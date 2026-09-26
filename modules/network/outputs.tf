output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs, one per AZ. For the web ALB and the NAT instance."
  value       = [for key, subnet in aws_subnet.this : subnet.id if local.subnets[key].tier == "public"]
}

output "web_subnet_ids" {
  description = "Private web tier subnet IDs, one per AZ."
  value       = [for key, subnet in aws_subnet.this : subnet.id if local.subnets[key].tier == "web"]
}

output "app_subnet_ids" {
  description = "Private app tier subnet IDs, one per AZ. For the app ALB and app instances."
  value       = [for key, subnet in aws_subnet.this : subnet.id if local.subnets[key].tier == "app"]
}

output "data_subnet_ids" {
  description = "Private data tier subnet IDs, one per AZ. For RDS and ElastiCache subnet groups."
  value       = [for key, subnet in aws_subnet.this : subnet.id if local.subnets[key].tier == "data"]
}
