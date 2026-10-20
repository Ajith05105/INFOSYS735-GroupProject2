variable "environment" {
  type        = string
  description = "Environment name, used in resource names."
}

variable "vpc_id" {
  type        = string
  description = "VPC to capture flow logs for."
}

variable "permissions_boundary_arn" {
  type        = string
  description = "Permissions boundary for the flow logs role."
}

variable "alert_email" {
  type        = string
  description = "Address subscribed to operational alerts. Null skips the subscription."
  default     = null
}

variable "tiers" {
  type = map(object({
    asg_name                = string
    alb_arn_suffix          = string
    target_group_arn_suffix = string
  }))
  description = "Load-balanced tiers to alarm on and chart, keyed by tier name."
}
