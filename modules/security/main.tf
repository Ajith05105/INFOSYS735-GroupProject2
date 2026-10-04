data "aws_caller_identity" "current" {}

# CloudFront's origin-facing IP ranges, maintained by AWS
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

locals {
  oracle_port = 1521

  # Created by bootstrap. Every role here must carry it.
  boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/anygroup/anygroup-workload-boundary"
}

# Security groups, chained so each tier accepts traffic only from the security
# group in front of it rather than from an IP range. The rules stay correct as
# Auto Scaling replaces instances. Terraform removes AWS's default allow-all
# egress, so every outbound path below is explicit too.

resource "aws_security_group" "this" {
  for_each = {
    alb     = "Internet-facing ALB: HTTPS from CloudFront only"
    web     = "Web tier (Apache): HTTP from the internet-facing ALB only"
    app-alb = "Internal ALB: HTTP from the web tier only"
    app     = "App tier (.NET Core): app port from the internal ALB only"
    db      = "Data tier (RDS Oracle): Oracle from the app tier only"
  }

  name        = "anygroup-${var.environment}-${each.key}-sg"
  description = each.value
  vpc_id      = var.vpc_id

  tags = {
    Name = "anygroup-${var.environment}-${each.key}-sg"
  }
}

locals {
  sg = { for key, group in aws_security_group.this : key => group.id }

  # peer is the security group on the other end of the rule. The one ingress
  # rule without a peer uses the CloudFront prefix list instead.
  ingress = {
    alb-from-cloudfront = { sg = "alb", port = var.origin_port, peer = null }
    web-from-alb        = { sg = "web", port = 80, peer = "alb" }
    app-alb-from-web    = { sg = "app-alb", port = 80, peer = "web" }
    app-from-app-alb    = { sg = "app", port = var.app_port, peer = "app-alb" }
    db-from-app         = { sg = "db", port = local.oracle_port, peer = "app" }
  }

  # Rules without a peer go to any address on 443: packages, Systems Manager,
  # Secrets Manager and S3. The database has no egress rules at all.
  egress = {
    alb-to-web     = { sg = "alb", port = 80, peer = "web" }
    web-to-app-alb = { sg = "web", port = 80, peer = "app-alb" }
    web-to-https   = { sg = "web", port = 443, peer = null }
    app-alb-to-app = { sg = "app-alb", port = var.app_port, peer = "app" }
    app-to-db      = { sg = "app", port = local.oracle_port, peer = "db" }
    app-to-https   = { sg = "app", port = 443, peer = null }
  }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = local.ingress

  security_group_id            = local.sg[each.value.sg]
  description                  = each.key
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = each.value.peer == null ? null : local.sg[each.value.peer]
  prefix_list_id               = each.value.peer == null ? data.aws_ec2_managed_prefix_list.cloudfront.id : null
}

resource "aws_vpc_security_group_egress_rule" "this" {
  for_each = local.egress

  security_group_id            = local.sg[each.value.sg]
  description                  = each.key
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = each.value.peer == null ? null : local.sg[each.value.peer]
  cidr_ipv4                    = each.value.peer == null ? "0.0.0.0/0" : null
}

# Instance roles, one per tier so each gets only what its function needs.
# Both start with Systems Manager access: Session Manager replaces SSH and
# bastion hosts (no inbound port anywhere), and Patch Manager can patch them.
# Tier-specific permissions are attached by the modules that need them.

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  for_each = toset(["web", "app"])

  name                 = "anygroup-${var.environment}-${each.key}-instance-role"
  path                 = "/anygroup/"
  assume_role_policy   = data.aws_iam_policy_document.ec2_trust.json
  permissions_boundary = local.boundary_arn
}

resource "aws_iam_role_policy_attachment" "ssm" {
  for_each = aws_iam_role.instance

  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  for_each = aws_iam_role.instance

  name = each.value.name
  path = "/anygroup/"
  role = each.value.name
}
