variable "aws_region" {
  type        = string
  description = "AWS region for bootstrap resources. Must match the region in the backend block."
  default     = "ap-southeast-6"
}

variable "github_repository" {
  type        = string
  description = "GitHub repository allowed to assume the CI roles, in owner/name form."
  default     = "Ajith05105/INFOSYS735-GroupProject2"
}

variable "github_deploy_branch" {
  type        = string
  description = "Branch whose workflow runs may assume the deploy role."
  default     = "main"
}
