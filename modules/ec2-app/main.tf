# ---------- AMI ----------
data "aws_ami" "al2" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  ami          = var.ami_id != "" ? var.ami_id : data.aws_ami.al2[0].id
  name_prefix  = "${var.project}-${var.env}"
  role_name    = "${local.name_prefix}-ec2-role"
  profile_name = "${local.name_prefix}-ec2-profile"
  sg_name      = "${local.name_prefix}-sg"

  common_tags = merge(
    {
      Project   = var.project
      env       = var.env
      owner     = "platform"
      ManagedBy = "terraform"
    },
    var.extra_tags
  )
}

# ---------- Network (default VPC) ----------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ---------- IAM ----------
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = local.role_name
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "s3_read_startup" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.bootstrap_bucket}/${var.startup_s3_key}"]
  }
}

resource "aws_iam_role_policy" "s3_read_startup" {
  name   = "read-startup"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.s3_read_startup.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = local.profile_name
  role = aws_iam_role.ec2.name
  tags = local.common_tags
}

# ---------- Security Group ----------
resource "aws_security_group" "app" {
  name        = local.sg_name
  description = "SG for ${var.project} ${var.env}"
  vpc_id      = data.aws_vpc.default.id
  tags        = merge(local.common_tags, { Name = local.sg_name })

  # SSH admin cidr port  22
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
    description = "SSH from admin"
  }

  # App port
  ingress {
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    #cidr_blocks = [var.internal_app_cidr]
	cidr_blocks = ["0.0.0.0/0"]
    description = "App port internal"
  }

  # allow all outbount traffics
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------- user_data ----------
locals {
  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    yum update -y || true
    yum install -y curl awscli dos2unix

    cat >/usr/local/bin/run-startup.sh <<'WRAP'
    #!/bin/bash
    set -euo pipefail
    BUCKET="${var.bootstrap_bucket}"
    KEY="${var.startup_s3_key}"
    ENV="${var.env}"
    PROJECT="${var.project}"
    REGION="${var.region}"
    LOCAL=/usr/local/bin/startup.sh

    aws s3 cp "s3://$BUCKET/$KEY" "$LOCAL" --region "$REGION"
    dos2unix "$LOCAL" >/dev/null 2>&1 || sed -i 's/\r$//' "$LOCAL"
    chmod +x "$LOCAL"
    ENV_NAME="$ENV" PROJECT="$PROJECT" "$LOCAL"
    WRAP
    chmod +x /usr/local/bin/run-startup.sh

    cat >/etc/systemd/system/startup.service <<'UNIT'
    [Unit]
    Description=Run idempotent startup script from S3
    After=network-online.target cloud-init.service
    Wants=network-online.target

    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/run-startup.sh
    RemainAfterExit=no

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable startup.service
    systemctl start startup.service || true
  EOT
}

# ---------- EC2 ----------
resource "aws_instance" "app" {
  ami                         = local.ami
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  user_data                   = local.user_data
  user_data_replace_on_change = true

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp2"
  }

  tags = merge(local.common_tags, {
    Name = local.name_prefix
    env  = var.env
  })

  lifecycle {
    ignore_changes  = [ami]
  }
}