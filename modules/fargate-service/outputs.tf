output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value       = aws_subnet.private[*].id
  description = "Private subnets for the storage backend (RDS subnet group / EFS mount targets)."
}

output "service_security_group_id" {
  value       = aws_security_group.service.id
  description = "The Fargate task SG; reference it from a storage SG's ingress."
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_zone_id" {
  value = aws_lb.this.zone_id
}

output "ecr_repository_url" {
  value = aws_ecr_repository.this.repository_url
}

output "service_url" {
  value = "https://${var.domain_name}"
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.this.name
}
