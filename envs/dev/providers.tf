provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "myapp"
      env       = "dev"
      ManagedBy = "terraform"
    }
  }
}