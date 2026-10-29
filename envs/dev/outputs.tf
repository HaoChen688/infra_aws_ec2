output "instance_id" {
  description = "DEV EC2 instance ID"
  value       = module.ec2_app.instance_id
}

output "public_ip" {
  description = "DEV EC2 public IP"
  value       = module.ec2_app.public_ip
}

output "private_ip" {
  description = "DEV EC2 private IP"
  value       = module.ec2_app.private_ip
}

output "sg_id" {
  description = "DEV Security Group ID"
  value       = module.ec2_app.sg_id
}

output "iam_role_name" {
  value = module.ec2_app.iam_role_name
}

output "iam_instance_profile_name" {
  value = module.ec2_app.iam_instance_profile_name
}

output "ami_used" {
  value = module.ec2_app.ami_used
}

output "env_tag" {
  description = "Value of tag:env for this environment"
  value       = "dev"
}