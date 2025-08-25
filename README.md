# Terraform ECS + RDS Deployment

This Terraform stack deploys:

- **RDS PostgreSQL** (private, accessible only by ECS tasks, with random generated password stored in secrets)  
- **ECS Fargate Service** running a Docker container  
- **Application Load Balancer (ALB) with HTTPS** (restricted CIDR access)  
- **Optional DB migration task** executed via ECS

---

## Prerequisites

- AWS account with permissions to create: VPC, subnets, ECS, RDS, ALB, IAM roles, and Secrets Manager  
- ACM SSL certificate in the same AWS region as the ALB  
- Docker image available either on **Docker Hub** or **ECR**

---

## Planned improvemnts
- **Multi-AZ Deployment**: Add second availability zone for high availability
- **Auto Scaling**: Implement CPU/memory-based scaling policies  
- **Custom Domain**: Route53 integration for branded endpoints

---

## Variables

### Mandatory Variables

| Variable | Description |
|----------|-------------|
| `container_image` | Docker image for main app container (e.g., `nginx:latest` or `123456789012.dkr.ecr.us-east-1.amazonaws.com/app:tag`) |
| `certificate_arn` | ARN of ACM certificate for ALB HTTPS |

### Optional Variables (with defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `project_name` | `ecs-api` | Prefix for all resources |
| `aws_region` | `us-east-1` | AWS region |
| `az` | `us-east-1a` | Availability Zone |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR block |
| `allowed_https_cidr` | `75.2.60.0/24` | CIDR allowed to access HTTPS ALB |
| `container_port` | `8080` | Main container port |
| `desired_count` | `1` | ECS task count |
| `fargate_cpu` | `512` | ECS Fargate CPU units |
| `fargate_memory` | `1024` | ECS Fargate memory in MB |
| `app_command` | `[]` | Command to run in main container |
| `db_name` | `appdb` | RDS database name |
| `db_username` | `appuser` | RDS username |
| `db_engine_version` | `16.3` | PostgreSQL version |
| `db_instance_class` | `db.t4g.micro` | RDS instance class |
| `db_allocated_storage` | `20` | RDS storage in GB |
| `db_password_env_name_app` | `DB_PASSWORD` | Environment variable name for DB password in main container |
| `app_db_env_vars` | `{}` | Extra environment variables for main container. Merged with automatically computed DB variables: `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`. User-supplied values override defaults. |
| `db_password_env_name_migration` | `DB_PASSWORD` | Environment variable name for DB password in migration container |
| `migration_db_env_vars` | `{}` | Extra environment variables for migration container. Merged with automatically computed DB variables: `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`. User-supplied values override defaults. |
| `run_migration` | `false` | Whether to run migration task |
| `container_image_migration` | `""` | Docker image for migration (optional) |
| `migration_command` | `[]` | Command for migration container |
| `migration_cpu` | `256` | CPU units for migration task |
| `migration_memory` | `512` | Memory for migration task (MB) |

---

## Docker Image
- Docker Hub: Use image like `"nginx:latest"`.
- Amazon ECR: Use full ECR URI `"123456789012.dkr.ecr.us-east-1.amazonaws.com/my-app:tag"`.
- ECS execution role has the policy `AmazonECSTaskExecutionRolePolicy`, which allows pulling images from your account’s ECR.

## Optional Migration

- Set `run_migration = true` and provide:
  - `migration_command` – command to run inside migration container
  - `container_image_migration` – Docker image for migration
- Terraform runs the migration using a null_resource and ECS run-task.
- ECS service waits for migration to complete before starting.

## Output Information

- ALB Endpoint
- Main Application Container Name
- Database
- Migration (optional)
  
## Examples
Run app only (no migration):

```bash
terraform apply \
  -var 'container_image=nginx:latest' \
  -var 'certificate_arn=arn:aws:acm:us-east-1:123456789012:certificate/abcd'
```
Run app with migration:
```bash
terraform apply \
  -var 'container_image=123456789012.dkr.ecr.us-east-1.amazonaws.com/app:latest' \
  -var 'certificate_arn=arn:aws:acm:us-east-1:123456789012:certificate/abcd' \
  -var 'run_migration=true' \
  -var 'migration_command=["/app/migrate.sh"]' \
  -var 'container_image_migration=123456789012.dkr.ecr.us-east-1.amazonaws.com/app:latest'
```
