#########################################
# outputs.tf — Human-friendly summary
#########################################

output "deployment_summary" {
  value = <<EOT

Deployment Summary

ALB Endpoint
- Application Load Balancer DNS: ${aws_lb.app.dns_name}
- Accessible only from CIDR: ${var.allowed_https_cidr}

Main Application
- Container image: ${var.container_image}
- ECS Service name: ${aws_ecs_service.this.name}

Database
- Type: RDS PostgreSQL
- Endpoint: ${aws_db_instance.this.endpoint}
- Accessible only from ECS tasks (not public)

Migration (optional)
- Migration enabled: ${var.run_migration}
- Migration image: ${try(var.container_image_migration, "N/A")}

EOT
}