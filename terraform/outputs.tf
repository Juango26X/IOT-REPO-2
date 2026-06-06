output "iot_endpoint" {
  description = "El endpoint de AWS IoT Core"
  value       = data.aws_iot_endpoint.iot_endpoint.endpoint_address
}

output "api_url" {
  description = "URL pública de la API FastAPI (via ALB)"
  value       = "http://${module.networking.alb_dns_name}"
}

output "ecr_repo_url" {
  description = "URL del repositorio ECR para hacer docker push de la API"
  value       = module.compute.ecr_repo_url
}

output "alert_queue_url" {
  description = "URL de la cola SQS de alertas"
  value       = module.compute.alert_queue_url
}

output "postgres_host" {
  description = "Host de la instancia RDS PostgreSQL"
  value       = module.database.db_host
}
