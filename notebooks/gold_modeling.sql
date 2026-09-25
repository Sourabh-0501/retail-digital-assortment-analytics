-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 04 - Gold layer: data model
-- MAGIC **Goal:** turn clean Silver tables into business-ready facts and dimensions.
-- MAGIC
-- MAGIC | Dataset | Table | Type | One row = |
-- MAGIC |---|---|---|---|
-- MAGIC | eCommerce | `dim_date` | Dimension | one date |
-- MAGIC | eCommerce | `ec_dim_product` | Dimension | one product |
-- MAGIC | eCommerce | `ec_fact_events` | Fact (detailed) | one event |
-- MAGIC | eCommerce | `ec_fact_sessions` | Fact (aggregated) | one visit |
-- MAGIC | eCommerce | `ec_fact_product_daily` | Fact (aggregated) | one product on one day |
-- MAGIC | Instacart | `ic_dim_product` | Dimension | one product |
-- MAGIC | Instacart | `ic_dim_order` | Dimension | one order |
-- MAGIC | Instacart | `ic_fact_order_products` | Fact | one product in one order |
-- MAGIC | A/B | `ab_summary`, `ab_daily` | Aggregated | one group / one group-day |
-- MAGIC
-- MAGIC Prefixes (`ec_`, `ic_`, `ab_`) keep the three unrelated datasets apart. Both eCommerce and Instacart have a product dimension, so they need different names.
-- MAGIC
-- MAGIC Notes carried over from Silver:
-- MAGIC 1. Category levels that don't exist -> `n/a` (not `unknown`)
-- MAGIC 2. Sessions: exclude the 12 null-session events
-- MAGIC 3. Event counts exclude `is_duplicate`; all purchases kept for revenue

-- COMMAND ----------

USE CATALOG dbw_kroger_insights;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC # Part 1 - `dim_date` (generated, not read from data)
-- MAGIC `sequence()` creates one date per day, `explode()` turns that list into rows.

-- COMMAND ----------

CREATE OR REPLACE TABLE gold.dim_date
COMMENT 'Calendar dimension for Oct-Nov 2019. One row per date.'
AS
WITH dates AS (
    SELECT explode(sequence(DATE'2019-10-01', DATE'2019-11-30', INTERVAL 1 DAY)) AS date
)
SELECT
    CAST(date_format(date, 'yyyyMMdd') AS INT)       AS date_key,
    date,
    year(date)                                       AS year,
    month(date)                                      AS month_num,
    date_format(date, 'MMMM')                        AS month_name,
    date_format(date, 'yyyy-MM')                     AS year_month,
    day(date)                                        AS day_of_month,
    weekday(date) + 1                                AS day_of_week_num,   -- 1 = Monday ... 7 = Sunday
    date_format(date, 'EEEE')                        AS day_name,
    weekofyear(date)                                 AS week_of_year,
    CAST(date_trunc('WEEK', date) AS DATE)           AS week_start_date,   -- Monday
    weekday(date) >= 5                               AS is_weekend,
    date = DATE'2019-11-29'                          AS is_black_friday
FROM dates;

-- COMMAND ----------

-- Expected: 61 rows (31 Oct + 30 Nov), exactly 1 Black Friday
SELECT COUNT(*) AS days, SUM(CASE WHEN is_black_friday THEN 1 ELSE 0 END) AS black_fridays,
       MIN(date) AS first_date, MAX(date) AS last_date
FROM gold.dim_date;

-- COMMAND ----------

SELECT * FROM gold.dim_date ORDER BY date LIMIT 10;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC # Part 2 - `ec_dim_product`
-- MAGIC **First check:** does every product have one brand and one category? If not, we need a rule to pick one.

-- COMMAND ----------

CREATE OR REPLACE TABLE gold.ec_dim_product
COMMENT 'eCommerce product dimension. One row per product_id. Brand/category = most frequent KNOWN value (unknown only if never recorded); price = median of non-zero prices.'
AS
WITH per_product AS (
    SELECT
        product_id,
        mode(category_id)                                                      AS category_id,
        COALESCE(mode(CASE WHEN category_code <> 'unknown' THEN category_code END), 'unknown') AS category_code,
        COALESCE(mode(CASE WHEN brand <> 'unknown' THEN brand END), 'unknown') AS brand,
        percentile_approx(price, 0.5) FILTER (WHERE price > 0)                AS median_price,
        MIN(event_date)                                                        AS first_seen_date,
        MAX(event_date)                                                        AS last_seen_date
    FROM silver.ecommerce_events
    GROUP BY product_id
),
levels AS (
    SELECT *, split(category_code, '\\.') AS parts
    FROM per_product
)
SELECT
    product_id,
    category_id,
    category_code,
    CASE WHEN category_code = 'unknown' THEN 'unknown'
         ELSE parts[0] END                                                     AS category_l1,
    CASE WHEN category_code = 'unknown' THEN 'unknown'
         ELSE COALESCE(try_element_at(parts, 2), 'n/a') END                    AS category_l2,
    CASE WHEN category_code = 'unknown' THEN 'unknown'
         ELSE COALESCE(try_element_at(parts, 3), 'n/a') END                    AS category_l3,
    brand,
    ROUND(median_price, 2)                                                     AS median_price,
    first_seen_date,
    last_seen_date
FROM levels;

-- COMMAND ----------

SELECT
    SUM(CASE WHEN real_brands > 1 THEN 1 ELSE 0 END)                  AS true_brand_conflicts,
    SUM(CASE WHEN real_brands = 1 AND has_unknown THEN 1 ELSE 0 END)  AS known_plus_unknown
FROM (
    SELECT
        product_id,
        COUNT(DISTINCT CASE WHEN brand <> 'unknown' THEN brand END)   AS real_brands,
        MAX(CASE WHEN brand = 'unknown' THEN 1 ELSE 0 END) = 1        AS has_unknown
    FROM silver.ecommerce_events
    GROUP BY product_id
) p;

-- COMMAND ----------

SELECT COUNT(*) AS products, COUNT(DISTINCT product_id) AS distinct_products,
       SUM(CASE WHEN brand = 'unknown' THEN 1 ELSE 0 END)       AS brand_unknown,
       SUM(CASE WHEN category_l3 = 'n/a' THEN 1 ELSE 0 END)     AS l3_not_applicable,
       SUM(CASE WHEN category_l3 = 'unknown' THEN 1 ELSE 0 END) AS l3_unknown
FROM gold.ec_dim_product;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC Rules used below:
-- MAGIC - `mode()` = most frequent value, so a product with a rare conflicting brand still gets its usual one
-- MAGIC - Typical price = median of non-zero prices (`percentile_approx` with `FILTER`), robust to price changes and outliers
-- MAGIC - Silver note 1: level shows `n/a` when the category is known but has fewer levels

-- COMMAND ----------

CREATE OR REPLACE TABLE gold.ec_dim_product
COMMENT 'eCommerce product dimension. One row per product_id. Brand/category = most frequent value; price = median of non-zero prices.'
AS
WITH per_product AS (
    SELECT
        product_id,
        mode(category_id)                                          AS category_id,
        mode(category_code)                                        AS category_code,
        mode(category_l1)                                          AS category_l1,
        mode(category_l2)                                          AS category_l2,
        mode(category_l3)                                          AS category_l3,
        mode(brand)                                                AS brand,
        percentile_approx(price, 0.5) FILTER (WHERE price > 0)     AS median_price,
        MIN(event_date)                                            AS first_seen_date,
        MAX(event_date)                                            AS last_seen_date
    FROM silver.ecommerce_events
    GROUP BY product_id
)
SELECT
    product_id,
    category_id,
    category_code,
    category_l1,
    CASE WHEN category_code = 'unknown' THEN 'unknown'
         WHEN category_l2   = 'unknown' THEN 'n/a' ELSE category_l2 END AS category_l2,
    CASE WHEN category_code = 'unknown' THEN 'unknown'
         WHEN category_l3   = 'unknown' THEN 'n/a' ELSE category_l3 END AS category_l3,
    brand,
    ROUND(median_price, 2)                                         AS median_price,
    first_seen_date,
    last_seen_date
FROM per_product;

-- COMMAND ----------

-- Expected: products = distinct_products (one row per product, primary key is unique)
SELECT COUNT(*) AS products, COUNT(DISTINCT product_id) AS distinct_products,
       SUM(CASE WHEN category_l3 = 'n/a' THEN 1 ELSE 0 END)     AS l3_not_applicable,
       SUM(CASE WHEN category_l3 = 'unknown' THEN 1 ELSE 0 END) AS l3_unknown
FROM gold.ec_dim_product;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC # Part 3 - `ec_fact_events` (detailed fact)
-- MAGIC Category and brand are **removed** here, they live in `ec_dim_product`. Facts keep keys + measures + flags only.
-- MAGIC Flags stay so every metric can choose (e.g. exclude duplicates from counts). ~110M rows: several minutes.

-- COMMAND ----------

CREATE OR REPLACE TABLE gold.ec_fact_events
CLUSTER BY (event_date)
COMMENT 'Event-level fact. FKs: product_id -> ec_dim_product, event_date -> dim_date. Includes is_duplicate and is_zero_price flags.'
AS
SELECT
    event_ts,
    event_date,                          -- FK -> dim_date.date
    CAST(date_format(event_date, 'yyyyMMdd') AS INT) AS date_key,
    event_type,
    product_id,                          -- FK -> ec_dim_product.product_id
    user_id,
    user_session,
    price,
    is_duplicate,
    is_zero_price
FROM silver.ecommerce_events;

-- COMMAND ----------

-- Expected: 109,950,743 rows, 0 orphan products, 0 orphan dates
SELECT
    (SELECT COUNT(*) FROM gold.ec_fact_events) AS fact_rows,
    (SELECT COUNT(*) FROM gold.ec_fact_events f
       LEFT JOIN gold.ec_dim_product p ON f.product_id = p.product_id
      WHERE p.product_id IS NULL)              AS orphan_products,
    (SELECT COUNT(*) FROM gold.ec_fact_events f
       LEFT JOIN gold.dim_date d ON f.event_date = d.date
      WHERE d.date IS NULL)                    AS orphan_dates;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC # Part 4 - `ec_fact_sessions` (aggregated fact, one row per visit)
-- MAGIC - Silver note 2: null sessions excluded
-- MAGIC - Silver note 3: views/carts exclude duplicates, purchases and revenue keep every row
-- MAGIC - `has_*` flags power the session funnel: *did* the visit include a view / cart / purchase?

-- COMMAND ----------

CREATE OR REPLACE TABLE gold.ec_fact_sessions
CLUSTER BY (session_date)
COMMENT 'Session-level fact. One row per user_session (null sessions excluded). Views/carts exclude duplicates; purchases/revenue include all rows.'
AS
SELECT
    user_session,
    MIN(user_id)                                                               AS user_id,
    MIN(event_ts)                                                              AS session_start,
    MAX(event_ts)                                                              AS session_end,
    CAST(MIN(event_ts) AS DATE)                                                AS session_date,   -- FK -> dim_date
    timestampdiff(SECOND, MIN(event_ts), MAX(event_ts))                        AS duration_seconds,
    SUM(CASE WHEN event_type = 'view' AND NOT is_duplicate THEN 1 ELSE 0 END)  AS views,
    SUM(CASE WHEN event_type = 'cart' AND NOT is_duplicate THEN 1 ELSE 0 END)  AS carts,
    SUM(CASE WHEN event_type = 'purchase' THEN 1 ELSE 0 END)                   AS purchases,
    COUNT(DISTINCT CASE WHEN event_type = 'view' THEN product_id END)          AS products_viewed,
    ROUND(SUM(CASE WHEN event_type = 'purchase' THEN price ELSE 0 END), 2)     AS revenue,
    MAX(CASE WHEN event_type = 'view'     THEN 1 ELSE 0 END) = 1               AS has_view,
    MAX(CASE WHEN event_type = 'cart'     THEN 1 ELSE 0 END) = 1               AS has_cart,
    MAX(CASE WHEN event_type = 'purchase' THEN 1 ELSE 0 END) = 1               AS has_purchase
FROM gold.ec_fact_events
WHERE user_session IS NOT NULL
GROUP BY user_session;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Checks - sessions
-- MAGIC - `sessions` = `distinct_sessions` (grain is one row per session)
-- MAGIC - `session_purchases` = 1,659,788 (all purchases have a session, the 12 null-session events were carts)
-- MAGIC - `session_revenue` = `event_revenue` (nothing lost when aggregating)
-- MAGIC - `multi_user_sessions`: sessions shared by more than one user_id (should be 0 or tiny)

-- COMMAND ----------

SELECT
    COUNT(*)                                   AS sessions,
    COUNT(DISTINCT user_session)               AS distinct_sessions,
    SUM(purchases)                             AS session_purchases,
    ROUND(SUM(revenue), 2)                     AS session_revenue,
    (SELECT ROUND(SUM(price), 2) FROM gold.ec_fact_events WHERE event_type = 'purchase') AS event_revenue
FROM gold.ec_fact_sessions;

-- COMMAND ----------

SELECT COUNT(*) AS multi_user_sessions
FROM (
    SELECT user_session
    FROM gold.ec_fact_events
    WHERE user_session IS NOT NULL
    GROUP BY user_session
    HAVING COUNT(DISTINCT user_id) > 1
) s;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC # Part 5 - `ec_fact_product_daily` (aggregated fact for Power BI)
-- MAGIC **Exercise - try writing this yourself first.** One row per `event_date` + `product_id` with:
-- MAGIC `views`, `carts` (both excluding duplicates), `purchases`, `revenue` (all purchase rows).
-- MAGIC Hint: same `SUM(CASE WHEN ...)` pattern as `ec_fact_sessions`, grouped by two columns.
-- MAGIC
-- MAGIC Why this table: Power BI shouldn't import 110M event rows. A daily product summary is far smaller and answers most SKU questions.

-- COMMAND ----------

CREATE OR REPLACE TABLE gold.ec_fact_product_daily
CLUSTER BY (event_date)
COMMENT 'Daily product performance. One row per event_date + product_id. Views/carts exclude duplicates; purchases/revenue include all rows.'
AS
SELECT
    event_date,
    date_key,
    product_id,
    SUM(CASE WHEN event_type = 'view' AND NOT is_duplicate THEN 1 ELSE 0 END)  AS views,
    SUM(CASE WHEN event_type = 'cart' AND NOT is_duplicate THEN 1 ELSE 0 END)  AS carts,
    SUM(CASE WHEN event_type = 'purchase' THEN 1 ELSE 0 END)                   AS purchases,
    ROUND(SUM(CASE WHEN event_type = 'purchase' THEN price ELSE 0 END), 2)     AS revenue
FROM gold.ec_fact_events
GROUP BY event_date, date_key, product_id;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Checks - product daily
-- MAGIC Expected: views 104,331,840 (104,335,509 - 3,669 dups), carts 3,828,450 (3,955,446 - 126,996 dups), purchases 1,659,788, revenue = event revenue above.

-- COMMAND ----------

SELECT
    COUNT(*)                    AS rows,
    SUM(views)                  AS views,
    SUM(carts)                  AS carts,
    SUM(purchases)              AS purchases,
    ROUND(SUM(revenue), 2)      AS revenue
FROM gold.ec_fact_product_daily;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC # Part 6 - Instacart star schema
-- MAGIC Silver already did the hard work (stacking, flattening, excluding test orders), so Gold mostly selects and names the model tables.
-- MAGIC Note: `order_dow` is 0-6; Instacart never documented which day 0 is (commonly assumed Sunday). Treat it as a label, not a known weekday.

-- COMMAND ----------

CREATE OR REPLACE TABLE gold.ic_dim_product
COMMENT 'Instacart product dimension with aisle and department names. One row per product_id.'
AS
SELECT product_id, product_name, aisle_id, aisle, department_id, department
FROM silver.ic_products;

-- COMMAND ----------

CREATE OR REPLACE TABLE gold.ic_dim_order
COMMENT 'Instacart order dimension: who and when. One row per order_id. Test orders excluded.'
AS
SELECT order_id, user_id, eval_set, order_number, order_dow, order_hour_of_day,
       days_since_prior_order, is_first_order
FROM silver.ic_orders;

-- COMMAND ----------

CREATE OR REPLACE TABLE gold.ic_fact_order_products
COMMENT 'Instacart fact: one product in one order. Composite key order_id + product_id. FKs -> ic_dim_order, ic_dim_product.'
AS
SELECT order_id, product_id, add_to_cart_order, reordered
FROM silver.ic_order_products;

-- COMMAND ----------

-- Expected: 49,688 / 3,346,083 / 33,819,106, 0 orphans, 0 duplicate keys
SELECT
    (SELECT COUNT(*) FROM gold.ic_dim_product)          AS products,
    (SELECT COUNT(*) FROM gold.ic_dim_order)            AS orders,
    (SELECT COUNT(*) FROM gold.ic_fact_order_products)  AS fact_rows,
    (SELECT COUNT(*) FROM gold.ic_fact_order_products f
       LEFT JOIN gold.ic_dim_order o ON f.order_id = o.order_id
      WHERE o.order_id IS NULL)                         AS orphan_orders,
    (SELECT COUNT(*) FROM (
        SELECT order_id, product_id FROM gold.ic_fact_order_products
        GROUP BY order_id, product_id HAVING COUNT(*) > 1) d) AS duplicate_keys;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC # Part 7 - A/B test summaries
-- MAGIC Statistical tests only need counts per group, so a small summary table is all the readout needs.
-- MAGIC `ab_daily` lets us check whether the effect is stable over time (novelty effect).

-- COMMAND ----------

CREATE OR REPLACE TABLE gold.ab_summary
COMMENT 'A/B test totals per group from clean silver.ab_test.'
AS
SELECT
    test_group,
    landing_page,
    COUNT(*)                                AS users,
    SUM(converted)                          AS conversions,
    ROUND(AVG(converted), 5)                AS conversion_rate,
    MIN(exposure_ts)                        AS first_exposure,
    MAX(exposure_ts)                        AS last_exposure
FROM silver.ab_test
GROUP BY test_group, landing_page;

-- COMMAND ----------

CREATE OR REPLACE TABLE gold.ab_daily
COMMENT 'A/B test users and conversions per group per day.'
AS
SELECT
    CAST(exposure_ts AS DATE)   AS exposure_date,
    test_group,
    COUNT(*)                    AS users,
    SUM(converted)              AS conversions,
    ROUND(AVG(converted), 5)    AS conversion_rate
FROM silver.ab_test
GROUP BY CAST(exposure_ts AS DATE), test_group;

-- COMMAND ----------

-- Expected: 2 rows, users 145,310 (treatment) and 145,274 (control)
SELECT * FROM gold.ab_summary;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC # Summary - all Gold tables

-- COMMAND ----------

SELECT 'dim_date' AS table_name, COUNT(*) AS row_count FROM gold.dim_date
UNION ALL SELECT 'ec_dim_product',         COUNT(*) FROM gold.ec_dim_product
UNION ALL SELECT 'ec_fact_events',         COUNT(*) FROM gold.ec_fact_events
UNION ALL SELECT 'ec_fact_sessions',       COUNT(*) FROM gold.ec_fact_sessions
UNION ALL SELECT 'ec_fact_product_daily',  COUNT(*) FROM gold.ec_fact_product_daily
UNION ALL SELECT 'ic_dim_product',         COUNT(*) FROM gold.ic_dim_product
UNION ALL SELECT 'ic_dim_order',           COUNT(*) FROM gold.ic_dim_order
UNION ALL SELECT 'ic_fact_order_products', COUNT(*) FROM gold.ic_fact_order_products
UNION ALL SELECT 'ab_summary',             COUNT(*) FROM gold.ab_summary
UNION ALL SELECT 'ab_daily',               COUNT(*) FROM gold.ab_daily;

-- COMMAND ----------

