terraform {
  required_version = "~> 1.16"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # Dev state lives in the bucket created by bootstrap. Backend blocks cannot
  # use variables, so these values are literal.
  backend "s3" {
    bucket       = "anygroup-dev-bootstrap-tfstate-ap-southeast-6"
    key          = "envs/dev/terraform.tfstate"
    region       = "ap-southeast-6"
    encrypt      = true
    use_lockfile = true
  }
}