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
