#!/bin/bash
# Web tier: Apache serving the storefront placeholder. Each instance shows its
# own ID and AZ so load balancing across AZs is visible on refresh.
set -euo pipefail

dnf install -y httpd

TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
meta() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
INSTANCE_ID=$(meta instance-id)
AZ=$(meta placement/availability-zone)

# Load balancer health check target
echo OK > /var/www/html/health

cat > /var/www/html/index.html <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>AnyGroupLLC New Zealand</title></head>
<body style="font-family: sans-serif; max-width: 40rem; margin: 3rem auto;">
  <h1>AnyGroupLLC New Zealand</h1>
  <p>Served by the web tier (Apache).</p>
  <table>
    <tr><th align="left">Instance</th><td>$INSTANCE_ID</td></tr>
    <tr><th align="left">Availability Zone</th><td>$AZ</td></tr>
  </table>
</body>
</html>
EOF

systemctl enable --now httpd
