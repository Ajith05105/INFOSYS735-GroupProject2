variable "environment" {
  type        = string
  description = "Environment name, used in resource names."
}

variable "vpc_id" {
  type        = string
  description = "VPC the security groups belong to."
}

variable "app_port" {
  type        = number
  description = "Port the app tier instances listen on."
}
