variable "aws_region" {
  type        = string
  description = "AWS region for bootstrap resources. Must match the region in the backend block."
  default     = "ap-southeast-6"
}

variable "github_repository" {
  type        = string
  description = "GitHub repository allowed to assume the CI roles, as it appears in the OIDC sub claim: owner@owner-id/repo@repo-id. The IDs are public and never change, so a recreated repo with the same name is not trusted."
  default     = "Ajith05105@75721773/INFOSYS735-GroupProject2@1387092923"
}

variable "github_deploy_branch" {
  type        = string
  description = "Branch whose workflow runs may assume the deploy role."
  default     = "main"
}
