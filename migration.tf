#########################################
# migration.tf — Optional ECS migration
#########################################

variable "run_migration" {
  type        = bool
  default     = false
  description = "Whether to run DB migration task after deployment"
}

variable "migration_command" {
  type        = list(string)
  default     = []
  description = "Command to run migration inside the container, e.g., ['/app/migrate.sh']"
}

variable "migration_cpu" {
  type        = string
  default     = "256"
  description = "CPU units for migration task"
}

variable "migration_memory" {
  type        = string
  default     = "512"
  description = "Memory for migration task (MB)"
}

variable "container_image_migration" {
  description = "Docker image for the migration task"
  type        = string
  default     = "" # optional: allow empty if migrations are disabled
}

resource "aws_ecs_task_definition" "migration" {
  count                    = var.run_migration ? 1 : 0
  family                   = "${local.name_prefix}-migration"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.migration_cpu
  memory                   = var.migration_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "migration"
      image     = var.container_image_migration
      essential = true
      command   = var.migration_command
      environment = [for k, v in local.migration_db_env_vars : { name = k, value = v }]
      secrets = [
        { name = var.db_password_env_name_migration, valueFrom = "${aws_secretsmanager_secret.db.arn}:password" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "migration"
        }
      }
    }
  ])
}

resource "null_resource" "run_migration" {
  count = var.run_migration ? 1 : 0

  triggers = {
    task_def = aws_ecs_task_definition.migration[0].arn
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<EOT
# Run ECS migration task
TASK_ARN=$(aws ecs run-task \
  --cluster ${aws_ecs_cluster.this.name} \
  --launch-type FARGATE \
  --task-definition ${aws_ecs_task_definition.migration[0].family} \
  --network-configuration "awsvpcConfiguration={subnets=[${aws_subnet.private.id}],securityGroups=[${aws_security_group.ecs.id}],assignPublicIp=DISABLED}" \
  --query "tasks[0].taskArn" --output text)

# Wait for task to stop
aws ecs wait tasks-stopped --cluster ${aws_ecs_cluster.this.name} --tasks $TASK_ARN

# Check exit code
EXIT_CODE=$(aws ecs describe-tasks \
  --cluster ${aws_ecs_cluster.this.name} \
  --tasks $TASK_ARN \
  --query "tasks[0].containers[0].exitCode" --output text)

if [ "$EXIT_CODE" != "0" ]; then
  echo "Migration failed with exit code $EXIT_CODE"
  exit 1
fi
EOT
  }

  depends_on = [
    aws_db_instance.this
  ]
}
