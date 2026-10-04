output "state_bucket_name" {
  description = "S3 bucket that holds Terraform state for every stack."
  value       = aws_s3_bucket.state.id
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC identity provider."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "plan_role_arn" {
  description = "Role that pull request workflows assume for terraform plan."
  value       = aws_iam_role.plan.arn
}

output "deploy_role_arn" {
  description = "Role that deploy branch workflows assume for terraform apply."
  value       = aws_iam_role.deploy.arn
}

output "workload_boundary_arn" {
  description = "Permissions boundary every workload role must carry."
  value       = aws_iam_policy.workload_boundary.arn
}
