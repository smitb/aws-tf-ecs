resource "aws_security_group" "alb_sg" {
  name        = "alb-sg-${var.environment_name}"
  description = "ALB security group"
  vpc_id      =  data.terraform_remote_state.vpc_rds.outputs.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "alb" {
  name               = "mendix-alb-${var.environment_name}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.terraform_remote_state.vpc_rds.outputs.public_subnet_ids
}

resource "aws_lb_listener" "alb_listener_80" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.mendix.arn
  }
}

resource "aws_lb_target_group" "mendix" {
  name     = "mendix-tg-${var.environment_name}"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = data.terraform_remote_state.vpc_rds.outputs.vpc_id
  target_type = "ip"

  health_check {
    matcher = "200"
    path = "/"
  }
}

resource "aws_cloudwatch_log_group" "mendix_log_group" {
  name = "/ecs/mendix-${var.environment_name}"
}

resource "aws_ecs_cluster" "cluster" {
  name = "mendix-cluster-${var.environment_name}"
}

resource "aws_iam_role" "mendix_task_role" {
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "mendix_task_policy" {
  role = aws_iam_role.mendix_task_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:CreateLogGroup"
      ],
      Effect = "Allow",
      Resource = "*",
    }]
  })
}

resource "aws_ecs_task_definition" "mendix_task" {
  family                = "mendix-task-${var.environment_name}"
  network_mode          = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                   = "1024"
  memory                = "2048"

  container_definitions = jsonencode([{
    name  = "mendix-app",
    image = "jacobboer/mxbluedockersandbox:sandboxapp",
    portMappings = [{
      containerPort = 8080,
      hostPort      = 8080,
      protocol      = "tcp"
    }]
    environment = [
      { 
        name = "ADMIN_PASSWORD",
        value = "Welcome2023!"
      },
      { 
        name = "DATABASE_ENDPOINT",
        value = "postgres://${data.terraform_remote_state.vpc_rds.outputs.postgresql_cluster_master_user}:${data.terraform_remote_state.vpc_rds.outputs.postgresql_cluster_master_password}@${data.terraform_remote_state.vpc_rds.outputs.postgresql_cluster_endpoint}:5432/${var.environment_name}"
      },
      { 
        name = "CERTIFICATE_AUTHORITIES",
        value = var.mendix_ca
      },
      # Add more environment variables here
    ]
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": aws_cloudwatch_log_group.mendix_log_group.name,
        "awslogs-region": "eu-central-1",
        "awslogs-stream-prefix": "ecs"
      }
    }
    "healthcheck": {
      "command": ["CMD-SHELL", "curl http://127.0.0.1:8080/ || exit 1"]
      "startPeriod": 180
    }
  }])

  execution_role_arn = aws_iam_role.mendix_task_role.arn
}

resource "aws_security_group" "mendix_sg" {
  name        = "mendix-sg-${var.environment_name}"
  description = "Mendix security group"
  vpc_id      = data.terraform_remote_state.vpc_rds.outputs.vpc_id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_service" "mendix-service" {
  name            = "mendix-service-${var.environment_name}"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.mendix_task.arn
  launch_type     = "FARGATE"
  
  network_configuration {
    
    subnets = data.terraform_remote_state.vpc_rds.outputs.private_subnet_ids
    security_groups = [aws_security_group.mendix_sg.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.mendix.arn
    container_name   = "mendix-app"
    container_port   = 8080
  }

  desired_count = 1
}