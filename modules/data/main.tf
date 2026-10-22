# Transactional database: RDS for PostgreSQL. RDS owns patching and backups
# (BR11). The design is Oracle SE2 Multi-AZ, but Oracle and the Multi-AZ
# standby would quickly use up the AWS Free plan credits, and the Free plan
# caps backups at one day, so dev runs a single PostgreSQL micro instance.

resource "aws_db_subnet_group" "this" {
  name        = "anygroup-${var.environment}-data-subnets"
  description = "Private data subnets: no route to the internet in either direction"
  subnet_ids  = var.subnet_ids
}

resource "aws_db_instance" "postgres" {
  identifier     = "anygroup-${var.environment}-postgres"
  engine         = "postgres"
  engine_version = "17"
  instance_class = var.instance_class
  db_name        = var.db_name
  username       = "anyadmin"

  # RDS generates the password and keeps it in Secrets Manager, rotating it
  # automatically. It never appears in Terraform state, code or a pipeline.
  manage_master_user_password = true

  multi_az               = false # Free plan
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.db_sg_id]
  publicly_accessible    = false

  storage_type      = "gp3"
  allocated_storage = 20
  storage_encrypted = true

  backup_retention_period    = 1 # Free plan maximum
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true
  apply_immediately          = true

  # Dev only: tear down cleanly with the deploy workflow's destroy
  deletion_protection      = false
  skip_final_snapshot      = true
  delete_automated_backups = true
}
