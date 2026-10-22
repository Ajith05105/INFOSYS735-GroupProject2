provider "aws" {
  region = "ap-southeast-6"

  default_tags {
    tags = {
      Project     = "anygroup"
      Owner       = "Ajith05105"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# CloudFront's WAF web ACL and viewer certificate must be created in us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "anygroup"
      Owner       = "Ajith05105"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
