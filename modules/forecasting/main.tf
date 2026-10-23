# Perishable stock forecasting (BR18), built on the CQRS split in the design
# patterns document. PostgreSQL stays the command side; everything here is the
# query side and never touches checkout:
#
#   PostgreSQL --Glue (nightly)--> data lake raw/ + curated/
#              --extract succeeded--> Glue Python shell job (forecast)
#              --forecast lands--> Lambda perishable risk check
#              --> DynamoDB recommendations + SNS alert to managers

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
# Glue: extract from PostgreSQL over JDBC inside the VPC. The connection lives in
# an app subnet, which has the S3 endpoint and NAT Glue needs, and the data
# tier only lets it in on the PostgreSQL port.
# ---------------------------------------------------------------------------

resource "aws_security_group" "glue" {
  name        = "${local.name}-glue-sg"
  description = "Glue job ENIs: talk to each other, reach PostgreSQL, S3 and AWS APIs"
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
  description       = "postgres-s3-and-aws-apis"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_glue" {
  security_group_id            = var.db_sg_id
  description                  = "db-from-glue"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.glue.id
}

resource "aws_glue_connection" "postgres" {
  name            = "${local.name}-postgres"
  connection_type = "JDBC"

  connection_properties = {
    JDBC_CONNECTION_URL = "jdbc:postgresql://${var.db_host}:5432/${var.db_name}"
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
  connections       = [aws_glue_connection.postgres.name]

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${aws_s3_bucket.lake.id}/${aws_s3_object.glue_script.key}"
  }

  default_arguments = {
    "--CONNECTION_NAME"                  = aws_glue_connection.postgres.name
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
# Forecast: replaces Amazon Forecast. A Glue Python shell job runs the
# forecast script on the curated sales and writes the result to
# curated/forecasts/. SageMaker's scikit-learn image is not published in
# ap-southeast-6, so the script runs on Glue instead. 1/16 DPU, billed per
# second while it runs.
# ---------------------------------------------------------------------------

resource "aws_glue_job" "forecast" {
  name         = "${local.name}-demand-forecast"
  role_arn     = aws_iam_role.glue.arn
  glue_version = "3.0" # Python shell 3.9 runs on Glue 3.0; the default is rejected
  max_capacity = 0.0625
  timeout      = 15 # minutes

  command {
    name            = "pythonshell"
    python_version  = "3.9"
    script_location = "s3://${aws_s3_bucket.lake.id}/${aws_s3_object.forecast_script.key}"
  }

  default_arguments = {
    "--BUCKET"    = aws_s3_bucket.lake.id
    "library-set" = "analytics" # pandas
  }
}

# A successful extract starts the forecast: no schedule to keep in step.
# Glue only fires this when the extract itself was started by a trigger.
resource "aws_glue_trigger" "forecast" {
  name = "${local.name}-demand-forecast-after-extract"
  type = "CONDITIONAL"

  actions {
    job_name = aws_glue_job.forecast.name
  }

  predicate {
    conditions {
      job_name = aws_glue_job.extract.name
      state    = "SUCCEEDED"
    }
  }
}

# Start this to run the whole chain on demand (a manual job run would not
# fire the forecast trigger)
resource "aws_glue_trigger" "run_now" {
  name = "${local.name}-sales-extract-run-now"
  type = "ON_DEMAND"

  actions {
    job_name = aws_glue_job.extract.name
  }
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
