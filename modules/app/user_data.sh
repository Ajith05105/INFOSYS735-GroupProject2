#!/bin/bash
# App tier: stand-in for the .NET Core backend. A small HTTP service that
# reports which instance and AZ answered, and whether the Oracle port on the
# database is reachable, which proves the web -> app -> db chain end to end.
# ponytail: TCP check only. Real queries arrive with the forecasting feature.
set -euo pipefail

TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
meta() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }

mkdir -p /opt/anygroup-app
cat > /opt/anygroup-app/server.py <<'PY'
import json
import os
import socket
from http.server import BaseHTTPRequestHandler, HTTPServer

INSTANCE = os.environ["INSTANCE_ID"]
AZ = os.environ["AZ"]
DB_HOST = os.environ.get("DB_HOST", "")


def database_status():
    if not DB_HOST:
        return "not configured"
    try:
        socket.create_connection((DB_HOST, 1521), timeout=2).close()
        return "reachable"
    except OSError:
        return "unreachable"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            body, kind = b"OK", "text/plain"
        else:
            body = json.dumps({
                "tier": "app (.NET Core stand-in)",
                "instance": INSTANCE,
                "az": AZ,
                "database": database_status(),
            }).encode()
            kind = "application/json"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.end_headers()
        self.wfile.write(body)


HTTPServer(("", int(os.environ["PORT"])), Handler).serve_forever()
PY

cat > /etc/systemd/system/anygroup-app.service <<EOF
[Unit]
Description=AnyGroupLLC app tier stand-in
After=network-online.target

[Service]
Environment=INSTANCE_ID=$(meta instance-id)
Environment=AZ=$(meta placement/availability-zone)
Environment=DB_HOST=${db_host}
Environment=PORT=${app_port}
ExecStart=/usr/bin/python3 /opt/anygroup-app/server.py
Restart=always
User=nobody

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now anygroup-app

# Seed the sample retail data the forecasting feature reads: products, 120
# days of daily sales, and stock batches with expiry dates. Every instance
# runs this; the first to create the tables loads them and the rest skip.
if [ -n "${db_secret_arn}" ]; then
  dnf install -y python3-pip
  pip3 install --quiet oracledb boto3
  cat > /opt/anygroup-app/seed.py <<'PY'
import datetime as dt
import json
import random
import time

import boto3
import oracledb

SECRET_ARN = "${db_secret_arn}"
REGION = "${aws_region}"
DSN = "${db_host}:1521/${db_name}"

# id, name, perishable, typical units sold per day
PRODUCTS = [
    ("P01", "Milk 2L", "Y", 60),
    ("P02", "Sourdough loaf", "Y", 40),
    ("P03", "Strawberries 250g", "Y", 35),
    ("P04", "Baby spinach 120g", "Y", 25),
    ("P05", "Greek yoghurt 1kg", "Y", 30),
    ("P06", "Jasmine rice 5kg", "N", 15),
    ("P07", "Canned chickpeas", "N", 20),
    ("P08", "Penne pasta 500g", "N", 18),
]
WEEKDAY_FACTOR = [1.0, 1.0, 1.0, 1.0, 1.15, 1.3, 1.3]  # Monday..Sunday


def connect():
    # Retries cover the database still starting and IAM still propagating
    for _ in range(20):
        try:
            secret = boto3.client("secretsmanager", region_name=REGION).get_secret_value(SecretId=SECRET_ARN)
            creds = json.loads(secret["SecretString"])
            return oracledb.connect(user=creds["username"], password=creds["password"], dsn=DSN)
        except Exception as error:
            print("waiting for database:", error, flush=True)
            time.sleep(30)
    raise SystemExit("database never became reachable")


conn = connect()
cur = conn.cursor()
try:
    cur.execute("CREATE TABLE PRODUCTS (PRODUCT_ID VARCHAR2(10) PRIMARY KEY, NAME VARCHAR2(50), PERISHABLE CHAR(1))")
except oracledb.DatabaseError as error:
    if error.args[0].code == 955:  # ORA-00955: name already used
        raise SystemExit("already seeded")
    raise
cur.execute("CREATE TABLE SALES (SALE_DATE DATE, PRODUCT_ID VARCHAR2(10), QUANTITY NUMBER)")
cur.execute("CREATE TABLE INVENTORY_BATCH (BATCH_ID VARCHAR2(20) PRIMARY KEY, PRODUCT_ID VARCHAR2(10), QUANTITY_ON_HAND NUMBER, EXPIRY_DATE DATE)")

cur.executemany("INSERT INTO PRODUCTS VALUES (:1, :2, :3)", [p[:3] for p in PRODUCTS])

random.seed(42)
today = dt.date.today()
sales = []
for i in range(120):
    day = today - dt.timedelta(days=120 - i)
    for pid, _, _, base in PRODUCTS:
        expected = base * WEEKDAY_FACTOR[day.weekday()] * (1 + 0.002 * i)
        sales.append((day, pid, max(0, round(random.gauss(expected, base * 0.08)))))
cur.executemany("INSERT INTO SALES VALUES (:1, :2, :3)", sales)

# Two batches per perishable line, sized to cover the next fortnight's demand
# (about 20 days of base sales once the sales trend is included),
# except two deliberate problems for the demo: strawberries are overstocked
# and about to expire (markdown), milk is understocked (reorder).
batches = []
for pid, _, perishable, base in PRODUCTS:
    if perishable == "N":
        batches.append((pid + "-B1", pid, base * 30, today + dt.timedelta(days=365)))
    elif pid == "P03":
        batches += [(pid + "-B1", pid, 600, today + dt.timedelta(days=4)), (pid + "-B2", pid, 300, today + dt.timedelta(days=9))]
    elif pid == "P01":
        batches.append((pid + "-B1", pid, 150, today + dt.timedelta(days=7)))
    else:
        batches += [(pid + "-B1", pid, base * 10, today + dt.timedelta(days=5)), (pid + "-B2", pid, base * 10, today + dt.timedelta(days=12))]
cur.executemany("INSERT INTO INVENTORY_BATCH VALUES (:1, :2, :3, :4)", batches)

conn.commit()
print(f"seeded {len(sales)} sales rows and {len(batches)} batches", flush=True)
PY
  python3 /opt/anygroup-app/seed.py >> /var/log/anygroup-seed.log 2>&1 || true
fi
