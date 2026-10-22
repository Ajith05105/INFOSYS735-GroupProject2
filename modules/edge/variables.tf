variable "environment" {
  type        = string
  description = "Environment name, used in resource names."
}

variable "origin_domain" {
  type        = string
  description = "Hostname CloudFront uses for the web ALB: origin.<domain> with a domain, the ALB's DNS name without."
}

variable "origin_secret" {
  type        = string
  description = "Value of the X-Origin-Verify header the web ALB requires."
  sensitive   = true
}

variable "domain_name" {
  type        = string
  description = "Domain with a Route 53 hosted zone. Null serves the site on the cloudfront.net hostname."
  default     = null
}

variable "rate_limit" {
  type        = number
  description = "Requests per 5 minutes from one IP before WAF blocks it."
  default     = 1000
}
