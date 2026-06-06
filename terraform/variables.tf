variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
  default     = "iot-edge"
}

variable "environment" {
  description = "Entorno de despliegue"
  type        = string
  default     = "lab"
}

# ── RDS PostgreSQL ──────────────────────────────────────────
variable "db_name" {
  description = "Nombre de la base de datos PostgreSQL"
  type        = string
  default     = "sensordb"
}

variable "db_user" {
  description = "Usuario administrador de PostgreSQL"
  type        = string
  default     = "sensoradmin"
}

variable "db_password" {
  description = "Contraseña de PostgreSQL (pasar con -var o TF_VAR_db_password)"
  type        = string
  sensitive   = true
  default     = "Sensor1234"
}

# ── Sistema de Alertas ──────────────────────────────────────
variable "alert_threshold" {
  description = "Umbral de temperatura (°C) que activa la Regla 3 de IoT"
  type        = number
  default     = 35
}
