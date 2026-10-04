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
}

resource "aws_iam_role_policy" "deploy" {
  name   = "anygroup-dev-cicd-deploy-policy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
