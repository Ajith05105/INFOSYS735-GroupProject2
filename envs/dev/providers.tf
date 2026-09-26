provider "aws" {
  region = "ap-southeast-6"

  default_tags {
    tags = {
      Project     = "anygroup"
      Owner       = "Ajith05105"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}
