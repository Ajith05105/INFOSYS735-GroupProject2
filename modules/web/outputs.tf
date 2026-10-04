output "alb_dns_name" {
  description = "DNS name of the internet-facing ALB. Only answers requests from CloudFront."
  value       = aws_lb.web.dns_name
}

output "asg_name" {
  description = "Name of the web Auto Scaling group."
  value       = aws_autoscaling_group.web.name
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix, the LoadBalancer dimension in CloudWatch."
  value       = aws_lb.web.arn_suffix
}

output "target_group_arn_suffix" {
  description = "Target group ARN suffix, the TargetGroup dimension in CloudWatch."
  value       = aws_lb_target_group.web.arn_suffix
}
