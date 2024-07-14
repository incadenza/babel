provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "site_bucket" {
  bucket = "remix-site-bucket"

  website {
    index_document = "index.html"
    error_document = "404.html"
  }
}

resource "aws_s3_bucket_object" "site_files" {
  for_each = fileset("${path.module}/public", "**/*")

  bucket = aws_s3_bucket.site_bucket.bucket
  key    = each.value
  source = "${path.module}/public/${each.value}"
  etag   = filemd5("${path.module}/public/${each.value}")

  content_type = lookup({
    "html" = "text/html",
    "js"   = "application/javascript",
    "css"  = "text/css"
  }, fileext("${path.module}/public/${each.value}"), "application/octet-stream")
}

resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "OAI for S3"
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
      origin_access_identity = aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path
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
          AWS = "arn:aws:iam::cloudfront:user/CloudFront Origin Access Identity ${aws_cloudfront_origin_access_identity.origin_access_identity.id}"
        },
        Action = "s3:GetObject",
        Resource = "arn:aws:s3:::${aws_s3_bucket.site_bucket.id}/*"
      }
    ]
  })
}

resource "aws_ecs_cluster" "remix_cluster" {
  name = "remix-cluster"
}

resource "aws_ecs_task_definition" "remix_task" {
  family                   = "remix-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([{
    name  = "remix-container"
    image = "your-remix-backend-image" # Replace with your Remix backend Docker image
    portMappings = [{
      containerPort = 3000
      hostPort      = 3000
      protocol      = "tcp"
    }]
    essential = true
  }])
}

resource "aws_ecs_service" "remix_service" {
  name            = "remix-service"
  cluster         = aws_ecs_cluster.remix_cluster.id
  task_definition = aws_ecs_task_definition.remix_task.arn
  desired_count   = 1

  launch_type = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.main.id]
    security_groups  = [aws_security_group.allow_all.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.remix_tg.arn
    container_name   = "remix-container"
    container_port   = 3000
  }
}

resource "aws_lb" "remix_lb" {
  name               = "remix-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.allow_all.id]
  subnets            = [aws_subnet.main.id]
}

resource "aws_lb_target_group" "remix_tg" {
  name     = "remix-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.remix_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.remix_tg.arn
  }
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "main" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_security_group" "allow_all" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

output "cdn_url" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

output "backend_url" {
  value = aws_lb.remix_lb.dns_name
}
