output "alert_queue_url" {
  description = "URL de la cola SQS de alertas"
  value       = aws_sqs_queue.alert_queue.url
}

output "alert_queue_arn" {
  description = "ARN de la cola SQS de alertas"
  value       = aws_sqs_queue.alert_queue.arn
}

output "iot_alert_lambda_arn" {
  description = "ARN de la Lambda de alerta (usada por la Regla 3 de IoT)"
  value       = aws_lambda_function.iot_alert.arn
}

output "ecr_repo_url" {
  description = "URL del repositorio ECR para la imagen de la API"
  value       = aws_ecr_repository.api_repo.repository_url
}
