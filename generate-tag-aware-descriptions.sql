// Here’s a tag‑aware, AI_COMPLETE‑based stored procedure that:
// 1. reads Snowflake tags (three tags are used as example: BUSINESS_DOMAIN, REFRESH_FREQUENCY, DATA_OWNER),
// 2. generates short descriptions for each table (and optionally columns),
// 3. sets them as COMMENTS.
//
// NOTE: for a Snowflake official mechanism to generate object descriptions with Cortex, check:
// https://docs.snowflake.com/en/user-guide/sql-cortex-descriptions

CREATE OR REPLACE PROCEDURE TAG_MANAGEMENT.TAGS.GENERATE_TAG_AWARE_DESCRIPTIONS(
    database_name    STRING,
    schema_name      STRING,
    set_table_comment  BOOLEAN,
    set_column_comment BOOLEAN
)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
AS
$$
from snowflake.snowpark import Session

def main(session: Session,
         database_name: str,
         schema_name: str,
         set_table_comment: bool,
         set_column_comment: bool) -> str:

    db  = database_name.upper()
    sch = schema_name.upper()

    # ---- 1) Collect table metadata + tags + column list in one query ----
    tables_df = session.sql(f"""
        WITH base AS (
          SELECT
            t.table_catalog   AS database_name,
            t.table_schema    AS schema_name,
            t.table_name      AS table_name,
            LISTAGG(c.column_name || ' (' || c.data_type || ')', ', ')
              WITHIN GROUP (ORDER BY c.ordinal_position) AS column_list
          FROM {db}.INFORMATION_SCHEMA.TABLES t
          JOIN {db}.INFORMATION_SCHEMA.COLUMNS c
            ON c.table_catalog = t.table_catalog
           AND c.table_schema  = t.table_schema
           AND c.table_name    = t.table_name
          WHERE t.table_schema = '{sch}'
            AND t.table_type   = 'BASE TABLE'
          GROUP BY 1,2,3
        ),
        tags AS (
          SELECT
            tr.object_database AS database_name,
            tr.object_schema   AS schema_name,
            tr.object_name     AS table_name,
            MAX(IFF(tr.tag_name = 'BUSINESS_DOMAIN',   tr.tag_value, NULL)) AS business_domain,
            MAX(IFF(tr.tag_name = 'REFRESH_FREQUENCY', tr.tag_value, NULL)) AS refresh_frequency,
            MAX(IFF(tr.tag_name = 'DATA_OWNER',        tr.tag_value, NULL)) AS data_owner
          FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tr
          WHERE tr.domain = 'TABLE'
            AND tr.object_database = '{db}'
            AND tr.object_schema   = '{sch}'
            AND tr.tag_name IN ('BUSINESS_DOMAIN','REFRESH_FREQUENCY','DATA_OWNER')
          GROUP BY 1,2,3
        )
        SELECT
          b.database_name,
          b.schema_name,
          b.table_name,
          b.column_list,
          COALESCE(t.business_domain,   'Unknown') AS business_domain,
          COALESCE(t.refresh_frequency, 'Unknown') AS refresh_frequency,
          COALESCE(t.data_owner,        'Unknown') AS data_owner
        FROM base b
        LEFT JOIN tags t
          ON  t.database_name = b.database_name
          AND t.schema_name   = b.schema_name
          AND t.table_name    = b.table_name
    """).collect()

    for row in tables_df:
        db_name   = row['DATABASE_NAME']
        sc_name   = row['SCHEMA_NAME']
        tb_name   = row['TABLE_NAME']
        cols      = row['COLUMN_LIST']
        biz_dom   = row['BUSINESS_DOMAIN']
        freq      = row['REFRESH_FREQUENCY']
        owner     = row['DATA_OWNER']

        fq_table = f'{db_name}.{sc_name}.{tb_name}'

        # ---- 2) Table description via AI_COMPLETE (tags included) ----
        if set_table_comment:
            prompt = (
                "You are a data catalog assistant. In at most 2 short sentences, "
                f"describe the business meaning of table {fq_table}. "
                f"Business domain: {biz_dom}. Refresh frequency: {freq}. "
                f"Data owner: {owner}. "
                f"Columns (name and type): {cols}."
            )
            safe_prompt = prompt.replace("'", "''")

            table_desc = session.sql(f"""
                SELECT AI_COMPLETE(
                  'snowflake-arctic',
                  '{safe_prompt}'
                )
            """).collect()[0][0]

            # Set comment on table
            safe_desc = table_desc.strip('" ').strip('"').strip("'")
            session.sql(f"""
                ALTER TABLE {fq_table}
                SET COMMENT = '{safe_desc}'
            """).collect()

        # ---- 3) Column descriptions (optional, one call per column) ----
        if set_column_comment:
            cols_df = session.sql(f"""
                SELECT column_name, data_type
                FROM {db_name}.INFORMATION_SCHEMA.COLUMNS
                WHERE table_schema = '{sc_name}'
                  AND table_name   = '{tb_name}'
                ORDER BY ordinal_position
            """).collect()

            for c in cols_df:
                col_name = c['COLUMN_NAME']
                data_type = c['DATA_TYPE']

                col_prompt = (
                    "You are a data catalog assistant. In at most 1 short sentence, "
                    f"describe the column {col_name} (type {data_type}) "
                    f"in table {fq_table}. "
                    f"Business domain: {biz_dom}. Refresh frequency: {freq}. "
                    f"Data owner: {owner}."
                )
                col_safe_prompt = col_prompt.replace("'", "''")

                col_desc = session.sql(f"""
                    SELECT AI_COMPLETE(
                      'snowflake-arctic',
                      '{col_safe_prompt}'
                    )
                """).collect()[0][0]

                col_safe_desc = col_desc.strip('" ').strip('"').strip("'")

                # Quote column name if needed
                col_ref = col_name if col_name.isupper() else f'"{col_name}"'

                session.sql(f"""
                    ALTER TABLE {fq_table}
                    MODIFY COLUMN {col_ref}
                    COMMENT '{col_safe_desc}'
                """).collect()

    return "OK"
$$
;

// Now, can call the SP to generate descriptions for all tables in the schema
// Optionally, all columns of each table
CALL TAG_MANAGEMENT.TAGS.GENERATE_TAG_AWARE_DESCRIPTIONS(
  'FINANCE_DEMO',
  'DEMO',
  TRUE,  -- set_table_comment
  TRUE  -- set_column_comment
);
