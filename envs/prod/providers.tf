provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "myapp"
      env       = "prod"
      ManagedBy = "terraform"
    }
  }
}