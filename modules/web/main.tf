locals {
  # Same rule as local.origin_port in envs/dev
  https = var.domain_name != null
}

# Latest Amazon Linux 2023 for whichever CPU architecture the instance type uses
data "aws_ec2_instance_type" "web" {
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
    values = [data.aws_ec2_instance_type.web.supported_architectures[0]]
  }
}

# Internet-facing ALB in the public subnets. Its security group only admits
# CloudFront, and the listener only forwards requests carrying the secret
# header CloudFront adds, so the edge protections (WAF, Shield) cannot be
# bypassed by calling the ALB directly.

resource "aws_lb" "web" {
  name                       = "anygroup-${var.environment}-web-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [var.alb_sg_id]
  subnets                    = var.alb_subnet_ids
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "web" {
  name                 = "anygroup-${var.environment}-web-tg"
  port                 = 80
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

resource "random_password" "origin_secret" {
  length  = 32
  special = false
}

resource "aws_lb_listener" "web" {
  load_balancer_arn = aws_lb.web.arn
  port              = local.https ? 443 : 80
  protocol          = local.https ? "HTTPS" : "HTTP"
  ssl_policy        = local.https ? "ELBSecurityPolicy-TLS13-1-2-2021-06" : null # TLS 1.2 minimum
  certificate_arn   = local.https ? aws_acm_certificate_validation.origin[0].certificate_arn : null

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "from_cloudfront" {
  listener_arn = aws_lb_listener.web.arn
  priority     = 1

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin_secret.result]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# With a domain: origin.<domain> points at the ALB with a DNS-validated ACM
# certificate, so CloudFront can verify the ALB over HTTPS.

data "aws_route53_zone" "this" {
  count = local.https ? 1 : 0
  name  = var.domain_name
}

resource "aws_acm_certificate" "origin" {
  count             = local.https ? 1 : 0
  domain_name       = "origin.${var.domain_name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "origin_validation" {
  count           = local.https ? 1 : 0
  zone_id         = data.aws_route53_zone.this[0].zone_id
  name            = tolist(aws_acm_certificate.origin[0].domain_validation_options)[0].resource_record_name
  type            = tolist(aws_acm_certificate.origin[0].domain_validation_options)[0].resource_record_type
  records         = [tolist(aws_acm_certificate.origin[0].domain_validation_options)[0].resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "origin" {
  count                   = local.https ? 1 : 0
  certificate_arn         = aws_acm_certificate.origin[0].arn
  validation_record_fqdns = [aws_route53_record.origin_validation[0].fqdn]
}

resource "aws_route53_record" "origin" {
  count   = local.https ? 1 : 0
  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = "origin.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.web.dns_name
    zone_id                = aws_lb.web.zone_id
    evaluate_target_health = true
  }
}

# Apache instances in the private web subnets, one or more per AZ

resource "aws_launch_template" "web" {
  name                   = "anygroup-${var.environment}-web-lt"
  image_id               = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  vpc_security_group_ids = [var.instance_sg_id]
  user_data              = filebase64("${path.module}/user_data.sh")
  update_default_version = true

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
      Name = "anygroup-${var.environment}-web-server"
      Tier = "web"
    }
  }
}

resource "aws_autoscaling_group" "web" {
  name                      = "anygroup-${var.environment}-web-asg"
  vpc_zone_identifier       = var.instance_subnet_ids
  min_size                  = var.min_size
  max_size                  = var.max_size
  desired_capacity          = var.min_size
  target_group_arns         = [aws_lb_target_group.web.arn]
  health_check_type         = "ELB" # replaces instances that run but stop serving
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.web.id
    version = aws_launch_template.web.latest_version
  }

  # A new launch template version (new AMI, new script) rolls through the
  # fleet automatically: patching by replacement, not by logging in.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 50
    }
  }

  # Scaling policies own the desired count once the group exists
  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

# Requests rise before CPU does, so scaling on requests per instance reacts
# earlier than a CPU policy would (report §6.3)
resource "aws_autoscaling_policy" "requests" {
  name                   = "anygroup-${var.environment}-web-requests-per-target"
  autoscaling_group_name = aws_autoscaling_group.web.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    target_value = 100

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.web.arn_suffix}/${aws_lb_target_group.web.arn_suffix}"
    }
  }
}

# Known seasonal peaks get capacity before the traffic arrives. Halloween is
# the example: full capacity for the day, back to baseline afterwards.
resource "aws_autoscaling_schedule" "halloween_start" {
  scheduled_action_name  = "halloween-scale-out"
  autoscaling_group_name = aws_autoscaling_group.web.name
  recurrence             = "0 6 31 10 *"
  time_zone              = "Pacific/Auckland"
  min_size               = var.max_size
  max_size               = var.max_size
  desired_capacity       = var.max_size
}

resource "aws_autoscaling_schedule" "halloween_end" {
  scheduled_action_name  = "halloween-scale-in"
  autoscaling_group_name = aws_autoscaling_group.web.name
  recurrence             = "0 6 1 11 *"
  time_zone              = "Pacific/Auckland"
  min_size               = var.min_size
  max_size               = var.max_size
  desired_capacity       = var.min_size
}
