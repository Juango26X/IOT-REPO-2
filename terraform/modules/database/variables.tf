variable "project_name" { type = string }
variable "environment" { type = string }

variable "db_name" {
  type    = string
  default = "sensordb"
}

variable "db_user" {
  type    = string
  default = "sensoradmin"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "rds_sg_id" {
  type        = string
  description = "ID del Security Group para RDS (viene del módulo networking)"
}

variable "rds_subnet_group_name" {
  type        = string
  description = "Nombre del DB Subnet Group para RDS (viene del módulo networking)"
}
