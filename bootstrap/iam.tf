# GitHub Actions OIDC identity provider. AWS validates GitHub's certificate
# against its own trusted CAs, so no thumbprint is pinned.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# Plan role: read-only, for pull request workflows
data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:pull_request"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "anygroup-dev-cicd-plan-role"
  path               = "/cicd/"
  description        = "Read-only role for terraform plan in pull request workflows"
  assume_role_policy = data.aws_iam_policy_document.plan_trust.json
}

# Plan has to refresh every resource type the stack manages, so it gets AWS's
# read-only policy instead of a hand-kept list that breaks each time a module
# adds a new service. It covers reading the state bucket too.
resource "aws_iam_role_policy_attachment" "plan" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Deploy role: plan and apply, assumable only from the deploy branch
data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/${var.github_deploy_branch}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "anygroup-dev-cicd-deploy-role"
  path               = "/cicd/"
  description        = "Deploy role for terraform apply from the ${var.github_deploy_branch} branch"
  assume_role_policy = data.aws_iam_policy_document.deploy_trust.json
}

data "aws_iam_policy_document" "deploy" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/envs/*"]
  }

  # Infrastructure permissions get added here as modules need them

  # EC2 covers the whole network and compute layer: VPC, subnets, routing, NAT
  # instances, NACLs, endpoints, security groups, launch templates. Listing
  # actions one by one failed applies every time a module needed a new one,
  # and only an admin can re-apply bootstrap. Pinned to the project region.
  statement {
    actions   = ["ec2:*"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  # Security module: workload roles and instance profiles under /anygroup/.
  # CreateRole only succeeds when the new role carries the workload boundary,
  # so deploy cannot mint a role more powerful than the boundary allows.
  statement {
    actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
    resources = ["arn:aws:iam::${local.account_id}:role/anygroup/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.workload_boundary.arn]
    }
  }

  statement {
    actions = [
      "iam:AttachRolePolicy",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:PutRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/anygroup/*"]
  }

  statement {
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = ["arn:aws:iam::${local.account_id}:instance-profile/anygroup/*"]
  }

  # Workload roles can only be handed to the services that run them
  statement {
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/anygroup/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "anygroup-dev-cicd-deploy-policy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# Ceiling for every role the deploy role creates (EC2 instance roles, and the
# Glue, Lambda and flow log roles that come later). A role's effective
# permissions are its policies intersected with this, so even an admin policy
# attached to a workload role cannot reach IAM, billing or anything outside
# these services. Owned here so CI cannot edit its own ceiling.
data "aws_iam_policy_document" "workload_boundary" {
  statement {
    actions = [
      "cloudwatch:*",
      "ec2:Describe*",
      "ec2messages:*",
      "glue:*",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "logs:*",
      "s3:*",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "sns:Publish",
      "ssm:*",
      "ssmmessages:*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = "anygroup-workload-boundary"
  path        = "/anygroup/"
  description = "Permissions boundary for every workload role created by the deploy role"
  policy      = data.aws_iam_policy_document.workload_boundary.json
}
