output "sensor_bucket_name" {
  value       = aws_s3_bucket.sensor_data.bucket
  description = "Nombre del bucket de S3 para sensores"
}

output "sensor_bucket_arn" {
  value       = aws_s3_bucket.sensor_data.arn
  description = "ARN del bucket de S3 para sensores (usado para el trigger Lambda)"
}

output "athena_results_bucket_name" {
  value       = aws_s3_bucket.athena_results.bucket
  description = "Nombre del bucket de S3 para Athena"
}
