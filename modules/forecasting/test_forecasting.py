"""Checks for the forecast model and the risk rules. Run: python test_forecasting.py"""

import sys
from pathlib import Path

here = Path(__file__).parent
sys.path[:0] = [str(here / "scripts"), str(here / "functions")]

from forecast import holt_winters  # noqa: E402
from perishable_risk import recommend  # noqa: E402


def test_holt_winters_repeats_a_flat_weekly_pattern():
    week = [10, 10, 10, 10, 12, 15, 15]
    forecast = holt_winters(week * 8, season=7, horizon=7)
    assert all(abs(f - w) < 0.5 for f, w in zip(forecast, week)), forecast


def test_holt_winters_follows_a_trend():
    forecast = holt_winters([float(i) for i in range(56)], season=7, horizon=3)
    assert all(abs(f - (56 + k)) < 2 for k, f in enumerate(forecast)), forecast


def test_recommend_marks_down_reorders_and_ignores():
    forecast = [
        {"PRODUCT_ID": pid, "DAY": f"2026-10-{d:02d}", "PREDICTED_QUANTITY": "10"}
        for pid in ["P01", "P03", "P05", "P06"]
        for d in range(1, 15)
    ]  # 140 units of demand each, window ends 2026-10-14
    inventory = [
        {"PRODUCT_ID": "P01", "NAME": "Milk", "PERISHABLE": "Y", "QUANTITY_ON_HAND": "50", "EXPIRY_DATE": "2026-10-05"},
        {"PRODUCT_ID": "P03", "NAME": "Strawberries", "PERISHABLE": "Y", "QUANTITY_ON_HAND": "300", "EXPIRY_DATE": "2026-10-04"},
        {"PRODUCT_ID": "P05", "NAME": "Yoghurt", "PERISHABLE": "Y", "QUANTITY_ON_HAND": "145", "EXPIRY_DATE": "2026-10-20"},
        {"PRODUCT_ID": "P06", "NAME": "Rice", "PERISHABLE": "N", "QUANTITY_ON_HAND": "1", "EXPIRY_DATE": "2027-10-01"},
    ]
    recs, window_end = recommend(forecast, inventory)
    assert window_end == "2026-10-14"
    assert [(r["product_id"], r["action"], r["quantity"]) for r in recs] == [
        ("P01", "REORDER", 90),
        ("P03", "MARKDOWN", 160),
    ], recs


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print("ok", name)
