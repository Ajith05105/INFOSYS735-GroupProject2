variable "environment" {
  type        = string
  description = "Environment name, used in resource names and tags."
  default     = "dev"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for this environment's VPC."
  default     = "10.0.0.0/16"
}

variable "app_port" {
  type        = number
  description = "Port the app tier instances listen on. Shared by the network NACLs and the app tier."
  default     = 8080
}

variable "domain_name" {
  type        = string
  description = "Domain with a Route 53 hosted zone in this account, e.g. anygroup-demo.click. Null means no domain: CloudFront reaches the ALB over HTTP, since no certificate can match the ALB's AWS hostname. Viewers always reach CloudFront over HTTPS."
  default     = null
}

variable "alert_email" {
  type        = string
  description = "Email subscribed to operational alerts (scaling events, alarms). Null skips the subscription."
  default     = null
}
