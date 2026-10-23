"""Glue job: forecast daily demand per product.

Replaces Amazon Forecast, which is closed to new customers. Reads the
curated daily sales the extract job produced and writes a 14-day forecast
per product to the curated zone, where it triggers the perishable risk check.

Model: additive Holt-Winters with weekly seasonality, which captures the
level, trend and weekend peaks a supermarket sees.
ponytail: fixed smoothing constants. Fit them per product once there is
enough real history to tune against.
"""

import sys

INPUT = "curated/sales_daily/"
OUTPUT = "curated/forecasts/demand.csv"
SEASON = 7  # days
HORIZON = 14  # days


def holt_winters(y, season, horizon, alpha=0.3, beta=0.05, gamma=0.2):
    """Additive Holt-Winters forecast. Needs at least two full seasons of history."""
    level = sum(y[:season]) / season
    trend = (sum(y[season : 2 * season]) - sum(y[:season])) / season**2
    seasonal = [v - level for v in y[:season]]

    for t in range(season, len(y)):
        s = seasonal[t - season]
        previous = level
        level = alpha * (y[t] - s) + (1 - alpha) * (level + trend)
        trend = beta * (level - previous) + (1 - beta) * trend
        seasonal.append(gamma * (y[t] - level) + (1 - gamma) * s)

    n = len(y)
    return [level + (k + 1) * trend + seasonal[n - season + (k % season)] for k in range(horizon)]


def main():
    import io

    import boto3
    import pandas as pd
    from awsglue.utils import getResolvedOptions

    bucket = getResolvedOptions(sys.argv, ["BUCKET"])["BUCKET"]
    s3 = boto3.client("s3")

    # The extract writes one CSV part file per run
    listing = s3.list_objects_v2(Bucket=bucket, Prefix=INPUT).get("Contents", [])
    keys = [o["Key"] for o in listing if o["Key"].endswith(".csv")]
    sales = pd.concat(
        pd.read_csv(io.BytesIO(s3.get_object(Bucket=bucket, Key=key)["Body"].read())) for key in keys
    )
    sales["DAY"] = pd.to_datetime(sales["DAY"])

    rows = []
    for product_id, group in sales.groupby("PRODUCT_ID"):
        # Days with no sales are real zeros, not missing data
        series = group.set_index("DAY")["QUANTITY"].asfreq("D", fill_value=0)
        start = series.index[-1] + pd.Timedelta(days=1)
        for k, quantity in enumerate(holt_winters(series.astype(float).tolist(), SEASON, HORIZON)):
            rows.append({
                "PRODUCT_ID": product_id,
                "DAY": (start + pd.Timedelta(days=k)).date().isoformat(),
                "PREDICTED_QUANTITY": round(max(quantity, 0.0), 1),
            })

    s3.put_object(Bucket=bucket, Key=OUTPUT, Body=pd.DataFrame(rows).to_csv(index=False))
    print(f"Wrote {len(rows)} forecast rows for {sales['PRODUCT_ID'].nunique()} products")


if __name__ == "__main__":
    main()
