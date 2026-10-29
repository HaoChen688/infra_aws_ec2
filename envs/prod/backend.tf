terraform {
  backend "s3" {
    bucket         = "myapp-tfstate-822952232701"
    key            = "terraform/prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "myapp-tf-lock-822952232701"
    encrypt        = true
  }
}