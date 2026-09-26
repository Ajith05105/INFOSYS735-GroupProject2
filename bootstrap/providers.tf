provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "anygroup"
      Owner       = "Ajith05105"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}
