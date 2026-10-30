region          = "us-east-1"
instance_type   = "t2.micro"
prevent_destroy = false

# DEV：可临时用本机出口 IP；多人协作时列多个
admin_cidrs = [
  #"203.0.113.10/32",
  "0.0.0.0/0",
]