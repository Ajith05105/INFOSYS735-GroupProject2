output "site_url" {
  description = "Public URL of the site."
  value       = "https://${var.domain_name != null ? var.domain_name : aws_cloudfront_distribution.this.domain_name}"
}
