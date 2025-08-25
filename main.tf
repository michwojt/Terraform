#########################################
# main.tf — Single-file Terraform stack
# ECS (Fargate) service behind HTTPS ALB (restricted to 75.2.60.0/24)
# + RDS PostgreSQL accessible only from ECS tasks
#########################################

provider "aws" {
  region = var.aws_region
}

#########################################
# Variables
#########################################

variable "project_name" { type = string  default = "ecs-api" }
variable "aws_region"   { type = string  default = "us-east-1" }

variable "az" { type = string default = "us-east-1a"}

variable "vpc_cidr"     { type = string  default = "10.0.0.0/16" }

# Restrict HTTPS access to this CIDR (75.2.60.*)
variable "allowed_https_cidr" { type = string  default = "75.2.60.0/24" }

# Container image & settings
variable "container_image" { type = string description = "Container image (e.g., nginx:latest or 123456789012.dkr.ecr.us-east-1.amazonaws.com/app:tag)" }
variable "container_port"  { type = number default = 8080 }
variable "desired_count"   { type = number default = 1 }
variable "fargate_cpu"     { type = number default = 512 }
variable "fargate_memory"  { type = number default = 1024 }

variable "app_command" {
  description = "Command executend in app conainer"
  type    = list(string)
  default = []
}

# HTTPS certificate (ALB)
# Provide an ACM cert in the same region
variable "certificate_arn" { type = string description = "ACM certificate ARN for your domain (in same region as ALB)" }


# RDS settings
variable "db_name"     { type = string default = "appdb" }
variable "db_username" { type = string default = "appuser" }
variable "db_engine_version" { type = string default = "16.3" }
variable "db_instance_class" { type = string default = "db.t4g.micro" }
variable "db_allocated_storage" { type = number default = 20 }

##DB environmental variables - Main container
variable "db_password_env_name_app" {
  type        = string
  default     = "DB_PASSWORD"
  description = "Environment variable name for the DB password inside app container"
}

# Define variables (only for user-supplied values)
variable "app_db_env_vars" {
  type        = map(string)
  description = "Extra environment variables for app container"
  default     = {}
}

##DB environmental variables - Migration container
variable "db_password_env_name_migration" {
  type        = string
  default     = "DB_PASSWORD"
  description = "Environment variable name for the DB password inside migration container"
}

variable "migration_db_env_vars" {
  type        = map(string)
  description = "Extra environment variables for migration container"
  default     = {}
}

#########################################
# Locals
#########################################

locals {
  name_prefix = "${var.project_name}"
  tags = {
    Project = var.project_name
  }
}

# Locals that merge computed DB values with user overrides
locals {
  base_db_env_vars = {
    DB_HOST = aws_db_instance.this.address
    DB_PORT = "5432"
    DB_NAME = var.db_name
    DB_USER = var.db_username
  }

  app_db_env_vars = merge(local.base_db_env_vars, var.app_db_env_vars)
  migration_db_env_vars = merge(local.base_db_env_vars, var.migration_db_env_vars)
}

#########################################
# Networking — VPC, Subnets, NAT, Routing
#########################################

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = merge(local.tags, { Name = "${local.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id
  tags = merge(local.tags, { Name = "${local.name_prefix}-igw" })
}


# Public subnet (for ALB, NAT Gateway, bastion if any)
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, 0)  # First /20 from VPC
  availability_zone       = var.az
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${local.name_prefix}-public"
    Tier = "public"
  })
}

# Private subnet (for ECS tasks, RDS)
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 1)  # Second /20 from VPC (non-overlapping)
  availability_zone       = var.az

  tags = merge(local.tags, {
    Name = "${local.name_prefix}-private"
    Tier = "private"
  })
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags = merge(local.tags, { Name = "${local.name_prefix}-nat-eip" })
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags = merge(local.tags, { Name = "${local.name_prefix}-nat" })
  depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route { cidr_block = "0.0.0.0/0" gateway_id = aws_internet_gateway.igw.id }
  tags = merge(local.tags, { Name = "${local.name_prefix}-public-rt" })
}

resource "aws_route_table_association" "public" {
  subnet_id     = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route { cidr_block = "0.0.0.0/0" nat_gateway_id = aws_nat_gateway.nat.id }
  tags = merge(local.tags, { Name = "${local.name_prefix}-private-rt" })
}

resource "aws_route_table_association" "private" {
  subnet_id     = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

#########################################
# Security Groups
#########################################

# ALB — allow 443 from allowed CIDR only; egress anywhere
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB security group"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from allowed CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_https_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-alb-sg" })
}

# ECS tasks — allow from ALB to container_port; egress anywhere
resource "aws_security_group" "ecs" {
  name        = "${local.name_prefix}-ecs-sg"
  description = "ECS tasks security group"
  vpc_id      = aws_vpc.this.id

  ingress {
    description      = "App port from ALB"
    from_port        = var.container_port
    to_port          = var.container_port
    protocol         = "tcp"
    security_groups  = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-ecs-sg" })
}

# RDS — allow Postgres only from ECS SG
resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "RDS security group"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Postgres from ECS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-rds-sg" })
}

#########################################
# ALB (HTTPS) + Target Group + Listener
#########################################

resource "aws_lb" "app" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public.id]
  enable_deletion_protection = false
  tags = merge(local.tags, { Name = "${local.name_prefix}-alb" })
}

resource "aws_lb_target_group" "app" {
  name        = "${local.name_prefix}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip" # required for Fargate

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200-399"
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-tg" })
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}


#########################################
# RDS PostgreSQL
#########################################

resource "aws_db_subnet_group" "this" {
  name       = "${local.name_prefix}-db-subnets"
  subnet_ids = [aws_subnet.private.id]
  tags = merge(local.tags, { Name = "${local.name_prefix}-db-subnets" })
}

resource "random_password" "db" {
  length  = 20
  special = true
}

resource "aws_db_instance" "this" {
  identifier              = "${local.name_prefix}-pg"
  engine                  = "postgres"
  engine_version          = var.db_engine_version
  instance_class          = var.db_instance_class
  allocated_storage       = var.db_allocated_storage
  db_name                 = var.db_name
  username                = var.db_username
  password                = random_password.db.result
  port                    = 5432
  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  publicly_accessible     = false
  skip_final_snapshot     = true
  deletion_protection     = false
  storage_encrypted       = true
  backup_retention_period = 7
  auto_minor_version_upgrade = true
  multi_az                = false
  tags = merge(local.tags, { Name = "${local.name_prefix}-pg" })
}

#########################################
# Secrets Manager — store DB connection info for the app
#########################################

resource "aws_secretsmanager_secret" "db" {
  name = "${local.name_prefix}/db"
  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username,
    password = random_password.db.result,
    host     = aws_db_instance.this.address,
    port     = 5432,
    dbname   = var.db_name
  })
  depends_on = [aws_db_instance.this]
}

#########################################
# ECS Cluster, Task & Service (Fargate)
#########################################

resource "aws_ecs_cluster" "this" {
  name = "${local.name_prefix}-cluster"
  tags = local.tags
}

# IAM for ECS task execution (pull image, send logs)
resource "aws_iam_role" "task_execution" {
  name = "${local.name_prefix}-task-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_exec_policy" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role for reading DB secret
resource "aws_iam_role" "task" {
  name = "${local.name_prefix}-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "secrets_read" {
  name        = "${local.name_prefix}-secrets-read"
  description = "Allow ECS task to read DB secret"
  policy      = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = ["secretsmanager:GetSecretValue"],
      Resource = [aws_secretsmanager_secret.db.arn]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_secrets_attach" {
  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.secrets_read.arn
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = 14
  tags = local.tags
}

# Container definition
locals {
  container_name = "${local.name_prefix}-app"
  container_def  = jsonencode([
    {
      name  = local.container_name,
      image = var.container_image,
      essential = true,
      portMappings = [{
        containerPort = var.container_port,
        hostPort      = var.container_port,
        protocol      = "tcp"
      }],
      environment = [for k, v in local.app_db_env_vars : { name = k, value = v }],
	  command = var.app_command,
      secrets = [
        { name = var.db_password_env_name_app, valueFrom = "${aws_secretsmanager_secret.db.arn}:password" }
      ],
      logConfiguration = {
        logDriver = "awslogs",
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name,
          awslogs-region        = var.aws_region,
          awslogs-stream-prefix = "ecs"
        }
      },
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.container_port}/ || exit 1"],
        interval    = 30,
        timeout     = 5,
        retries     = 3,
        startPeriod = 10
      }
    }
  ])
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.container_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.fargate_cpu)
  memory                   = tostring(var.fargate_memory)
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions    = local.container_def
}

resource "aws_ecs_service" "this" {
  name            = "${local.name_prefix}-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [aws_subnet.private.id]
    security_groups = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = local.container_name
    container_port   = var.container_port
  }
  
  depends_on = [
    aws_db_instance.this,
    null_resource.run_migration
  ]

  lifecycle { ignore_changes = [task_definition] }
  depends_on = [aws_lb_listener.https]
}

