terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # CloudFront's WAF web ACL and viewer certificate must live in us-east-1
      configuration_aliases = [aws.us_east_1]
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  https = var.domain_name != null
}

# Catalogue images: replaces the 5 TB image server with no capacity ceiling
# (BR6). Private; the only way in is CloudFront through Origin Access Control,
# so WAF and Shield apply to every read (BR7).

resource "aws_s3_bucket" "catalogue" {
  bucket        = "anygroup-${var.environment}-catalogue-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # dev only: lets destroy empty the bucket
}

resource "aws_s3_bucket_public_access_block" "catalogue" {
  bucket                  = aws_s3_bucket.catalogue.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "catalogue" {
  bucket = aws_s3_bucket.catalogue.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "catalogue" {
  bucket = aws_s3_bucket.catalogue.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Long-tail access patterns nobody can predict, so let S3 tier each object by
# observed access instead of a hand-written lifecycle (report §7.3)
resource "aws_s3_bucket_lifecycle_configuration" "catalogue" {
  bucket = aws_s3_bucket.catalogue.id

  rule {
    id     = "intelligent-tiering"
    status = "Enabled"

    filter {}

    transition {
      days          = 0
      storage_class = "INTELLIGENT_TIERING"
    }
  }
}

# A sample catalogue image so the demo page shows the S3 path working
resource "aws_s3_object" "sample" {
  bucket        = aws_s3_bucket.catalogue.id
  key           = "images/catalogue-sample.svg"
  content_type  = "image/svg+xml"
  storage_class = "INTELLIGENT_TIERING"
  content       = <<-EOT
    <svg xmlns="http://www.w3.org/2000/svg" width="320" height="120" viewBox="0 0 320 120">
      <rect width="320" height="120" rx="12" fill="#1f6f43"/>
      <text x="160" y="55" text-anchor="middle" font-family="sans-serif" font-size="20" fill="#fff">Catalogue image</text>
      <text x="160" y="85" text-anchor="middle" font-family="sans-serif" font-size="14" fill="#cfe8d8">S3 via CloudFront</text>
    </svg>
  EOT
}

resource "aws_cloudfront_origin_access_control" "catalogue" {
  name                              = "anygroup-${var.environment}-catalogue-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "catalogue" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.catalogue.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    # Only this distribution, not any CloudFront distribution in any account
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "catalogue" {
  bucket = aws_s3_bucket.catalogue.id
  policy = data.aws_iam_policy_document.catalogue.json

  depends_on = [aws_s3_bucket_public_access_block.catalogue]
}

# WAF at the edge, so malicious requests are dropped before they consume any
# origin capacity, NAT bandwidth or app resources (report §5.2). Also covers
# PCI DSS 6.4.2.

resource "aws_wafv2_web_acl" "this" {
  provider = aws.us_east_1

  name  = "anygroup-${var.environment}-edge-waf"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = {
      common-rules     = { priority = 10, group = "AWSManagedRulesCommonRuleSet" } # OWASP Top 10 style attacks
      known-bad-inputs = { priority = 20, group = "AWSManagedRulesKnownBadInputsRuleSet" }
      ip-reputation    = { priority = 30, group = "AWSManagedRulesAmazonIpReputationList" }
    }

    content {
      name     = rule.key
      priority = rule.value.priority

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.value.group
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = true
        metric_name                = rule.key
      }
    }
  }

  # Blocks any single IP sending more than the limit in 5 minutes
  rule {
    name     = "rate-limit"
    priority = 40

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "rate-limit"
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    sampled_requests_enabled   = true
    metric_name                = "anygroup-${var.environment}-edge-waf"
  }
}

# Viewer certificate, only with a domain. Without one, viewers get HTTPS on
# the cloudfront.net hostname with CloudFront's own certificate.

data "aws_route53_zone" "this" {
  count = local.https ? 1 : 0
  name  = var.domain_name
}

resource "aws_acm_certificate" "viewer" {
  provider = aws.us_east_1
  count    = local.https ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "viewer_validation" {
  count           = local.https ? 1 : 0
  zone_id         = data.aws_route53_zone.this[0].zone_id
  name            = tolist(aws_acm_certificate.viewer[0].domain_validation_options)[0].resource_record_name
  type            = tolist(aws_acm_certificate.viewer[0].domain_validation_options)[0].resource_record_type
  records         = [tolist(aws_acm_certificate.viewer[0].domain_validation_options)[0].resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "viewer" {
  provider = aws.us_east_1
  count    = local.https ? 1 : 0

  certificate_arn         = aws_acm_certificate.viewer[0].arn
  validation_record_fqdns = [aws_route53_record.viewer_validation[0].fqdn]
}

# The distribution: dynamic requests go to the web ALB uncached, /images/*
# comes from S3 cached at the edge

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  comment         = "AnyGroupLLC ${var.environment}"
  aliases         = local.https ? [var.domain_name] : []
  price_class     = "PriceClass_All" # includes New Zealand and Australia edge locations
  http_version    = "http2and3"
  is_ipv6_enabled = true
  web_acl_id      = aws_wafv2_web_acl.this.arn

  origin {
    origin_id   = "web-alb"
    domain_name = var.origin_domain

    # The ALB only forwards requests carrying this header
    custom_header {
      name  = "X-Origin-Verify"
      value = var.origin_secret
    }

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = local.https ? "https-only" : "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  origin {
    origin_id                = "catalogue"
    domain_name              = aws_s3_bucket.catalogue.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.catalogue.id
  }

  default_cache_behavior {
    target_origin_id         = "web-alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    compress                 = true
  }

  ordered_cache_behavior {
    path_pattern           = "/images/*"
    target_origin_id       = "catalogue"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = !local.https
    acm_certificate_arn            = local.https ? aws_acm_certificate_validation.viewer[0].certificate_arn : null
    ssl_support_method             = local.https ? "sni-only" : null
    minimum_protocol_version       = local.https ? "TLSv1.2_2021" : null
  }
}

resource "aws_route53_record" "site" {
  count   = local.https ? 1 : 0
  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}
