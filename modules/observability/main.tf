data "aws_region" "current" {}

# One topic for operational alerts: scaling events and alarms. Email is the
# subscriber; the address must click the confirmation link AWS sends.
# ponytail: unencrypted, because CloudWatch alarms cannot publish to a topic
# encrypted with the AWS managed SNS key. A customer managed key fixes that.
resource "aws_sns_topic" "alerts" {
  name = "anygroup-${var.environment}-ops-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == null ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Every launch, termination and failure in either tier's Auto Scaling group
resource "aws_autoscaling_notification" "tiers" {
  group_names = [for tier in var.tiers : tier.asg_name]
  topic_arn   = aws_sns_topic.alerts.arn

  notifications = [
    "autoscaling:EC2_INSTANCE_LAUNCH",
    "autoscaling:EC2_INSTANCE_LAUNCH_ERROR",
    "autoscaling:EC2_INSTANCE_TERMINATE",
    "autoscaling:EC2_INSTANCE_TERMINATE_ERROR",
  ]
}

# Alarms that tell a person something is wrong. The scaling policies create
# their own alarms to drive capacity; these only notify.

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  for_each = var.tiers

  alarm_name          = "anygroup-${var.environment}-${each.key}-unhealthy-hosts"
  alarm_description   = "At least one ${each.key} instance is failing load balancer health checks"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = each.value.alb_arn_suffix
    TargetGroup  = each.value.target_group_arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  for_each = var.tiers

  alarm_name          = "anygroup-${var.environment}-${each.key}-5xx-errors"
  alarm_description   = "${each.key} instances returned more than 10 server errors in 5 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = each.value.alb_arn_suffix
    TargetGroup  = each.value.target_group_arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  for_each = var.tiers

  alarm_name          = "anygroup-${var.environment}-${each.key}-cpu-high"
  alarm_description   = "${each.key} tier average CPU above 80 percent for 10 minutes, even after scaling"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    AutoScalingGroupName = each.value.asg_name
  }
}

# The single operational pane (BR14): traffic, latency, health and capacity
# for both tiers side by side
locals {
  region = data.aws_region.current.region

  alb_metric = {
    for name, tier in var.tiers : name => {
      requests = ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", tier.alb_arn_suffix]
      latency  = ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", tier.alb_arn_suffix]
      healthy  = ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", tier.alb_arn_suffix, "TargetGroup", tier.target_group_arn_suffix]
      cpu      = ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", tier.asg_name]
      capacity = ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", tier.asg_name]
    }
  }

  widgets = [
    { title = "Requests", key = "requests", stat = "Sum" },
    { title = "Response time (seconds)", key = "latency", stat = "Average" },
    { title = "Healthy instances", key = "healthy", stat = "Minimum" },
    { title = "CPU utilisation (%)", key = "cpu", stat = "Average" },
    { title = "In-service instances", key = "capacity", stat = "Average" },
  ]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "anygroup-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      for i, w in local.widgets : {
        type   = "metric"
        x      = (i % 2) * 12
        y      = floor(i / 2) * 6
        width  = 12
        height = 6
        properties = {
          title   = w.title
          region  = local.region
          stat    = w.stat
          period  = 60
          view    = "timeSeries"
          metrics = [for name, m in local.alb_metric : concat(m[w.key], [{ label = name }])]
        }
      }
    ]
  })
}

# VPC Flow Logs at the VPC level, so every network interface Auto Scaling
# creates later is covered without any per-instance setup (report §5.6)

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/anygroup/${var.environment}/vpc-flow-logs"
  retention_in_days = 365 # PCI DSS 10.5.1: one year
}

data "aws_iam_policy_document" "flow_logs_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name                 = "anygroup-${var.environment}-flow-logs-role"
  path                 = "/anygroup/"
  assume_role_policy   = data.aws_iam_policy_document.flow_logs_trust.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}

resource "aws_flow_log" "vpc" {
  vpc_id                   = var.vpc_id
  traffic_type             = "ALL"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60

  tags = {
    Name = "anygroup-${var.environment}-vpc-flow-log"
  }
}
