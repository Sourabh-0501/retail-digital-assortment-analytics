-- =====================================================================
-- Lab: Table management in Unity Catalog / Delta Lake
-- Practice on copies in a sandbox schema – never on production tables.
-- Covers: CLONE, rename table/column, comments, tags, external tables,
--         DROP managed vs external, UNDROP, re-registering external data.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Sandbox schema + copies
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS dbw_kroger_insights.sandbox
COMMENT 'Practice area for table management labs. Safe to delete.';

-- Deep clone: full, independent copy (data files are copied) -> backups, migrations
CREATE OR REPLACE TABLE dbw_kroger_insights.sandbox.kpi_daily_deep
DEEP CLONE dbw_kroger_insights.gold.kpi_daily;

-- Shallow clone: metadata only, points to the source files -> cheap test copies
-- (breaks if the source's files are VACUUMed – never use as a backup)
CREATE OR REPLACE TABLE dbw_kroger_insights.sandbox.kpi_daily_shallow
SHALLOW CLONE dbw_kroger_insights.gold.kpi_daily;
-- Result: deep clone copied 1 file (6,530 bytes); shallow clone copied 0 files.

-- ---------------------------------------------------------------------
-- 2. Rename a table (metadata only – but breaks every consumer of the old name)
-- ---------------------------------------------------------------------
ALTER TABLE dbw_kroger_insights.sandbox.kpi_daily_deep
RENAME TO dbw_kroger_insights.sandbox.daily_kpis;

SHOW TABLES IN dbw_kroger_insights.sandbox;

-- Safe-rename pattern: keep the old name alive as a view while consumers migrate
CREATE VIEW dbw_kroger_insights.sandbox.kpi_daily_deep AS
SELECT * FROM dbw_kroger_insights.sandbox.daily_kpis;

-- ---------------------------------------------------------------------
-- 3. Rename a column
--    Fails by default (DELTA_UNSUPPORTED_RENAME_COLUMN): Parquet files store
--    physical column names. Column mapping decouples logical and physical
--    names -> rename/drop become metadata-only.
--    Trade-off: upgrades the table protocol (older external readers may break).
-- ---------------------------------------------------------------------
ALTER TABLE dbw_kroger_insights.sandbox.daily_kpis
SET TBLPROPERTIES ('delta.columnMapping.mode' = 'name');

ALTER TABLE dbw_kroger_insights.sandbox.daily_kpis
RENAME COLUMN revenue TO total_revenue;

DESCRIBE TABLE dbw_kroger_insights.sandbox.daily_kpis;

-- ---------------------------------------------------------------------
-- 4. Documentation and classification
-- ---------------------------------------------------------------------
COMMENT ON TABLE dbw_kroger_insights.sandbox.daily_kpis IS
'Practice copy of gold.kpi_daily. One row per day, Oct–Nov 2019.';

ALTER TABLE dbw_kroger_insights.sandbox.daily_kpis
ALTER COLUMN total_revenue COMMENT 'Sum of purchase revenue for the day (USD)';

ALTER TABLE dbw_kroger_insights.sandbox.daily_kpis
SET TAGS ('domain' = 'ecommerce', 'layer' = 'gold', 'owner_team' = 'insights');

ALTER TABLE dbw_kroger_insights.sandbox.daily_kpis
ALTER COLUMN date SET TAGS ('pii' = 'false');

-- Tags are queryable across the whole catalog
SELECT * FROM dbw_kroger_insights.information_schema.table_tags
WHERE schema_name = 'sandbox';

-- ---------------------------------------------------------------------
-- 5. External table with a readable storage path
--    (must be outside any managed storage location – hence the raw container)
-- ---------------------------------------------------------------------
CREATE TABLE dbw_kroger_insights.sandbox.daily_kpis_ext
LOCATION 'abfss://raw@retailprojectstorage01.dfs.core.windows.net/external_lab/daily_kpis_ext'
AS SELECT * FROM dbw_kroger_insights.gold.kpi_daily;

DESCRIBE DETAIL dbw_kroger_insights.sandbox.daily_kpis;      -- managed: location hidden
DESCRIBE DETAIL dbw_kroger_insights.sandbox.daily_kpis_ext;  -- external: readable path

-- ---------------------------------------------------------------------
-- 6. DROP: managed vs external
-- ---------------------------------------------------------------------
-- External: only metadata removed – files stay in storage
DROP TABLE dbw_kroger_insights.sandbox.daily_kpis_ext;

-- Managed: data deleted after a 7-day recovery window
DROP TABLE dbw_kroger_insights.sandbox.daily_kpis;
SHOW TABLES DROPPED IN dbw_kroger_insights.sandbox;

-- Recover the managed table (metadata, comments, tags included)
UNDROP TABLE dbw_kroger_insights.sandbox.daily_kpis;
SELECT COUNT(*) FROM dbw_kroger_insights.sandbox.daily_kpis;      -- 61

-- Recover the external table: re-register the surviving files (no AS SELECT needed)
CREATE TABLE dbw_kroger_insights.sandbox.daily_kpis_ext
LOCATION 'abfss://raw@retailprojectstorage01.dfs.core.windows.net/external_lab/daily_kpis_ext';
SELECT COUNT(*) FROM dbw_kroger_insights.sandbox.daily_kpis_ext;  -- 61

-- ---------------------------------------------------------------------
-- 7. Cleanup
--    CASCADE drops the schema and everything in it.
--    External files remain in storage -> delete raw/external_lab manually.
-- ---------------------------------------------------------------------
DROP SCHEMA dbw_kroger_insights.sandbox CASCADE;