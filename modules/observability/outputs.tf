output "dashboard_name" {
  description = "CloudWatch dashboard with both tiers."
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}
