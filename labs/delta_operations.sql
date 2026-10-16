-- =====================================================================
-- Lab: Delta Lake operations
-- Covers: history, time travel, RESTORE, MERGE (upserts, idempotency),
--         schema enforcement vs evolution, OPTIMIZE, VACUUM.
-- Auto Loader (incremental file ingestion) is in labs/auto_loader_lab.
-- Practice on a sandbox copy – never on production tables.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS dbw_kroger_insights.sandbox
COMMENT 'Practice area for labs. Safe to delete.';

CREATE OR REPLACE TABLE dbw_kroger_insights.sandbox.products AS
SELECT product_id, category_l1, brand, median_price
FROM dbw_kroger_insights.gold.ec_dim_product
WHERE category_l1 = 'electronics'
LIMIT 1000;

-- History = audit trail: version, who, when, operation, metrics
DESCRIBE HISTORY dbw_kroger_insights.sandbox.products;          -- v0: CREATE, 1,000 rows

-- ---------------------------------------------------------------------
-- Part 1: Time travel and RESTORE
-- ---------------------------------------------------------------------
-- The "accident"
DELETE FROM dbw_kroger_insights.sandbox.products
WHERE brand = 'samsung';
SELECT COUNT(*) FROM dbw_kroger_insights.sandbox.products;     -- 966 (34 deleted)

-- v1: DELETE used a deletion vector (rows marked, no file rewritten)
DESCRIBE HISTORY dbw_kroger_insights.sandbox.products;

-- Read the past without changing anything
SELECT COUNT(*) FROM dbw_kroger_insights.sandbox.products VERSION AS OF 0;   -- 1,000

-- What exactly was lost?
SELECT * FROM dbw_kroger_insights.sandbox.products VERSION AS OF 0
EXCEPT
SELECT * FROM dbw_kroger_insights.sandbox.products;            -- the 34 Samsung rows

-- Undo: RESTORE creates a NEW version (v2) – history is never erased
RESTORE TABLE dbw_kroger_insights.sandbox.products TO VERSION AS OF 0;
SELECT COUNT(*) FROM dbw_kroger_insights.sandbox.products;     -- 1,000

-- ---------------------------------------------------------------------
-- Part 2: MERGE (upsert) – atomic and idempotent
-- ---------------------------------------------------------------------
-- Daily feed: 3 existing products with +10% price, 2 new products
CREATE OR REPLACE TABLE dbw_kroger_insights.sandbox.products_feed AS
SELECT product_id, category_l1, brand, ROUND(median_price * 1.10, 2) AS median_price
FROM dbw_kroger_insights.sandbox.products
WHERE product_id IN (1005182, 1005175, 1002099)
UNION ALL
SELECT 99000001, 'electronics', 'newbrand', 199.99
UNION ALL
SELECT 99000002, 'electronics', 'newbrand', 349.99;

MERGE INTO dbw_kroger_insights.sandbox.products AS t
USING dbw_kroger_insights.sandbox.products_feed AS s
  ON t.product_id = s.product_id                               -- business key
WHEN MATCHED AND t.median_price <> s.median_price THEN         -- only real changes
  UPDATE SET t.median_price = s.median_price
WHEN NOT MATCHED THEN
  INSERT *;
-- Run 1: updated 3, inserted 2 -> 1,002 rows
-- Run 2 (same statement): updated 0, inserted 0 -> still 1,002 (idempotent)
-- An INSERT INTO would have created duplicates on every rerun.
SELECT COUNT(*) FROM dbw_kroger_insights.sandbox.products;

-- ---------------------------------------------------------------------
-- Part 3: Schema enforcement vs schema evolution
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE dbw_kroger_insights.sandbox.products_feed_v2 AS
SELECT 99000003 AS product_id, 'electronics' AS category_l1, 'newbrand' AS brand,
       499.99 AS median_price, 25 AS stock_qty;

-- Enforcement (default): fails with DELTA_METADATA_MISMATCH – extra column stock_qty
-- INSERT INTO dbw_kroger_insights.sandbox.products
-- SELECT * FROM dbw_kroger_insights.sandbox.products_feed_v2;

-- Deliberate, statement-scoped evolution
MERGE WITH SCHEMA EVOLUTION INTO dbw_kroger_insights.sandbox.products AS t
USING dbw_kroger_insights.sandbox.products_feed_v2 AS s
  ON t.product_id = s.product_id
WHEN MATCHED THEN UPDATE SET *
WHEN NOT MATCHED THEN INSERT *;
-- Alternative in strictly governed setups:
-- ALTER TABLE dbw_kroger_insights.sandbox.products ADD COLUMN stock_qty INT;

-- Existing rows are not rewritten: they read stock_qty as NULL (null ≠ 0)
SELECT product_id, brand, stock_qty
FROM dbw_kroger_insights.sandbox.products
WHERE product_id >= 99000001
ORDER BY product_id;                                           -- null, null, 25

-- ---------------------------------------------------------------------
-- Part 4: OPTIMIZE and VACUUM
-- ---------------------------------------------------------------------
DESCRIBE DETAIL dbw_kroger_insights.sandbox.products;          -- numFiles = 3

-- Compacts small files and purges rows marked by deletion vectors
OPTIMIZE dbw_kroger_insights.sandbox.products;                 -- 3 files -> 1, 15,221 -> 11,997 bytes

DESCRIBE DETAIL dbw_kroger_insights.sandbox.products;          -- numFiles = 1

-- VACUUM permanently deletes unreferenced files older than the retention
-- window (7 days default). After it, time travel past that window is gone.
VACUUM dbw_kroger_insights.sandbox.products DRY RUN;           -- nothing yet (files < 7 days old)

-- ---------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------
DROP SCHEMA dbw_kroger_insights.sandbox CASCADE;