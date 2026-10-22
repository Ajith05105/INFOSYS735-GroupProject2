data "aws_region" "current" {}

# Latest Amazon Linux 2023 for whichever CPU architecture the instance type uses
data "aws_ec2_instance_type" "app" {
  instance_type = var.instance_type
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*"]
  }

  filter {
    name   = "architecture"
    values = [data.aws_ec2_instance_type.app.supported_architectures[0]]
  }
}

# Internal ALB in the app subnets. Only the web tier can reach it, so the app
# tier is never addressable from the edge and scales independently of web.

resource "aws_lb" "app" {
  name                       = "anygroup-${var.environment}-app-alb"
  load_balancer_type         = "application"
  internal                   = true
  security_groups            = [var.alb_sg_id]
  subnets                    = var.subnet_ids
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "app" {
  name                 = "anygroup-${var.environment}-app-tg"
  port                 = var.app_port
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# App instances in the private app subnets, one or more per AZ

resource "aws_launch_template" "app" {
  name                   = "anygroup-${var.environment}-app-lt"
  image_id               = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  vpc_security_group_ids = [var.instance_sg_id]
  update_default_version = true

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    app_port      = var.app_port
    db_host       = var.db_host
    db_name       = var.db_name
    db_secret_arn = var.db_secret_arn
    aws_region    = data.aws_region.current.region
  }))

  iam_instance_profile {
    name = var.instance_profile
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type = "gp3"
      encrypted   = true
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "anygroup-${var.environment}-app-server"
      Tier = "app"
    }
  }
}

resource "aws_autoscaling_group" "app" {
  name                      = "anygroup-${var.environment}-app-asg"
  vpc_zone_identifier       = var.subnet_ids
  min_size                  = var.min_size
  max_size                  = var.max_size
  desired_capacity          = var.min_size
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  # Capacity metrics for the dashboard
  metrics_granularity = "1Minute"
  enabled_metrics     = ["GroupDesiredCapacity", "GroupInServiceInstances"]

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 50
    }
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

# 60 percent rather than the usual 70, because EC2 scale-out takes minutes and
# the headroom covers provisioning time (report §6.4)
resource "aws_autoscaling_policy" "cpu" {
  name                   = "anygroup-${var.environment}-app-cpu"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    target_value = 60

    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
  }
}
