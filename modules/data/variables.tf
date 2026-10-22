variable "environment" {
  type        = string
  description = "Environment name, used in resource names."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private data subnets, one per AZ."
}

variable "db_sg_id" {
  type        = string
  description = "Security group for the database."
}

variable "instance_class" {
  type        = string
  description = "DB instance class. The Free plan only allows micro sizes; production sizing in the report is db.m6i.2xlarge."
  default     = "db.t4g.micro"
}

variable "db_name" {
  type        = string
  description = "PostgreSQL database name."
  default     = "anygroup"
}
