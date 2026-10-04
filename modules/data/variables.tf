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
  description = "DB instance class. Production sizing in the report is db.m6i.2xlarge. Check what oracle-se2 offers in the region before deploying."
  default     = "db.t3.small"
}

variable "db_name" {
  type        = string
  description = "Oracle database name, also the service name clients connect to. Up to 8 alphanumeric characters."
  default     = "ANYGRP"
}
