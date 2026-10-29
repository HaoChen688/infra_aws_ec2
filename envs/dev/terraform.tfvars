region          = "us-east-1"
instance_type   = "t2.micro"
prevent_destroy = false

# DEV：可临时用本机出口 IP；多人协作时列多个
admin_cidrs = [
  #"203.0.113.10/32",
  "66.90.98.106/32",
  "203.0.113.55/32",  # 你的新 IP
  "0.0.0.0/0",
]