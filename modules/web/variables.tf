variable "environment" {
  type        = string
  description = "Environment name, used in resource names."
}

variable "vpc_id" {
  type        = string
  description = "VPC for the target group."
}

variable "alb_subnet_ids" {
  type        = list(string)
  description = "Public subnets for the internet-facing ALB, one per AZ."
}

variable "instance_subnet_ids" {
  type        = list(string)
  description = "Private web tier subnets for the instances, one per AZ."
}

variable "alb_sg_id" {
  type        = string
  description = "Security group for the internet-facing ALB."
}

variable "instance_sg_id" {
  type        = string
  description = "Security group for the web instances."
}

variable "instance_profile" {
  type        = string
  description = "Instance profile name for the web instances."
}

variable "domain_name" {
  type        = string
  description = "Domain with a Route 53 hosted zone. Null runs the ALB listener on HTTP 80 instead of HTTPS 443."
  default     = null
}

variable "instance_type" {
  type        = string
  description = "Web instance type. Production sizing in the report is c7i.large."
  default     = "t4g.micro"
}

variable "min_size" {
  type        = number
  description = "Minimum and baseline instance count. Two keeps one per AZ."
  default     = 2
}

variable "max_size" {
  type        = number
  description = "Maximum instance count. The report's production value is 12."
  default     = 4
}
