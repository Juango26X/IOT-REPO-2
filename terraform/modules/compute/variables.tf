variable "project_name" { type = string }
variable "environment" { type = string }
variable "lab_role_arn" { type = string }
variable "account_id" { type = string }
variable "region" { type = string }

# S3 para trigger Lambda histórico
variable "sensor_bucket_name" { type = string }
variable "sensor_bucket_arn" { type = string }

# Parámetros de conexión a PostgreSQL (RDS)
variable "db_host" { type = string }
variable "db_name" { type = string }
variable "db_user" { type = string }
variable "db_password" {
  type      = string
  sensitive = true
}

# Nombre de la tabla DynamoDB para la API
variable "dynamo_table_name" { type = string }

# Repositorio ECR para la imagen de la API
variable "ecr_repo_name" {
  type    = string
  default = "iot-sensor-api"
}

# Umbral de temperatura para la Regla 3 de IoT
variable "alert_threshold" {
  type    = number
  default = 35
}

# ── Valores del módulo networking ──────────────────────────
variable "subnet_ids" {
  type        = list(string)
  description = "IDs de las subnets donde corren las tareas ECS"
}

variable "ecs_sg_id" {
  type        = string
  description = "ID del Security Group para las tareas ECS"
}

variable "target_group_arn" {
  type        = string
  description = "ARN del Target Group del ALB"
}

variable "alb_listener_arn" {
  type        = string
  description = "ARN del Listener del ALB (para el depends_on del ECS Service)"
}
