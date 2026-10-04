variable "environment" {
  type        = string
  description = "Environment name, used in resource names."
}

variable "vpc_id" {
  type        = string
  description = "VPC for the target group."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private app tier subnets for the internal ALB and the instances, one per AZ."
}

variable "alb_sg_id" {
  type        = string
  description = "Security group for the internal ALB."
}

variable "instance_sg_id" {
  type        = string
  description = "Security group for the app instances."
}

variable "instance_profile" {
  type        = string
  description = "Instance profile name for the app instances."
}

variable "app_port" {
  type        = number
  description = "Port the app instances listen on."
}

variable "db_host" {
  type        = string
  description = "Database endpoint the app tier checks for reachability. Empty until the data tier exists."
  default     = ""
}

variable "instance_type" {
  type        = string
  description = "App instance type. Production sizing in the report is m7i.xlarge."
  default     = "t4g.micro"
}

variable "min_size" {
  type        = number
  description = "Minimum and baseline instance count. Two keeps one per AZ."
  default     = 2
}

variable "max_size" {
  type        = number
  description = "Maximum instance count. The report's production value is 16."
  default     = 4
}

variable "db_name" {
  type        = string
  description = "Oracle database (service) name, for seeding sample data."
  default     = ""
}

variable "db_secret_arn" {
  type        = string
  description = "Secret with the database credentials. Empty skips seeding sample data."
  default     = ""
}
