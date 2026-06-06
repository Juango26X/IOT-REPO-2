resource "aws_dynamodb_table" "sensor_data" {
  # Al tener SOLO un Partition Key (hash_key) y NO tener Sort Key (range_key),
  # cada vez que llegue un evento con el mismo device_id, DynamoDB
  # simplemente sobrescribirá el registro existente. ¡Perfecto para "Hot Data"!
  name         = "SensorData-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "device_id"

  attribute {
    name = "device_id"
    type = "S"
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# ──────────────────────────────────────────────────────────────
# RDS PostgreSQL – Histórico de sensores
# Instancia db.t3.micro para mantenerse dentro del Free Tier / Learner Lab
# ──────────────────────────────────────────────────────────────

resource "aws_db_instance" "sensor_history" {
  identifier              = "${var.project_name}-postgres-${var.environment}"
  engine                  = "postgres"
  engine_version          = "15"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  storage_type            = "gp2"

  db_name  = var.db_name
  username = var.db_user
  password = var.db_password

  # Acceso público para que las Lambdas y la tarea ECS (con assign_public_ip)
  # puedan conectarse sin configurar VPN ni NAT Gateway
  publicly_accessible    = true
  skip_final_snapshot    = true
  deletion_protection    = false

  # Security group que permite el puerto 5432 desde ECS y Lambdas
  vpc_security_group_ids = [var.rds_sg_id]

  # Subnet group con mínimo 2 subnets en distintas AZs (requerido por RDS)
  db_subnet_group_name   = var.rds_subnet_group_name

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}
