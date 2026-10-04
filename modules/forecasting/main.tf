# Perishable stock forecasting (BR18), built on the CQRS split in the design
# patterns document. Oracle stays the command side; everything here is the
# query side and never touches checkout:
#
#   Oracle --Glue (nightly)--> data lake raw/ + curated/
#          --Glue succeeded--> EventBridge --> SageMaker pipeline (forecast)
#          --forecast lands--> Lambda perishable risk check
#          --> DynamoDB recommendations + SNS alert to managers

terraform {
  required_providers {
    archive = {
      source = "hashicorp/archive"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_subnet" "glue" {
  id = var.glue_subnet_id
}

locals {
  name       = "anygroup-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
}

# ---------------------------------------------------------------------------
# Data lake: separate from the catalogue bucket so its access, lifecycle and
# encryption can be set independently (report §7.4)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "lake" {
  bucket        = "${local.name}-datalake-${local.account_id}"
  force_destroy = true # dev only
}

resource "aws_s3_bucket_public_access_block" "lake" {
  bucket                  = aws_s3_bucket.lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "lake" {
  bucket = aws_s3_bucket.lake.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "glue_script" {
  bucket = aws_s3_bucket.lake.id
  key    = "scripts/glue_extract.py"
  source = "${path.module}/scripts/glue_extract.py"
  etag   = filemd5("${path.module}/scripts/glue_extract.py")
}

resource "aws_s3_object" "forecast_script" {
  bucket = aws_s3_bucket.lake.id
  key    = "scripts/forecast.py"
  source = "${path.module}/scripts/forecast.py"
  etag   = filemd5("${path.module}/scripts/forecast.py")
}

# ---------------------------------------------------------------------------
# Seed data access: the app tier reads the database credentials from Secrets
# Manager at runtime to load sample sales and stock batches
# ponytail: seeds with the master user. Give the app its own least-privilege
# database user before real data goes in.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "app_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }
}

resource "aws_iam_role_policy" "app_secret" {
  name   = "read-db-secret"
  role   = var.app_role_name
  policy = data.aws_iam_policy_document.app_secret.json
}

# ---------------------------------------------------------------------------
# Glue: extract from Oracle over JDBC inside the VPC. The connection lives in
# an app subnet, which has the S3 endpoint and NAT Glue needs, and the data
# tier only lets it in on the Oracle port.
# ---------------------------------------------------------------------------

resource "aws_security_group" "glue" {
  name        = "${local.name}-glue-sg"
  description = "Glue job ENIs: talk to each other, reach Oracle, S3 and AWS APIs"
  vpc_id      = data.aws_subnet.glue.vpc_id

  tags = {
    Name = "${local.name}-glue-sg"
  }
}

# Glue requires its workers to reach each other on all ports
resource "aws_vpc_security_group_ingress_rule" "glue_self" {
  security_group_id            = aws_security_group.glue.id
  description                  = "glue-workers"
  ip_protocol                  = "tcp"
  from_port                    = 0
  to_port                      = 65535
  referenced_security_group_id = aws_security_group.glue.id
}

resource "aws_vpc_security_group_egress_rule" "glue_all" {
  security_group_id = aws_security_group.glue.id
  description       = "oracle-s3-and-aws-apis"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_glue" {
  security_group_id            = var.db_sg_id
  description                  = "db-from-glue"
  ip_protocol                  = "tcp"
  from_port                    = 1521
  to_port                      = 1521
  referenced_security_group_id = aws_security_group.glue.id
}

resource "aws_glue_connection" "oracle" {
  name            = "${local.name}-oracle"
  connection_type = "JDBC"

  connection_properties = {
    JDBC_CONNECTION_URL = "jdbc:oracle:thin://@${var.db_host}:1521/${var.db_name}"
    SECRET_ID           = var.db_secret_arn
  }

  physical_connection_requirements {
    subnet_id              = var.glue_subnet_id
    availability_zone      = data.aws_subnet.glue.availability_zone
    security_group_id_list = [aws_security_group.glue.id]
  }
}

data "aws_iam_policy_document" "glue_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue" {
  name                 = "${local.name}-glue-role"
  path                 = "/anygroup/"
  assume_role_policy   = data.aws_iam_policy_document.glue_trust.json
  permissions_boundary = var.permissions_boundary_arn
}

# Glue's managed policy covers its VPC network interfaces and logging
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "glue" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.lake.arn]
  }

  statement {
    actions   = ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.lake.arn}/*"]
  }

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }
}

resource "aws_iam_role_policy" "glue" {
  name   = "datalake-and-db-secret"
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.glue.json
}

resource "aws_glue_job" "extract" {
  name              = "${local.name}-sales-extract"
  role_arn          = aws_iam_role.glue.arn
  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 15 # minutes
  connections       = [aws_glue_connection.oracle.name]

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${aws_s3_bucket.lake.id}/${aws_s3_object.glue_script.key}"
  }

  default_arguments = {
    "--CONNECTION_NAME"                  = aws_glue_connection.oracle.name
    "--BUCKET"                           = aws_s3_bucket.lake.id
    "--enable-continuous-cloudwatch-log" = "true"
  }
}

# Overnight, when checkout traffic is lowest (02:00 NZST)
resource "aws_glue_trigger" "nightly" {
  name     = "${local.name}-sales-extract-nightly"
  type     = "SCHEDULED"
  schedule = "cron(0 14 * * ? *)"

  actions {
    job_name = aws_glue_job.extract.name
  }
}

# ---------------------------------------------------------------------------
# SageMaker: replaces Amazon Forecast. A one-step pipeline runs the forecast
# script as a processing job on AWS's scikit-learn image and writes the
# result to curated/forecasts/. Billed per second while it runs.
# ---------------------------------------------------------------------------

data "aws_sagemaker_prebuilt_ecr_image" "sklearn" {
  count = var.forecast_image_uri == null ? 1 : 0

  repository_name = "sagemaker-scikit-learn"
  image_tag       = "1.2-1-cpu-py3"
}

data "aws_iam_policy_document" "sagemaker_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sagemaker" {
  name                 = "${local.name}-forecast-role"
  path                 = "/anygroup/"
  assume_role_policy   = data.aws_iam_policy_document.sagemaker_trust.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "sagemaker" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.lake.arn]
  }

  statement {
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.lake.arn}/*"]
  }

  # The pipeline uses this role to start and watch the processing job
  statement {
    actions = [
      "sagemaker:AddTags",
      "sagemaker:CreateProcessingJob",
      "sagemaker:DescribeProcessingJob",
      "sagemaker:StopProcessingJob",
    ]
    resources = ["arn:aws:sagemaker:${local.region}:${local.account_id}:processing-job/*"]
  }

  statement {
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.sagemaker.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["sagemaker.amazonaws.com"]
    }
  }

  # Pull the scikit-learn image from AWS's registry
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetAuthorizationToken",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["*"]
  }

  statement {
    actions = [
      "cloudwatch:PutMetricData",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "sagemaker" {
  name   = "forecast-processing"
  role   = aws_iam_role.sagemaker.id
  policy = data.aws_iam_policy_document.sagemaker.json
}

resource "aws_sagemaker_pipeline" "forecast" {
  pipeline_name         = "${local.name}-demand-forecast"
  pipeline_display_name = "${local.name}-demand-forecast"
  role_arn              = aws_iam_role.sagemaker.arn

  pipeline_definition = jsonencode({
    Version = "2020-12-01"
    Steps = [{
      Name = "DemandForecast"
      Type = "Processing"
      Arguments = {
        RoleArn = aws_iam_role.sagemaker.arn
        AppSpecification = {
          ImageUri            = coalesce(var.forecast_image_uri, one(data.aws_sagemaker_prebuilt_ecr_image.sklearn[*].registry_path))
          ContainerEntrypoint = ["python3", "/opt/ml/processing/code/forecast.py"]
        }
        ProcessingResources = {
          ClusterConfig = {
            InstanceCount  = 1
            InstanceType   = var.forecast_instance_type
            VolumeSizeInGB = 5
          }
        }
        ProcessingInputs = [
          {
            InputName = "code"
            S3Input = {
              S3Uri       = "s3://${aws_s3_bucket.lake.id}/${aws_s3_object.forecast_script.key}"
              LocalPath   = "/opt/ml/processing/code"
              S3DataType  = "S3Prefix"
              S3InputMode = "File"
            }
          },
          {
            InputName = "sales"
            S3Input = {
              S3Uri       = "s3://${aws_s3_bucket.lake.id}/curated/sales_daily/"
              LocalPath   = "/opt/ml/processing/input"
              S3DataType  = "S3Prefix"
              S3InputMode = "File"
            }
          },
        ]
        ProcessingOutputConfig = {
          Outputs = [{
            OutputName = "forecasts"
            S3Output = {
              S3Uri        = "s3://${aws_s3_bucket.lake.id}/curated/forecasts/"
              LocalPath    = "/opt/ml/processing/output"
              S3UploadMode = "EndOfJob"
            }
          }]
        }
        StoppingCondition = {
          MaxRuntimeInSeconds = 900
        }
      }
    }]
  })
}

# A successful Glue extract starts the forecast: no schedule to keep in step
resource "aws_cloudwatch_event_rule" "extract_succeeded" {
  name        = "${local.name}-extract-succeeded"
  description = "Start the demand forecast when the nightly sales extract succeeds"

  event_pattern = jsonencode({
    source        = ["aws.glue"]
    "detail-type" = ["Glue Job State Change"]
    detail = {
      jobName = [aws_glue_job.extract.name]
      state   = ["SUCCEEDED"]
    }
  })
}

data "aws_iam_policy_document" "events_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events" {
  name                 = "${local.name}-start-forecast-role"
  path                 = "/anygroup/"
  assume_role_policy   = data.aws_iam_policy_document.events_trust.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "events" {
  statement {
    actions   = ["sagemaker:StartPipelineExecution"]
    resources = [aws_sagemaker_pipeline.forecast.arn]
  }
}

resource "aws_iam_role_policy" "events" {
  name   = "start-forecast-pipeline"
  role   = aws_iam_role.events.id
  policy = data.aws_iam_policy_document.events.json
}

resource "aws_cloudwatch_event_target" "forecast" {
  rule     = aws_cloudwatch_event_rule.extract_succeeded.name
  arn      = aws_sagemaker_pipeline.forecast.arn
  role_arn = aws_iam_role.events.arn
}

# ---------------------------------------------------------------------------
# Results: recommendation history in DynamoDB, alerts to managers by SNS
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "recommendations" {
  name         = "${local.name}-stock-recommendations"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "product_id"
  range_key    = "generated_at"

  attribute {
    name = "product_id"
    type = "S"
  }

  attribute {
    name = "generated_at"
    type = "S"
  }
}

resource "aws_sns_topic" "stock_alerts" {
  name              = "${local.name}-stock-alerts"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "stock_alerts" {
  count = var.alert_email == null ? 0 : 1

  topic_arn = aws_sns_topic.stock_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------------------------------------------------------------------
# Lambda perishable risk check, triggered by a new forecast file
# ---------------------------------------------------------------------------

data "archive_file" "perishable_risk" {
  type        = "zip"
  source_file = "${path.module}/functions/perishable_risk.py"
  output_path = "${path.module}/.build/perishable_risk.zip"
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name                 = "${local.name}-perishable-risk-role"
  path                 = "/anygroup/"
  assume_role_policy   = data.aws_iam_policy_document.lambda_trust.json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name}-perishable-risk"
  retention_in_days = 30
}

data "aws_iam_policy_document" "lambda" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.lake.arn]
  }

  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.lake.arn}/curated/*"]
  }

  statement {
    actions   = ["dynamodb:BatchWriteItem", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.recommendations.arn]
  }

  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.stock_alerts.arn]
  }

  # The alert topic is encrypted with the AWS managed SNS key
  statement {
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["sns.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "read-lake-write-results"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

resource "aws_lambda_function" "perishable_risk" {
  function_name    = "${local.name}-perishable-risk"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "perishable_risk.handler"
  filename         = data.archive_file.perishable_risk.output_path
  source_code_hash = data.archive_file.perishable_risk.output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.recommendations.name
      TOPIC_ARN  = aws_sns_topic.stock_alerts.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

resource "aws_lambda_permission" "from_lake" {
  statement_id   = "AllowDataLakeForecastEvents"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.perishable_risk.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.lake.arn
  source_account = local.account_id
}

resource "aws_s3_bucket_notification" "forecast_ready" {
  bucket = aws_s3_bucket.lake.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.perishable_risk.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "curated/forecasts/"
    filter_suffix       = ".csv"
  }

  depends_on = [aws_lambda_permission.from_lake]
}
