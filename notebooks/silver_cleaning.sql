-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 03 - Silver layer: cleaning and standardizing
-- MAGIC **Goal:** turn the Bronze tables into clean, trusted tables, using the rules found during data profiling.
-- MAGIC
-- MAGIC | # | Dataset | Rule |
-- MAGIC |---|---|---|
-- MAGIC | 1 | eCommerce | Keep only valid `event_type` values (view, cart, purchase) |
-- MAGIC | 2 | eCommerce | Null `brand` -> 'unknown' |
-- MAGIC | 3 | eCommerce | Null `category_code` -> 'unknown'; split into category levels |
-- MAGIC | 4 | eCommerce | Flag `price = 0` with `is_zero_price` |
-- MAGIC | 5 | eCommerce | Convert `event_time` text -> timestamp; add `event_date`, `event_month` |
-- MAGIC | 6 | A/B | Exclude group/page mismatches |
-- MAGIC | 7 | A/B | Deduplicate users, keep first exposure |
-- MAGIC | 8 | Instacart | Keep null `days_since_prior_order`; add `is_first_order` |
-- MAGIC | 9 | Instacart | Exclude test orders |
-- MAGIC | 10 | Instacart | Stack prior + train order products |
-- MAGIC | 11 | Instacart | Flatten aisles and departments into products |
-- MAGIC
-- MAGIC Compute: **Serverless** | Default language: **SQL**

-- COMMAND ----------

USE CATALOG dbw_kroger_insights;

-- COMMAND ----------

WITH ranked_ab_tests AS (
    SELECT 
        user_id,
        -- Convert timestamp (using backticks for reserved keyword)
        CAST(`timestamp` AS TIMESTAMP) AS event_timestamp,
        -- Rename reserved keyword 'group' to test_group
        `group` AS test_group,
        landing_page,
        converted,
        -- Assign row numbers to keep each user's first entry
        ROW_NUMBER() OVER (
            PARTITION BY user_id 
            ORDER BY CAST(`timestamp` AS TIMESTAMP) ASC
        ) AS rn
    FROM dbw_kroger_insights.bronze.ab_test
    -- Profiling filter to keep valid rows
    WHERE user_id IS NOT NULL 
      AND `timestamp` IS NOT NULL
)
SELECT 
    user_id,
    event_timestamp,
    test_group,
    landing_page,
    converted
FROM ranked_ab_tests
WHERE rn = 1;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC # Part 1 - eCommerce events (rules 1-5)
-- MAGIC - `try_to_timestamp` returns null instead of failing if a value can't be parsed, so we can count parse failures afterwards.
-- MAGIC - `try_element_at` returns null if a category has fewer than 3 levels (e.g. `electronics.smartphone` has no level 3).
-- MAGIC - `CLUSTER BY (event_date)` organizes the files by date, so queries filtering on dates read less data (liquid clustering).
-- MAGIC - ~110M rows: expect several minutes.

-- COMMAND ----------

CREATE OR REPLACE TABLE silver.ecommerce_events
CLUSTER BY (event_date)
COMMENT 'Cleaned clickstream events (Oct-Nov 2019). Null brand/category set to unknown; zero prices and exact duplicates flagged, not removed.'
AS
WITH parsed AS (
    SELECT
        *,
        try_to_timestamp(replace(event_time, ' UTC', ''), 'yyyy-MM-dd HH:mm:ss') AS event_ts
    FROM bronze.ecommerce_events
    WHERE event_type IN ('view', 'cart', 'purchase')                         -- rule 1
)
SELECT
    event_ts,                                                                 -- rule 5 (UTC)
    CAST(event_ts AS DATE)                                     AS event_date,
    date_format(event_ts, 'yyyy-MM')                           AS event_month,
    event_type,
    product_id,
    category_id,
    COALESCE(category_code, 'unknown')                         AS category_code,   -- rule 3
    COALESCE(try_element_at(split(category_code, '\\.'), 1), 'unknown') AS category_l1,
    COALESCE(try_element_at(split(category_code, '\\.'), 2), 'unknown') AS category_l2,
    COALESCE(try_element_at(split(category_code, '\\.'), 3), 'unknown') AS category_l3,
    COALESCE(brand, 'unknown')                                 AS brand,           -- rule 2
    price,
    price = 0                                                  AS is_zero_price,   -- rule 4
    user_id,
    user_session,
    _source_file,
    ROW_NUMBER() OVER (
        PARTITION BY event_ts, event_type, product_id, user_id, user_session
        ORDER BY _source_file
    ) > 1                                                      AS is_duplicate     -- rule 6 (new)
FROM parsed;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Document the decisions directly on the table (visible in Catalog Explorer)

-- COMMAND ----------

ALTER TABLE silver.ecommerce_events ALTER COLUMN price
    COMMENT 'Product price. 0.23% of events have price 0 (views/carts only, no purchases); kept and flagged via is_zero_price.';
ALTER TABLE silver.ecommerce_events ALTER COLUMN category_code
    COMMENT 'Readable category. 32.21% null in source, set to unknown. Use category_id as the reliable key.';
ALTER TABLE silver.ecommerce_events ALTER COLUMN event_ts
    COMMENT 'Event timestamp in UTC, parsed from source text event_time.';

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Quality checks - eCommerce
-- MAGIC Expected: `silver_rows` = 109,950,743 (no invalid event types were found in profiling), `failed_timestamps` = 0, dates 2019-10-01 to 2019-11-30.

-- COMMAND ----------

SELECT
    (SELECT COUNT(*) FROM bronze.ecommerce_events)                    AS bronze_rows,
    COUNT(*)                                                          AS silver_rows,
    SUM(CASE WHEN event_ts IS NULL THEN 1 ELSE 0 END)                 AS failed_timestamps,
    MIN(event_date)                                                   AS first_date,
    MAX(event_date)                                                   AS last_date,
    SUM(CASE WHEN brand = 'unknown' THEN 1 ELSE 0 END)                AS unknown_brand,
    SUM(CASE WHEN category_code = 'unknown' THEN 1 ELSE 0 END)        AS unknown_category,
    SUM(CASE WHEN is_zero_price THEN 1 ELSE 0 END)                    AS zero_price,
    SUM(CASE WHEN user_session IS NULL THEN 1 ELSE 0 END)             AS null_sessions
FROM silver.ecommerce_events;

-- COMMAND ----------

SELECT event_type, COUNT(*) AS events
FROM silver.ecommerce_events
WHERE user_session IS NULL
GROUP BY event_type;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Check: exact duplicate events
-- MAGIC Same user, session, product, event type and timestamp more than once. We count them first, then decide.

-- COMMAND ----------

SELECT COUNT(*) AS duplicate_groups, SUM(cnt - 1) AS extra_rows
FROM (
    SELECT event_ts, event_type, product_id, user_id, user_session, COUNT(*) AS cnt
    FROM silver.ecommerce_events
    GROUP BY event_ts, event_type, product_id, user_id, user_session
    HAVING COUNT(*) > 1
) d;

-- COMMAND ----------

SELECT
    event_type,
    SUM(CASE WHEN is_duplicate THEN 1 ELSE 0 END) AS flagged
FROM silver.ecommerce_events
GROUP BY event_type;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Check: category levels look right

-- COMMAND ----------

SELECT category_code, category_l1, category_l2, category_l3, COUNT(*) AS events
FROM silver.ecommerce_events
GROUP BY ALL
ORDER BY events DESC
LIMIT 15;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC # Part 2 - A/B test (rules 6-7)
-- MAGIC **Exercise: try writing this one yourself before reading the solution below.**
-- MAGIC 1. Keep only matching rows (treatment/new_page, control/old_page)
-- MAGIC 2. Convert `timestamp` to a real timestamp
-- MAGIC 3. Use `ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY ...)` to keep each user's first row
-- MAGIC 4. Rename `group` to `test_group` so nobody needs backticks again
-- MAGIC
-- MAGIC Expected result: **290,584 rows**, one per user.

-- COMMAND ----------

CREATE OR REPLACE TABLE silver.ab_test
COMMENT 'Clean A/B test data: group/page mismatches removed (3,893 rows), one row per user (first exposure kept).'
AS
WITH matched AS (
    SELECT
        user_id,
        CAST(`timestamp` AS TIMESTAMP) AS exposure_ts,
        `group`                        AS test_group,
        landing_page,
        converted
    FROM bronze.ab_test
    WHERE (`group` = 'treatment' AND landing_page = 'new_page')              -- rule 6
       OR (`group` = 'control'   AND landing_page = 'old_page')
),
ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY exposure_ts) AS rn  -- rule 7
    FROM matched
)
SELECT user_id, exposure_ts, test_group, landing_page, converted
FROM ranked
WHERE rn = 1;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Quality checks - A/B
-- MAGIC Expected: 290,584 rows, 290,584 distinct users, 0 mismatches.

-- COMMAND ----------

SELECT
    COUNT(*)                AS total_rows,
    COUNT(DISTINCT user_id) AS distinct_users,
    SUM(CASE WHEN (test_group = 'treatment' AND landing_page <> 'new_page')
               OR (test_group = 'control'   AND landing_page <> 'old_page')
             THEN 1 ELSE 0 END) AS mismatches
FROM silver.ab_test;

-- COMMAND ----------

SELECT test_group, COUNT(*) AS users
FROM silver.ab_test
GROUP BY test_group;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC # Part 3 - Instacart (rules 8-11)

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Orders: exclude test orders, add first-order flag
-- MAGIC Expected: 3,421,083 - 75,000 = **3,346,083 rows**

-- COMMAND ----------

CREATE OR REPLACE TABLE silver.ic_orders
COMMENT 'Instacart orders (prior + train). Test orders excluded (their products are hidden). days_since_prior_order is null on first orders by design.'
AS
SELECT
    order_id,
    user_id,
    eval_set,
    order_number,
    order_dow,
    order_hour_of_day,
    days_since_prior_order,                                                   -- rule 8: keep null
    order_number = 1 AS is_first_order                                        -- rule 8: flag
FROM bronze.ic_orders
WHERE eval_set <> 'test';                                                     -- rule 9

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Order products: stack prior + train
-- MAGIC `UNION ALL` keeps every row (plain `UNION` would also remove duplicates, which is slower and not needed here).
-- MAGIC Expected: 32,434,489 + 1,384,617 = **33,819,106 rows**

-- COMMAND ----------

CREATE OR REPLACE TABLE silver.ic_order_products
COMMENT 'Products in each order, prior + train stacked. Composite key: order_id + product_id.'
AS
SELECT order_id, product_id, add_to_cart_order, reordered, 'prior' AS source_set
FROM bronze.ic_order_products_prior
UNION ALL                                                                     -- rule 10
SELECT order_id, product_id, add_to_cart_order, reordered, 'train' AS source_set
FROM bronze.ic_order_products_train;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Products: flatten aisles and departments (snowflake -> star)
-- MAGIC `LEFT JOIN` keeps every product even if its aisle or department were missing. Expected: **49,688 rows**

-- COMMAND ----------

CREATE OR REPLACE TABLE silver.ic_products
COMMENT 'Instacart products with aisle and department names flattened in (rule 11).'
AS
SELECT
    p.product_id,
    p.product_name,
    p.aisle_id,
    a.aisle,
    p.department_id,
    d.department
FROM bronze.ic_products p
LEFT JOIN bronze.ic_aisles      a ON p.aisle_id = a.aisle_id
LEFT JOIN bronze.ic_departments d ON p.department_id = d.department_id;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Quality checks - Instacart
-- MAGIC - **Orphan checks:** every order product should point to an existing order and product (expected 0 orphans)
-- MAGIC - **Lookup checks:** every product should have an aisle and department name (expected 0 missing)

-- COMMAND ----------

SELECT
    (SELECT COUNT(*) FROM silver.ic_orders)          AS orders,
    (SELECT COUNT(*) FROM silver.ic_order_products)  AS order_products,
    (SELECT COUNT(*) FROM silver.ic_products)        AS products,

    (SELECT COUNT(*) FROM silver.ic_order_products op
      LEFT JOIN silver.ic_orders o ON op.order_id = o.order_id
      WHERE o.order_id IS NULL)                      AS orphan_order_rows,

    (SELECT COUNT(*) FROM silver.ic_order_products op
      LEFT JOIN silver.ic_products p ON op.product_id = p.product_id
      WHERE p.product_id IS NULL)                    AS orphan_product_rows,

    (SELECT COUNT(*) FROM silver.ic_products
      WHERE aisle IS NULL OR department IS NULL)     AS products_missing_lookup;

-- COMMAND ----------

SELECT p.*, b.aisle_id AS bronze_aisle_id, b.department_id AS bronze_department_id,
       b._rescued_data
FROM silver.ic_products p
JOIN bronze.ic_products b ON p.product_id = b.product_id
WHERE p.aisle IS NULL OR p.department IS NULL;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC # Summary - all Silver tables

-- COMMAND ----------

SELECT 'ecommerce_events'  AS table_name, COUNT(*) AS row_count FROM silver.ecommerce_events
UNION ALL SELECT 'ab_test',           COUNT(*) FROM silver.ab_test
UNION ALL SELECT 'ic_orders',         COUNT(*) FROM silver.ic_orders
UNION ALL SELECT 'ic_order_products', COUNT(*) FROM silver.ic_order_products
UNION ALL SELECT 'ic_products',       COUNT(*) FROM silver.ic_products;

-- COMMAND ----------

