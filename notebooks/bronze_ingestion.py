# Databricks notebook source
# /// script
# [tool.databricks.environment]
# environment_version = "5"
# ///
# MAGIC %md
# MAGIC # 01 - Bronze ingestion
# MAGIC **Goal:** load every raw CSV from the `raw` container into Bronze Delta tables, as-is.
# MAGIC
# MAGIC Bronze rules:
# MAGIC - Keep the data exactly as the source gave it (no cleaning, no filtering)
# MAGIC - Add two audit columns: `_source_file` (which file the row came from) and `_ingested_at` (when we loaded it)
# MAGIC - Cleaning happens in Silver, not here
# MAGIC
# MAGIC Compute: **Serverless**

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 1 - Config

# COMMAND ----------

CATALOG = "dbw_kroger_insights"
STORAGE = "retailprojectstorage01"
RAW = f"abfss://raw@{STORAGE}.dfs.core.windows.net"

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 2 - Create the schemas (bronze / silver / gold)
# MAGIC Each schema stores its tables in its own container, so the medallion layers are physically separate in the data lake.

# COMMAND ----------

for layer in ["bronze", "silver", "gold"]:
    spark.sql(f"""
        CREATE SCHEMA IF NOT EXISTS {CATALOG}.{layer}
        MANAGED LOCATION 'abfss://{layer}@{STORAGE}.dfs.core.windows.net/'
    """)

spark.sql(f"USE CATALOG {CATALOG}")
display(spark.sql("SHOW SCHEMAS"))

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 3 - Check the raw files are visible

# COMMAND ----------

for folder in ["ecommerce", "instacart", "abtest"]:
    print(f"--- {folder} ---")
    for f in dbutils.fs.ls(f"{RAW}/{folder}"):
        print(f"{f.name:40s} {f.size / 1024**2:>10.1f} MB")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 4 - Reusable loader function
# MAGIC One function loads any CSV into a Bronze table. Writing it once and reusing it is how real pipelines are built.

# COMMAND ----------

from pyspark.sql import functions as F
from pyspark.sql.types import (StructType, StructField, StringType,
                               LongType, IntegerType, DoubleType)

def load_csv_to_bronze(path, table, schema):
    df = (spark.read
            .option("header", True)
            .option("escape", '"')                            # handles "" inside quoted text (RFC 4180)
            .option("rescuedDataColumn", "_rescued_data")     # captures values that don't fit the schema
            .schema(schema)
            .csv(path)
            .withColumn("_source_file", F.col("_metadata.file_path"))
            .withColumn("_ingested_at", F.current_timestamp()))

    (df.write
       .mode("overwrite")
       .option("overwriteSchema", True)
       .saveAsTable(f"{CATALOG}.bronze.{table}"))

    count = spark.table(f"{CATALOG}.bronze.{table}").count()
    print(f"bronze.{table}: {count:,} rows")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 5 - eCommerce events (Oct + Nov stacked into one table)
# MAGIC - Reading the whole `ecommerce/` folder picks up both CSVs automatically; `_source_file` tells them apart.
# MAGIC - `event_time` is kept as **string** on purpose (format is `2019-10-01 00:00:00 UTC`). We convert it in Silver.
# MAGIC - This is ~110M rows, so expect it to take several minutes.

# COMMAND ----------

ecommerce_schema = StructType([
    StructField("event_time",    StringType()),
    StructField("event_type",    StringType()),
    StructField("product_id",    LongType()),
    StructField("category_id",   LongType()),
    StructField("category_code", StringType()),
    StructField("brand",         StringType()),
    StructField("price",         DoubleType()),
    StructField("user_id",       LongType()),
    StructField("user_session",  StringType()),
])

load_csv_to_bronze(f"{RAW}/ecommerce/", "ecommerce_events", ecommerce_schema)

# COMMAND ----------

# MAGIC    %sql
# MAGIC    SELECT COUNT(*) AS rescued_rows
# MAGIC    FROM dbw_kroger_insights.bronze.ecommerce_events
# MAGIC    WHERE _rescued_data IS NOT NULL

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT _source_file, COUNT(*) AS row_count
# MAGIC FROM dbw_kroger_insights.bronze.ecommerce_events
# MAGIC GROUP BY _source_file

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 6 - Instacart (6 tables, loaded as-is)
# MAGIC `prior` and `train` stay separate in Bronze. We stack them in Silver.

# COMMAND ----------

instacart_files = {
    "ic_orders": ("orders.csv", StructType([
        StructField("order_id",               IntegerType()),
        StructField("user_id",                IntegerType()),
        StructField("eval_set",               StringType()),
        StructField("order_number",           IntegerType()),
        StructField("order_dow",              IntegerType()),
        StructField("order_hour_of_day",      IntegerType()),
        StructField("days_since_prior_order", DoubleType()),
    ])),
    "ic_order_products_prior": ("order_products__prior.csv", StructType([
        StructField("order_id",          IntegerType()),
        StructField("product_id",        IntegerType()),
        StructField("add_to_cart_order", IntegerType()),
        StructField("reordered",         IntegerType()),
    ])),
    "ic_order_products_train": ("order_products__train.csv", StructType([
        StructField("order_id",          IntegerType()),
        StructField("product_id",        IntegerType()),
        StructField("add_to_cart_order", IntegerType()),
        StructField("reordered",         IntegerType()),
    ])),
    "ic_products": ("products.csv", StructType([
        StructField("product_id",    IntegerType()),
        StructField("product_name",  StringType()),
        StructField("aisle_id",      IntegerType()),
        StructField("department_id", IntegerType()),
    ])),
    "ic_aisles": ("aisles.csv", StructType([
        StructField("aisle_id", IntegerType()),
        StructField("aisle",    StringType()),
    ])),
    "ic_departments": ("departments.csv", StructType([
        StructField("department_id", IntegerType()),
        StructField("department",    StringType()),
    ])),
}

for table, (file_name, schema) in instacart_files.items():
    load_csv_to_bronze(f"{RAW}/instacart/{file_name}", table, schema)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 7 - A/B test data

# COMMAND ----------

ab_schema = StructType([
    StructField("user_id",      IntegerType()),
    StructField("timestamp",    StringType()),
    StructField("group",        StringType()),
    StructField("landing_page", StringType()),
    StructField("converted",    IntegerType()),
])

load_csv_to_bronze(f"{RAW}/abtest/ab_data.csv", "ab_test", ab_schema)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 8 - Validate: do row counts match the source?
# MAGIC Expected (approx.):
# MAGIC | Table | Expected rows |
# MAGIC |---|---|
# MAGIC | ecommerce_events | ~110M (Oct ~42.4M + Nov ~67.5M) |
# MAGIC | ic_orders | 3,421,083 |
# MAGIC | ic_order_products_prior | 32,434,489 |
# MAGIC | ic_order_products_train | 1,384,617 |
# MAGIC | ic_products | 49,688 |
# MAGIC | ic_aisles | 134 |
# MAGIC | ic_departments | 21 |
# MAGIC | ab_test | 294,478 |

# COMMAND ----------

# Step 8 - Source-to-target reconciliation for all Bronze tables

sources = {
    "ecommerce_events":        f"{RAW}/ecommerce/",
    "ic_orders":               f"{RAW}/instacart/orders.csv",
    "ic_order_products_prior": f"{RAW}/instacart/order_products__prior.csv",
    "ic_order_products_train": f"{RAW}/instacart/order_products__train.csv",
    "ic_products":             f"{RAW}/instacart/products.csv",
    "ic_aisles":               f"{RAW}/instacart/aisles.csv",
    "ic_departments":          f"{RAW}/instacart/departments.csv",
    "ab_test":                 f"{RAW}/abtest/ab_data.csv",
}

SKIP_LARGE = True   # ecommerce already verified per file (42,448,764 + 67,501,979)

results = []
for table, path in sources.items():
    if SKIP_LARGE and table == "ecommerce_events":
        continue

    src = spark.read.option("header", True).csv(path)                 # raw file, no schema
    tgt = spark.table(f"{CATALOG}.bronze.{table}")                    # bronze table
    tgt_cols = [c for c in tgt.columns if not c.startswith("_")]      # ignore our audit columns

    src_rows, tgt_rows = src.count(), tgt.count()
    results.append((
        table,
        src_rows, tgt_rows, src_rows == tgt_rows,
        len(src.columns), len(tgt_cols), src.columns == tgt_cols,
    ))

display(spark.createDataFrame(results, [
    "table", "source_rows", "target_rows", "rows_match",
    "source_cols", "target_cols", "cols_match",
]))

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT 'ic_orders' AS t, COUNT(*) FROM dbw_kroger_insights.bronze.ic_orders WHERE _rescued_data IS NOT NULL
# MAGIC UNION ALL SELECT 'ic_products', COUNT(*) FROM dbw_kroger_insights.bronze.ic_products WHERE _rescued_data IS NOT NULL
# MAGIC UNION ALL SELECT 'ab_test', COUNT(*) FROM dbw_kroger_insights.bronze.ab_test WHERE _rescued_data IS NOT NULL

# COMMAND ----------

