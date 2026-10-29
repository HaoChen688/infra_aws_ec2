region          = "us-east-1"
instance_type   = "t2.micro"
prevent_destroy = true

# PROD：固定跳板机 CIDR，禁止自动探测
admin_cidrs = [
  "203.0.113.10/32",
  # "198.51.100.0/24",
]