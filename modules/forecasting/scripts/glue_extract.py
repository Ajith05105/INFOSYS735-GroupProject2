"""Glue job: copy sales and inventory out of Oracle into the data lake.

This is the CQRS sync step. The query side (data lake, forecasting, risk
checks) reads this copy, never the live transactional database, so analysis
cannot slow checkout. One read per table, scheduled overnight.

raw/      the tables as extracted, in Parquet
curated/  sales_daily: units sold per product per day (forecast input)
          inventory:   stock batches with product details and expiry dates
"""

import sys

from awsglue.context import GlueContext
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F

args = getResolvedOptions(sys.argv, ["CONNECTION_NAME", "BUCKET"])
glue = GlueContext(SparkContext.getOrCreate())
lake = f"s3://{args['BUCKET']}"


def extract(table):
    """Read one Oracle table through the Glue connection and land it in raw/."""
    frame = glue.create_dynamic_frame.from_options(
        connection_type="oracle",
        connection_options={
            "useConnectionProperties": "true",
            "connectionName": args["CONNECTION_NAME"],
            "dbtable": table,
        },
    )
    df = frame.toDF()
    df.write.mode("overwrite").parquet(f"{lake}/raw/{table.lower()}/")
    return df


products = extract("PRODUCTS")
sales = extract("SALES")
batches = extract("INVENTORY_BATCH")

daily = (
    sales.groupBy("PRODUCT_ID", F.to_date("SALE_DATE").alias("DAY"))
    .agg(F.sum("QUANTITY").cast("int").alias("QUANTITY"))
    .orderBy("PRODUCT_ID", "DAY")
)
daily.coalesce(1).write.mode("overwrite").option("header", True).csv(f"{lake}/curated/sales_daily/")

inventory = batches.join(products, "PRODUCT_ID").select(
    "PRODUCT_ID",
    "NAME",
    "PERISHABLE",
    "BATCH_ID",
    F.col("QUANTITY_ON_HAND").cast("int").alias("QUANTITY_ON_HAND"),
    F.to_date("EXPIRY_DATE").alias("EXPIRY_DATE"),
)
inventory.coalesce(1).write.mode("overwrite").option("header", True).csv(f"{lake}/curated/inventory/")
