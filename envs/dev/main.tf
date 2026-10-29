locals {
  project          = "myapp"
  env              = "dev"
  account_id       = "822952232701"
  bootstrap_bucket = "myapp-bootstrap-${local.account_id}"
}

module "ec2_app" {
  source = "../../modules/ec2-app"

  project           = local.project
  env               = local.env
  region            = var.region
  instance_type     = var.instance_type
  key_name          = "app-key"
  admin_cidrs       = var.admin_cidrs
  bootstrap_bucket  = local.bootstrap_bucket
  app_port          = 8080
  internal_app_cidr = "10.0.0.0/8"
  root_volume_size  = 20
  prevent_destroy   = var.prevent_destroy

  extra_tags = {
    CostCenter = "dev"
  }
}