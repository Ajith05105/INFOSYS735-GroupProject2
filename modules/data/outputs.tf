output "address" {
  description = "Database hostname. Follows the primary through a Multi-AZ failover."
  value       = aws_db_instance.oracle.address
}

output "db_name" {
  description = "Oracle database (service) name."
  value       = aws_db_instance.oracle.db_name
}

output "master_secret_arn" {
  description = "Secrets Manager secret holding the master credentials."
  value       = aws_db_instance.oracle.master_user_secret[0].secret_arn
}
