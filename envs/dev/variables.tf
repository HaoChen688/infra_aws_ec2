variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to SSH"
  type        = list(string)
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
}

variable "prevent_destroy" {
  description = "Protect EC2 from destroy (false for dev)"
  type        = bool
  default     = false
}