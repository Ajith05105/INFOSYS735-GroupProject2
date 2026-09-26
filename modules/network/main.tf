data "aws_availability_zones" "available" {
  state = "available"
}

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
