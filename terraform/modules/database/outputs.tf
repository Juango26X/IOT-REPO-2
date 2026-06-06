output "sensor_table_name" {
  value       = aws_dynamodb_table.sensor_data.name
  description = "Nombre de la tabla DynamoDB para los datos del sensor"
}

output "db_host" {
  value       = aws_db_instance.sensor_history.address
  description = "Host/endpoint de la instancia RDS PostgreSQL"
}

output "db_name" {
  value       = aws_db_instance.sensor_history.db_name
  description = "Nombre de la base de datos PostgreSQL"
}

output "db_user" {
  value       = aws_db_instance.sensor_history.username
  description = "Usuario de PostgreSQL"
}
