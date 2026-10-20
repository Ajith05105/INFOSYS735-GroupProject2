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
