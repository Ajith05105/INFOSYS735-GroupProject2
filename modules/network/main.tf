data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  # First two AZs in the region, keyed by letter
  azs = {
    a = data.aws_availability_zones.available.names[0]
    b = data.aws_availability_zones.available.names[1]
  }

  # One public and three private subnets per AZ. Each is a /24 inside the /16,
  # where netnum is the third octet: 10.0.<netnum>.0/24. The tens digit is the
  # tier and the ones digit is the AZ.
  subnets = {
    public-a = { tier = "public", az = "a", netnum = 0 }
    public-b = { tier = "public", az = "b", netnum = 1 }
    web-a    = { tier = "web", az = "a", netnum = 10 }
    web-b    = { tier = "web", az = "b", netnum = 11 }
    app-a    = { tier = "app", az = "a", netnum = 20 }
    app-b    = { tier = "app", az = "b", netnum = 21 }
    data-a   = { tier = "data", az = "a", netnum = 30 }
    data-b   = { tier = "data", az = "b", netnum = 31 }
  }

  # CIDR lists per tier, used by the NACL rules
  tier_cidrs = {
    for tier in ["public", "web", "app", "data"] :
    tier => [for s in local.subnets : cidrsubnet(var.vpc_cidr, 8, s.netnum) if s.tier == tier]
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "anygroup-${var.environment}-network-vpc"
  }
}

# No subnet assigns public IPs automatically. The ALB gets its own, and the
# NAT instance should request one explicitly in its own resource block.
resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[each.value.az]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, each.value.netnum)

  tags = {
    Name = "anygroup-${var.environment}-${each.value.tier}-subnet-${each.value.az}"
    Tier = each.value.tier
  }
}

# Public routing: public subnets go straight out through the internet gateway

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "anygroup-${var.environment}-network-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "anygroup-${var.environment}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  for_each = { for key, s in local.subnets : key => s if s.tier == "public" }

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.public.id
}

# NAT instances, one per AZ, so neither AZ depends on the other for outbound
# access and no traffic crosses AZs. Instances rather than NAT gateways for cost.
# ponytail: no auto-recovery. If one dies, its AZ loses outbound access until it
# is replaced. Wrap each in a single-instance ASG if that matters beyond the demo.

data "aws_ec2_instance_type" "nat" {
  instance_type = var.nat_instance_type
}

# Latest Amazon Linux 2023 for whichever CPU architecture the NAT type uses
data "aws_ami" "nat" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*"]
  }

  filter {
    name   = "architecture"
    values = [data.aws_ec2_instance_type.nat.supported_architectures[0]]
  }
}

resource "aws_security_group" "nat" {
  name        = "anygroup-${var.environment}-nat-sg"
  description = "NAT instances: forward any traffic from inside the VPC"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "Anything from inside the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Out to the internet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "anygroup-${var.environment}-nat-sg"
  }
}

resource "aws_instance" "nat" {
  for_each = local.azs

  ami                         = data.aws_ami.nat.id
  instance_type               = var.nat_instance_type
  subnet_id                   = aws_subnet.this["public-${each.key}"].id
  vpc_security_group_ids      = [aws_security_group.nat.id]
  associate_public_ip_address = true
  source_dest_check           = false # must forward traffic not addressed to itself

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  # Turn on forwarding and masquerade everything leaving the public interface.
  # iptables-services ships a FORWARD reject rule, so that chain is flushed.
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    dnf install -y iptables-services
    echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/90-nat.conf
    sysctl -p /etc/sysctl.d/90-nat.conf
    systemctl enable --now iptables
    iface=$(ip route show default | awk '{print $5; exit}')
    iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
    iptables -F FORWARD
    service iptables save
  EOT

  tags = {
    Name = "anygroup-${var.environment}-nat-instance-${each.key}"
  }

  # The package install above needs the internet route to exist at boot
  depends_on = [aws_route_table_association.public]
}

# Private routing: web and app subnets go out through their own AZ's NAT
# instance. The data tier gets a route table with no default route at all, so
# the database has no path to the internet in either direction.

resource "aws_route_table" "private" {
  for_each = local.azs

  vpc_id = aws_vpc.this.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.nat[each.key].primary_network_interface_id
  }

  tags = {
    Name = "anygroup-${var.environment}-private-rt-${each.key}"
  }
}

resource "aws_route_table_association" "private" {
  for_each = { for key, s in local.subnets : key => s if contains(["web", "app"], s.tier) }

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.private[each.value.az].id
}

resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "anygroup-${var.environment}-data-rt"
  }
}

resource "aws_route_table_association" "data" {
  for_each = { for key, s in local.subnets : key => s if s.tier == "data" }

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.data.id
}

# S3 traffic from the web and app tiers skips the NAT instances. Gateway
# endpoints have no hourly charge.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.private : rt.id]

  tags = {
    Name = "anygroup-${var.environment}-s3-endpoint"
  }
}

# Network ACLs: coarse and stateless, one per tier. Each tier accepts its own
# port from the tier in front of it, plus return traffic. Security groups are
# the primary control; these are the second layer.

locals {
  # Linux ephemeral ports, where replies to connections a private instance
  # opened arrive (from the internet via NAT, or from the next tier down)
  replies = { protocol = "tcp", from = 32768, to = 60999, cidr = "0.0.0.0/0" }
  all_out = { protocol = "-1", from = 0, to = 0, cidr = "0.0.0.0/0" }

  nacl_rules = {
    public = {
      ingress = [
        { protocol = "tcp", from = 443, to = 443, cidr = "0.0.0.0/0" },    # CloudFront to the ALB, HTTPS only
        { protocol = "tcp", from = 1024, to = 65535, cidr = "0.0.0.0/0" }, # replies to the NAT and ALB
        { protocol = "-1", from = 0, to = 0, cidr = var.vpc_cidr },        # private tiers heading out through NAT
      ]
      egress = [local.all_out]
    }

    web = {
      ingress = concat(
        [for c in local.tier_cidrs.public : { protocol = "tcp", from = 80, to = 80, cidr = c }], # ALB to Apache
        [local.replies],
      )
      egress = [local.all_out]
    }

    app = {
      ingress = concat(
        [for c in local.tier_cidrs.web : { protocol = "tcp", from = 80, to = 80, cidr = c }],                     # web to the internal ALB
        [for c in local.tier_cidrs.app : { protocol = "tcp", from = var.app_port, to = var.app_port, cidr = c }], # internal ALB to app, across AZs
        [local.replies],
      )
      egress = [local.all_out]
    }

    # Only Oracle traffic with the app tier, plus primary/standby traffic
    # between the two data subnets. No internet in either direction.
    data = {
      ingress = concat(
        [for c in local.tier_cidrs.app : { protocol = "tcp", from = 1521, to = 1521, cidr = c }],
        [for c in local.tier_cidrs.data : { protocol = "-1", from = 0, to = 0, cidr = c }],
      )
      egress = concat(
        [for c in local.tier_cidrs.app : { protocol = "tcp", from = 1024, to = 65535, cidr = c }],
        [for c in local.tier_cidrs.data : { protocol = "-1", from = 0, to = 0, cidr = c }],
      )
    }
  }
}

resource "aws_network_acl" "this" {
  for_each = local.nacl_rules

  vpc_id     = aws_vpc.this.id
  subnet_ids = [for key, s in local.subnets : aws_subnet.this[key].id if s.tier == each.key]

  dynamic "ingress" {
    for_each = each.value.ingress

    content {
      rule_no    = 100 + ingress.key * 10
      action     = "allow"
      protocol   = ingress.value.protocol
      from_port  = ingress.value.from
      to_port    = ingress.value.to
      cidr_block = ingress.value.cidr
    }
  }

  dynamic "egress" {
    for_each = each.value.egress

    content {
      rule_no    = 100 + egress.key * 10
      action     = "allow"
      protocol   = egress.value.protocol
      from_port  = egress.value.from
      to_port    = egress.value.to
      cidr_block = egress.value.cidr
    }
  }

  tags = {
    Name = "anygroup-${var.environment}-${each.key}-nacl"
  }
}
