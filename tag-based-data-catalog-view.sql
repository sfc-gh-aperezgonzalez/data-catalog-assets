// This SQL view illustrates how to retrieve Snowflake tags and table metadata
// for a given database(s), which could be use as base view for a Snowflake Intelligence
// Data Catalog Agent 
  
CREATE OR REPLACE VIEW TAG_MANAGEMENT.TAGS.V_DATASETS_REGISTRY AS
WITH base AS (
  SELECT
    t.table_catalog   AS database_name,
    t.table_schema    AS schema_name,
    t.table_name      AS object_name,
    t.row_count,
    t.bytes,
    t.comment         AS table_description,
    t.created,
    t.last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES t
  WHERE t.table_type    = 'BASE TABLE'
    AND t.table_schema  = 'DEMO'
    AND t.table_catalog IN ('FINANCE_DEMO','MANUFACTURING')
    AND t.deleted IS NULL
),
tags AS (
  SELECT
    tr.object_database AS database_name,
    tr.object_schema   AS schema_name,
    tr.object_name     AS object_name,
    MAX(IFF(tr.tag_name = 'BUSINESS_DOMAIN',   tr.tag_value, NULL)) AS business_domain_raw,
    MAX(IFF(tr.tag_name = 'REFRESH_FREQUENCY', tr.tag_value, NULL)) AS refresh_frequency_raw,
    MAX(IFF(tr.tag_name = 'DATA_OWNER',        tr.tag_value, NULL)) AS data_owner_raw
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tr
  WHERE tr.domain = 'TABLE'
    AND tr.object_schema   = 'DEMO'
    AND tr.object_database IN ('FINANCE_DEMO','MANUFACTURING')
    AND tr.tag_name IN ('BUSINESS_DOMAIN','REFRESH_FREQUENCY','DATA_OWNER')
  GROUP BY 1,2,3
)
SELECT
  b.database_name,
  b.schema_name,
  b.object_name,
  b.table_description,
  b.row_count,
  b.bytes,
  b.last_altered,
  t.business_domain_raw,
  t.refresh_frequency_raw,
  t.data_owner_raw
FROM base b
LEFT JOIN tags t
  ON  t.database_name = b.database_name
  AND t.schema_name   = b.schema_name
  AND t.object_name   = b.object_name;
