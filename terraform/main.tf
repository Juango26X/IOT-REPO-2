terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Módulo de Red (VPC, Subnets, Security Groups, ALB)
module "networking" {
  source       = "./modules/networking"
  project_name = var.project_name
  environment  = var.environment
}

# Módulo de Almacenamiento (S3)
module "storage" {
  source       = "./modules/storage"
  project_name = var.project_name
  environment  = var.environment
}

# Módulo de Base de Datos (DynamoDB + RDS PostgreSQL)
module "database" {
  source       = "./modules/database"
  project_name = var.project_name
  environment  = var.environment
  db_name      = var.db_name
  db_user      = var.db_user
  db_password  = var.db_password
  rds_sg_id             = module.networking.rds_sg_id
  rds_subnet_group_name = module.networking.rds_subnet_group_name

  depends_on = [module.networking]
}

# Módulo de Cómputo (Lambdas + SQS + ECS API)
module "compute" {
  source       = "./modules/compute"
  project_name = var.project_name
  environment  = var.environment
  lab_role_arn = data.aws_iam_role.lab_role.arn
  account_id   = data.aws_caller_identity.current.account_id
  region       = data.aws_region.current.name

  # S3
  sensor_bucket_name = module.storage.sensor_bucket_name
  sensor_bucket_arn  = module.storage.sensor_bucket_arn

  # PostgreSQL
  db_host     = module.database.db_host
  db_name     = module.database.db_name
  db_user     = module.database.db_user
  db_password = var.db_password

  # DynamoDB
  dynamo_table_name = module.database.sensor_table_name

  alert_threshold = var.alert_threshold

  # Red (viene del módulo networking)
  subnet_ids       = module.networking.subnet_ids
  ecs_sg_id        = module.networking.ecs_sg_id
  target_group_arn = module.networking.target_group_arn
  alb_listener_arn = module.networking.alb_listener_arn

  depends_on = [module.storage, module.database, module.networking]
}

# Módulo de IoT Core
module "iot" {
  source       = "./modules/iot"
  project_name = var.project_name
  environment  = var.environment

  lab_role_arn = data.aws_iam_role.lab_role.arn
  account_id   = data.aws_caller_identity.current.account_id
  region       = data.aws_region.current.name
  iot_endpoint = data.aws_iot_endpoint.iot_endpoint.endpoint_address
  root_ca_pem  = data.http.root_ca.response_body

  sensor_bucket_name   = module.storage.sensor_bucket_name
  sensor_table_name    = module.database.sensor_table_name

  # Regla 3: Lambda de alerta
  iot_alert_lambda_arn = module.compute.iot_alert_lambda_arn
  alert_threshold      = var.alert_threshold

  depends_on = [module.compute]
}
