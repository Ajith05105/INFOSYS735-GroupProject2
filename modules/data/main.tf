# Transactional database: RDS for Oracle Standard Edition 2, licence included,
# Multi-AZ. RDS owns patching, backups and failover (BR11). Writes commit
# synchronously to a standby in the other AZ; if the primary fails, RDS
# promotes the standby and repoints the endpoint with no connection string
# change (BR1). SE2 has no read replicas, so the standby is the "slave".

resource "aws_db_subnet_group" "this" {
  name        = "anygroup-${var.environment}-data-subnets"
  description = "Private data subnets: no route to the internet in either direction"
  subnet_ids  = var.subnet_ids
}

resource "aws_db_instance" "oracle" {
  identifier     = "anygroup-${var.environment}-oracle"
  engine         = "oracle-se2"
  license_model  = "license-included"
  instance_class = var.instance_class
  db_name        = var.db_name
  username       = "anyadmin"

  # RDS generates the password and keeps it in Secrets Manager, rotating it
  # automatically. It never appears in Terraform state, code or a pipeline.
  manage_master_user_password = true

  multi_az               = true
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.db_sg_id]
  publicly_accessible    = false

  storage_type          = "gp3"
  allocated_storage     = 20
  max_allocated_storage = 100 # storage autoscaling: no silent out-of-space outage
  storage_encrypted     = true

  backup_retention_period    = 35 # maximum, for point-in-time recovery (report §7.2)
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true
  apply_immediately          = true

  # Dev only: tear down cleanly with the deploy workflow's destroy
  deletion_protection      = false
  skip_final_snapshot      = true
  delete_automated_backups = true
}
