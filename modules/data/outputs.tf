output "address" {
  description = "Database hostname."
  value       = aws_db_instance.postgres.address
}

output "db_name" {
  description = "PostgreSQL database name."
  value       = aws_db_instance.postgres.db_name
}

output "master_secret_arn" {
  description = "Secrets Manager secret holding the master credentials."
  value       = aws_db_instance.postgres.master_user_secret[0].secret_arn
}
