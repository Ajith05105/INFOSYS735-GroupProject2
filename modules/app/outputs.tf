output "alb_dns_name" {
  description = "DNS name of the internal ALB, which the web tier proxies /api/ to."
  value       = aws_lb.app.dns_name
}
