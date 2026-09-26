# Network module

Creates the VPC and its subnets: one public and three private subnets in each of two Availability Zones.

This module only creates the VPC and subnets. It does not create an internet gateway, route tables or a NAT instance.

## Resources

- 1 VPC with DNS support and DNS hostnames enabled
- 8 subnets, all `/24`

With `vpc_cidr = "10.0.0.0/16"`:

| Subnet | Tier | AZ | CIDR | Intended for |
|---|---|---|---|---|
| `anygroup-dev-public-subnet-a` | public | first AZ | `10.0.0.0/24` | Web ALB, NAT instance |
| `anygroup-dev-public-subnet-b` | public | second AZ | `10.0.1.0/24` | Web ALB |
| `anygroup-dev-web-subnet-a` | web | first AZ | `10.0.10.0/24` | Web instances |
| `anygroup-dev-web-subnet-b` | web | second AZ | `10.0.11.0/24` | Web instances |
| `anygroup-dev-app-subnet-a` | app | first AZ | `10.0.20.0/24` | App ALB, app instances |
| `anygroup-dev-app-subnet-b` | app | second AZ | `10.0.21.0/24` | App ALB, app instances |
| `anygroup-dev-data-subnet-a` | data | first AZ | `10.0.30.0/24` | RDS, ElastiCache |
| `anygroup-dev-data-subnet-b` | data | second AZ | `10.0.31.0/24` | RDS, ElastiCache |

### How the addresses are laid out

The third octet of each subnet encodes where it is: the tens digit is the tier and the ones digit is the AZ.

- `10.0.2x.x` is always the app tier.
- `10.0.x1.x` is always the second AZ.

So `10.0.21.37` is an app instance in the second AZ. The gaps also leave room for a third AZ (`.2`, `.12`, `.22`, `.32`) without renumbering anything.

The subnets are defined as a table in `locals.subnets` in `main.tf`. To add or change a subnet, edit one line of that table.

## Usage

```hcl
module "network" {
  source      = "../../modules/network"
  environment = var.environment
  vpc_cidr    = var.vpc_cidr
}
```

## Inputs

| Name | Type | Required | Description |
|---|---|---|---|
| `environment` | `string` | yes | Environment name, used in resource names, for example `dev` |
| `vpc_cidr` | `string` | yes | CIDR block for the VPC. Must be a `/16`, because every subnet is a `/24`. |

Neither input has a default, on purpose. Each environment must pass its own values, so `prod` can never silently end up with `dev`'s address range.

## Outputs

| Name | Type | Description |
|---|---|---|
| `vpc_id` | `string` | ID of the VPC |
| `vpc_cidr` | `string` | CIDR block of the VPC |
| `public_subnet_ids` | `list(string)` | Public subnet IDs, one per AZ |
| `web_subnet_ids` | `list(string)` | Web tier subnet IDs, one per AZ |
| `app_subnet_ids` | `list(string)` | App tier subnet IDs, one per AZ |
| `data_subnet_ids` | `list(string)` | Data tier subnet IDs, one per AZ |

Pass them into other modules from `envs/dev/main.tf`:

```hcl
module "data" {
  source     = "../../modules/data"
  subnet_ids = module.network.data_subnet_ids
}
```

## Notes

- **AZs are looked up, not hardcoded.** The module uses the first two available AZs in the provider's region, so the same code works in any region.
- **No subnet assigns public IPs automatically,** including the public ones. The ALB gets its own public addresses, and anything else that needs one, like the NAT instance, has to ask for it explicitly. This keeps public IPv4 addresses to a minimum.
- **Cost:** VPCs and subnets are free.

## IAM permissions

These are already granted in `bootstrap/iam.tf`.

- **Deploy role:** `ec2:CreateVpc`, `ec2:DeleteVpc`, `ec2:ModifyVpcAttribute`, `ec2:CreateSubnet`, `ec2:DeleteSubnet`, `ec2:ModifySubnetAttribute`, `ec2:CreateTags`, `ec2:DeleteTags`, `ec2:Describe*`
- **Plan role:** `ec2:Describe*`
