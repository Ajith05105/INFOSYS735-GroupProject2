output "alb_dns_name" {
  description = "DNS name of the internet-facing ALB. Only answers requests from CloudFront."
  value       = aws_lb.web.dns_name
}
