variable "project" {
  description = "Project name, used for naming and tags"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase alphanumeric/hyphen, 2-21 chars."
  }
}

variable "env" {
  description = "Environment: dev or prod"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.env)
    error_message = "env must be dev or prod."
  }
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
}

variable "ami_id" {
  description = "Explicit AMI ID; empty = auto-discover latest Amazon Linux 2"
  type        = string
  default     = ""
}

variable "key_name" {
  description = "Existing EC2 Key Pair name (admin login key)"
  type        = string
  default     = "app-key"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to SSH (port 22)"
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0
    error_message = "admin_cidrs must not be empty."
  }
}

variable "bootstrap_bucket" {
  description = "S3 bucket hosting scripts/startup.sh"
  type        = string
}

variable "startup_s3_key" {
  description = "S3 key of startup.sh"
  type        = string
  default     = "scripts/startup.sh"
}

variable "app_port" {
  description = "Application port (internal)"
  type        = number
  default     = 8080
}

variable "internal_app_cidr" {
  description = "CIDR allowed to reach app_port"
  type        = string
  default     = "10.0.0.0/8"
}

variable "root_volume_size" {
  description = "Root EBS volume size (GB)"
  type        = number
  default     = 20
}

variable "prevent_destroy" {
  description = "Protect the EC2 instance from accidental destroy (recommended true for prod)"
  type        = bool
  default     = false
}

variable "extra_tags" {
  description = "Additional tags merged into all resources"
  type        = map(string)
  default     = {}
}