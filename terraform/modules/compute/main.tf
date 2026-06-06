# ============================================================
# MÓDULO COMPUTE
# Contiene:
#   1. Lambda S3 → PostgreSQL (histórico)
#   2. Lambda Alerta (IoT Rule 3 → SQS)
#   3. SQS Queue de alertas
#   4. Lambda SQS → CloudWatch (log de urgencia)
#   5. ECR + ECS (API FastAPI)
# ============================================================

# ──────────────────────────────────────────────────────────────
# 1. LAMBDA: S3 → PostgreSQL (histórico)
# Patrón igual al de 4_lambda_s3
# El zip se prepara desde el Makefile antes de correr terraform apply
# ──────────────────────────────────────────────────────────────

data "archive_file" "s3_to_postgres_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../lambdas/s3_to_postgres/package"
  output_path = "${path.module}/s3_to_postgres.zip"
}

resource "aws_lambda_function" "s3_to_postgres" {
  filename         = data.archive_file.s3_to_postgres_zip.output_path
  function_name    = "${var.project_name}-s3-to-postgres-${var.environment}"
  role             = var.lab_role_arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  source_code_hash = data.archive_file.s3_to_postgres_zip.output_base64sha256

  environment {
    variables = {
      DB_HOST     = var.db_host
      DB_PORT     = "5432"
      DB_NAME     = var.db_name
      DB_USER     = var.db_user
      DB_PASSWORD = var.db_password
    }
  }
}

# Permiso para que S3 invoque la Lambda
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_to_postgres.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = var.sensor_bucket_arn
}

# Trigger: cuando S3 crea un objeto, llama a la Lambda
resource "aws_s3_bucket_notification" "sensor_trigger" {
  bucket = var.sensor_bucket_name

  lambda_function {
    lambda_function_arn = aws_lambda_function.s3_to_postgres.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

# ──────────────────────────────────────────────────────────────
# 2. SQS QUEUE DE ALERTAS
# Igual al patrón de 10_sqs/terraform/main.tf
# ──────────────────────────────────────────────────────────────
resource "aws_sqs_queue" "alert_queue" {
  name                      = "${var.project_name}-alert-queue-${var.environment}"
  delay_seconds             = 0
  max_message_size          = 262144
  message_retention_seconds = 86400
  receive_wait_time_seconds = 0
}

# ──────────────────────────────────────────────────────────────
# 3. LAMBDA ALERTA: recibe de IoT Rule 3, envía a SQS
# ──────────────────────────────────────────────────────────────
data "archive_file" "iot_alert_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../lambdas/iot_alert"
  output_path = "${path.module}/iot_alert.zip"
}

resource "aws_lambda_function" "iot_alert" {
  filename         = data.archive_file.iot_alert_zip.output_path
  function_name    = "${var.project_name}-iot-alert-${var.environment}"
  role             = var.lab_role_arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  timeout          = 15
  source_code_hash = data.archive_file.iot_alert_zip.output_base64sha256

  environment {
    variables = {
      ALERT_QUEUE_URL = aws_sqs_queue.alert_queue.url
    }
  }
}

# Permiso para que IoT Core invoque la Lambda de alerta
resource "aws_lambda_permission" "allow_iot_alert" {
  statement_id  = "AllowIoTInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.iot_alert.function_name
  principal     = "iot.amazonaws.com"
}

# ──────────────────────────────────────────────────────────────
# 4. LAMBDA SQS → CLOUDWATCH (log de urgencia)
# Patrón idéntico al de 10_sqs/withLambda
# ──────────────────────────────────────────────────────────────
data "archive_file" "sqs_to_cw_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../lambdas/sqs_to_cloudwatch"
  output_path = "${path.module}/sqs_to_cloudwatch.zip"
}

resource "aws_lambda_function" "sqs_to_cloudwatch" {
  filename         = data.archive_file.sqs_to_cw_zip.output_path
  function_name    = "${var.project_name}-sqs-to-cloudwatch-${var.environment}"
  role             = var.lab_role_arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  timeout          = 15
  source_code_hash = data.archive_file.sqs_to_cw_zip.output_base64sha256
}

# Trigger SQS → Lambda (igual que en 10_sqs)
resource "aws_lambda_event_source_mapping" "alert_sqs_trigger" {
  event_source_arn = aws_sqs_queue.alert_queue.arn
  function_name    = aws_lambda_function.sqs_to_cloudwatch.arn
  batch_size       = 10
  enabled          = true
}

# ──────────────────────────────────────────────────────────────
# 5. ECR + ECS: API FastAPI
# Los recursos de red (ALB, SGs, subnets) vienen del módulo networking
# ──────────────────────────────────────────────────────────────

# Repositorio ECR para la imagen de la API
resource "aws_ecr_repository" "api_repo" {
  name                 = var.ecr_repo_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# Cluster ECS
resource "aws_ecs_cluster" "api_cluster" {
  name = "${var.project_name}-api-cluster-${var.environment}"
}


resource "aws_cloudwatch_log_group" "api_logs" {
  name              = "/ecs/${var.project_name}-api-${var.environment}"
  retention_in_days = 7
}

# ECS Task Definition (Fargate)
resource "aws_ecs_task_definition" "api_task" {
  family                   = "${var.project_name}-api-task-${var.environment}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = var.lab_role_arn
  task_role_arn            = var.lab_role_arn

  container_definitions = jsonencode([
    {
      name  = "sensor-api-container"
      image = "${aws_ecr_repository.api_repo.repository_url}:latest"
      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "AWS_REGION",   value = var.region },
        { name = "DYNAMO_TABLE", value = var.dynamo_table_name },
        { name = "DB_HOST",      value = var.db_host },
        { name = "DB_NAME",      value = var.db_name },
        { name = "DB_USER",      value = var.db_user },
        { name = "DB_PASSWORD",  value = var.db_password }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api_logs.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# ECS Service
resource "aws_ecs_service" "api_service" {
  name            = "${var.project_name}-api-service-${var.environment}"
  cluster         = aws_ecs_cluster.api_cluster.id
  task_definition = aws_ecs_task_definition.api_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.ecs_sg_id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "sensor-api-container"
    container_port   = 8000
  }

  depends_on = [aws_ecs_cluster.api_cluster]
}
