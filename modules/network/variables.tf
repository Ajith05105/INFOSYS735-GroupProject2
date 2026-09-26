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
