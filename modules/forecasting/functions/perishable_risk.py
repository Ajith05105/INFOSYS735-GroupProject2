"""Lambda: turn a demand forecast into perishable stock actions (BR18).

Triggered when SageMaker writes a forecast to curated/forecasts/. For each
perishable product it compares predicted demand over the forecast window
with stock on hand and stock that expires inside the window:

  MARKDOWN  more stock expires in the window than will sell: discount the
            surplus now instead of binning it later
  REORDER   total stock will not cover predicted demand: order the gap

Recommendations go to DynamoDB (history per product) and one SNS alert
goes to store and procurement managers. Reads only the query side, so it
never touches checkout.
"""

import csv
import io
import os
from collections import defaultdict
from datetime import datetime, timezone
from decimal import Decimal

TOLERANCE = 0.1  # ignore gaps within 10 percent of demand


def recommend(forecast, inventory, tolerance=TOLERANCE):
    """Return (recommendations, window_end) from forecast and inventory CSV rows."""
    window_end = max(row["DAY"][:10] for row in forecast)

    demand = defaultdict(float)
    for row in forecast:
        demand[row["PRODUCT_ID"]] += float(row["PREDICTED_QUANTITY"])

    products = {}
    for row in inventory:
        product = products.setdefault(row["PRODUCT_ID"], {
            "name": row["NAME"],
            "perishable": row["PERISHABLE"].strip() == "Y",
            "on_hand": 0.0,
            "expiring": 0.0,
        })
        quantity = float(row["QUANTITY_ON_HAND"])
        product["on_hand"] += quantity
        if row["EXPIRY_DATE"][:10] <= window_end:
            product["expiring"] += quantity

    recommendations = []
    for product_id, product in sorted(products.items()):
        if not product["perishable"] or product_id not in demand:
            continue
        predicted = demand[product_id]
        if product["expiring"] > predicted * (1 + tolerance):
            action, quantity = "MARKDOWN", product["expiring"] - predicted
        elif product["on_hand"] < predicted * (1 - tolerance):
            action, quantity = "REORDER", predicted - product["on_hand"]
        else:
            continue
        recommendations.append({
            "product_id": product_id,
            "name": product["name"],
            "action": action,
            "quantity": round(quantity),
            "predicted_demand": round(predicted),
            "on_hand": round(product["on_hand"]),
            "expiring_in_window": round(product["expiring"]),
        })
    return recommendations, window_end


def read_csv_rows(s3, bucket, prefix):
    rows = []
    listing = s3.list_objects_v2(Bucket=bucket, Prefix=prefix)
    for item in listing.get("Contents", []):
        if item["Key"].endswith(".csv"):
            body = s3.get_object(Bucket=bucket, Key=item["Key"])["Body"].read().decode()
            rows.extend(csv.DictReader(io.StringIO(body)))
    return rows


def handler(event, context):
    import boto3

    s3 = boto3.client("s3")
    bucket = event["Records"][0]["s3"]["bucket"]["name"]
    forecast = read_csv_rows(s3, bucket, "curated/forecasts/")
    inventory = read_csv_rows(s3, bucket, "curated/inventory/")

    recommendations, window_end = recommend(forecast, inventory)
    generated_at = datetime.now(timezone.utc).isoformat(timespec="seconds")

    table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
    with table.batch_writer() as batch:
        for rec in recommendations:
            batch.put_item(Item={
                **{k: Decimal(v) if isinstance(v, int) else v for k, v in rec.items()},
                "generated_at": generated_at,
                "window_end": window_end,
            })

    if recommendations:
        lines = [
            f"{r['action']:<8} {r['name']}: {r['quantity']} units "
            f"(predicted demand {r['predicted_demand']}, on hand {r['on_hand']}, "
            f"expiring by {window_end}: {r['expiring_in_window']})"
            for r in recommendations
        ]
        boto3.client("sns").publish(
            TopicArn=os.environ["TOPIC_ARN"],
            Subject=f"Perishable stock actions to {window_end}",
            Message="\n".join(lines),
        )

    print(f"{len(recommendations)} recommendations up to {window_end}")
    return {"recommendations": len(recommendations), "window_end": window_end}
