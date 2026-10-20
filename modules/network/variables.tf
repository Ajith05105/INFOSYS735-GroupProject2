variable "environment" {
  type        = string
  description = "Environment name, used in resource names."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC. Must be a /16, because every subnet is carved out as a /24."

  validation {
    condition     = endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr must be a /16, for example 10.0.0.0/16."
  }
}

variable "nat_instance_type" {
  type        = string
  description = "Instance type for the NAT instances. The AMI architecture follows it automatically."
  default     = "t4g.micro"
}

variable "app_port" {
  type        = number
  description = "Port the app tier instances listen on, opened in the app tier NACL."
}

variable "origin_port" {
  type        = number
  description = "Port CloudFront uses to reach the internet-facing ALB: 443 with a domain, 80 without."
}
