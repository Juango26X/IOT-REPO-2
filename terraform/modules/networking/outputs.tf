output "vpc_id" {
  value = data.aws_vpc.default.id
}

output "subnet_ids" {
  value = data.aws_subnets.default.ids
}

output "alb_sg_id" {
  value = aws_security_group.alb_sg.id
}

output "ecs_sg_id" {
  value = aws_security_group.ecs_sg.id
}

output "alb_dns_name" {
  value = aws_lb.api_alb.dns_name
}

output "alb_listener_arn" {
  value = aws_lb_listener.api_listener.arn
}

output "target_group_arn" {
  value = aws_lb_target_group.api_tg.arn
}

output "rds_sg_id" {
  value       = aws_security_group.rds_sg.id
  description = "ID del Security Group para RDS PostgreSQL"
}

output "rds_subnet_group_name" {
  value       = aws_db_subnet_group.rds_subnet_group.name
  description = "Nombre del DB Subnet Group para RDS"
}
