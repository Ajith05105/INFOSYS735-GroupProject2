output "alb_sg_id" {
  description = "Security group for the internet-facing ALB."
  value       = aws_security_group.this["alb"].id
}

output "web_sg_id" {
  description = "Security group for the web tier instances."
  value       = aws_security_group.this["web"].id
}

output "app_alb_sg_id" {
  description = "Security group for the internal ALB."
  value       = aws_security_group.this["app-alb"].id
}

output "app_sg_id" {
  description = "Security group for the app tier instances."
  value       = aws_security_group.this["app"].id
}

output "db_sg_id" {
  description = "Security group for the RDS Oracle instance."
  value       = aws_security_group.this["db"].id
}

output "web_instance_profile" {
  description = "Instance profile name for the web tier."
  value       = aws_iam_instance_profile.instance["web"].name
}

output "app_instance_profile" {
  description = "Instance profile name for the app tier."
  value       = aws_iam_instance_profile.instance["app"].name
}
