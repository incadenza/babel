provider "aws" {
  region = "us-east-1"
}

# S3 bucket for static assets
resource "aws_s3_bucket" "site_bucket" {
  bucket = "remix-site-bucket"

  website {
    index_document = "index.html"
    error_document = "404.html"
  }
}

resource "aws_s3_bucket_object" "site_files" {
  for_each = fileset("${path.module}/public", "**/*")

  bucket = aws_s3_bucket.site_bucket.id
  key    = each.value
  source = "${path.module}/public/${each.value}"
  etag   = filemd5("${path.module}/public/${each.value}")

  content_type = lookup({
    "html" = "text/html",
    "js"   = "application/javascript",
    "css"  = "text/css"
  }, fileext(each.value), "application/octet-stream")
}

resource "aws_cloudfront_origin_access_control" "oac" {
  name   = "s3-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior = "always"
  signing_protocol = "sigv4"
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CDN for Remix website"
  default_root_object = "index.html"

  origin {
    domain_name = aws_s3_bucket.site_bucket.bucket_regional_domain_name
    origin_id   = aws_s3_bucket.site_bucket.id

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.oac.cloudfront_access_identity_path
    }
  }

  default_cache_behavior {
    target_origin_id       = aws_s3_bucket.site_bucket.id
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  price_class = "PriceClass_100"

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket_policy" "bucket_policy" {
  bucket = aws_s3_bucket.site_bucket.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          AWS = "arn:aws:iam::cloudfront:user/CloudFront Origin Access Identity ${aws_cloudfront_origin_access_identity.oac.id}"
        },
        Action = "s3:GetObject",
        Resource = "arn:aws:s3:::${aws_s3_bucket.site_bucket.id}/*"
      }
    ]
  })
}

# VPC
resource "aws_vpc" "vpc" {
  cidr_block = "10.0.0.0/16"
}

# Subnet
resource "aws_subnet" "subnet" {
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
}

# Route Table
resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

# Route Table Association
resource "aws_route_table_association" "rta" {
  subnet_id      = aws_subnet.subnet.id
  route_table_id = aws_route_table.rt.id
}

# Security Group
resource "aws_security_group" "sg" {
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
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

# ECS Cluster
resource "aws_ecs_cluster" "cluster" {
  name = "remix-cluster"
}

# IAM Role for ECS Task
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS Task Definition
resource "aws_ecs_task_definition" "task" {
  family                   = "remix-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "remix-container"
      image     = "your-remix-backend-image" # Replace with your Docker image
      essential = true
      portMappings = [
        {
          containerPort = 3000
          hostPort      = 3000
          protocol      = "tcp"
        }
      ]
    }
  ])
}

# ECS Service
resource "aws_ecs_service" "service" {
  name            = "remix-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.subnet.id]
    security_groups  = [aws_security_group.sg.id]
    assign_public_ip = true
  }
}

# ALB
resource "aws_lb" "lb" {
  name               = "remix-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.sg.id]
  subnets            = [aws_subnet.subnet.id]
}

# ALB Target Group
resource "aws_lb_target_group" "tg" {
  name     = "remix-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = aws_vpc.vpc.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

# ALB Listener
resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

# ECS Service Load Balancer Attachment
resource "aws_lb_target_group_attachment" "ecs_attachment" {
  target_group_arn = aws_lb_target_group.tg.arn
  target_id        = aws_ecs_service.service.id
  port             = 3000
}

output "cdn_url" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

output "backend_url" {
  value = aws_lb.lb.dns_name
}
