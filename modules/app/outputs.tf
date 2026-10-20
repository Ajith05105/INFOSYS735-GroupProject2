output "alb_dns_name" {
  description = "DNS name of the internal ALB, which the web tier proxies /api/ to."
  value       = aws_lb.app.dns_name
}

output "asg_name" {
  description = "Name of the app Auto Scaling group."
  value       = aws_autoscaling_group.app.name
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix, the LoadBalancer dimension in CloudWatch."
  value       = aws_lb.app.arn_suffix
}

output "target_group_arn_suffix" {
  description = "Target group ARN suffix, the TargetGroup dimension in CloudWatch."
  value       = aws_lb_target_group.app.arn_suffix
}
