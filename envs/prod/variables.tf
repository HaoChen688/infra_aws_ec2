variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to SSH (must be fixed bastion CIDRs)"
  type        = list(string)
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
}

variable "prevent_destroy" {
  description = "Protect PROD EC2 from destroy (true recommended)"
  type        = bool
  default     = true
}