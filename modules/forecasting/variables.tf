variable "environment" {
  type        = string
  description = "Environment name, used in resource names."
}

variable "permissions_boundary_arn" {
  type        = string
  description = "Boundary that every role created here must carry."
}

variable "glue_subnet_id" {
  type        = string
  description = "Private app subnet the Glue connection runs in. Needs the S3 endpoint and NAT."
}

variable "db_sg_id" {
  type        = string
  description = "Database security group. Glue is allowed in on the PostgreSQL port."
}

variable "db_host" {
  type        = string
  description = "PostgreSQL endpoint."
}

variable "db_name" {
  type        = string
  description = "PostgreSQL database name."
}

variable "db_secret_arn" {
  type        = string
  description = "Secrets Manager secret with the database credentials."
}

variable "app_role_name" {
  type        = string
  description = "App tier role, granted read access to the database secret to seed sample data."
}

variable "alert_email" {
  type        = string
  description = "Address subscribed to perishable stock alerts. Null skips the subscription."
  default     = null
}
