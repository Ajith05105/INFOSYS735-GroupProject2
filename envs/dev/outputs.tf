output "vpc_id" {
  description = "ID of the dev VPC."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs, one per AZ."
  value       = module.network.public_subnet_ids
}

output "web_subnet_ids" {
  description = "Web tier subnet IDs, one per AZ."
  value       = module.network.web_subnet_ids
}

output "app_subnet_ids" {
  description = "App tier subnet IDs, one per AZ."
  value       = module.network.app_subnet_ids
}

output "data_subnet_ids" {
  description = "Data tier subnet IDs, one per AZ."
  value       = module.network.data_subnet_ids
}

output "web_alb_dns_name" {
  description = "Internet-facing ALB. Only answers requests that come through CloudFront."
  value       = module.web.alb_dns_name
}

output "dashboard_name" {
  description = "CloudWatch dashboard for both tiers."
  value       = module.observability.dashboard_name
}

output "db_address" {
  description = "Oracle endpoint, reachable only from the app tier."
  value       = module.data.address
}

output "site_url" {
  description = "Public URL of the site, through CloudFront."
  value       = module.edge.site_url
}
