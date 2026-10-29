output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "EC2 public IP"
  value       = aws_instance.app.public_ip
}

output "private_ip" {
  description = "EC2 private IP"
  value       = aws_instance.app.private_ip
}

output "sg_id" {
  description = "Security Group ID"
  value       = aws_security_group.app.id
}

output "iam_role_name" {
  description = "IAM Role name"
  value       = aws_iam_role.ec2.name
}

output "iam_instance_profile_name" {
  description = "IAM Instance Profile name"
  value       = aws_iam_instance_profile.ec2.name
}

output "ami_used" {
  description = "AMI ID actually used"
  value       = local.ami
}