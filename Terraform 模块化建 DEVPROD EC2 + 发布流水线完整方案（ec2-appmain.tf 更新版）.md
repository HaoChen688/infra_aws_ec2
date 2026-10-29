# Terraform 模块化建 DEV/PROD EC2 + 发布流水线完整方案（`ec2-app/main.tf` 更新版）

> **本次修订点**：
>
> 1. **`modules/ec2-app/main.tf` 改为你提供的新内容**：SG 用内联 `ingress`/`egress`（`cidr_blocks = var.admin_cidrs` 一次写多个 CIDR），不再用 `aws_vpc_security_group_ingress_rule` 逐条资源；`lifecycle` 只保留 `ignore_changes = [ami]`（去掉了 `prevent_destroy`）。
> 2. **随之调整的模块接口**：
>    - `modules/ec2-app/variables.tf` 里 **`prevent_destroy` 变量保留但模块不再使用**（`main.tf` 的 `lifecycle` 已移除 `prevent_destroy`）。为避免"变量声明了但没用"的困惑，下文 **删除 `prevent_destroy` 变量**，并同步删除 `envs/dev|prod` 对它的传参；PROD 防误删改为**流程约束**（workflow 无 destroy 选项）。
>    - `modules/ec2-app/outputs.tf` 不变。
> 3. **`envs/dev/main.tf`、`envs/prod/main.tf` 同步去掉 `prevent_destroy = var.prevent_destroy`**；`envs/*/variables.tf`、`terraform.tfvars` 去掉 `prevent_destroy`。
> 4. **SG 行为变化说明**：内联 `ingress.cidr_blocks = var.admin_cidrs` 是**声明式整体覆盖**——改 `admin_cidrs` 时 Terraform 会把 22 端口的 CIDR 集合整体替换为列表内容（不会残留旧 IP），比逐条 `aws_vpc_security_group_ingress_rule` 更简洁。
> 5. 其余文件（`.gitignore`、`startup.sh`、`terraform-*.yml`、`deploy-*.yml`、发版流程、公钥写入、排查）**保持不变**，下文给出完整展开。

------

## 目录

1. 目录结构总览
2. `.gitignore`
3. 上传前自检
4. 前置准备 + `startup.sh`
5. 模块 `modules/ec2-app`（**[main.tf](https://main.tf/) 已更新**）
6. `envs/dev`（**已去掉 prevent_destroy**）
7. `envs/prod`（**已去掉 prevent_destroy**）
8. Terraform CI 用户
9. `terraform-dev.yml`
10. `terraform-prod.yml`
11. 手动跑一遍 DEV
12. `deploy-dev.yml`
13. `deploy-prod.yml`
14. 发版流程（dev → main → tag）
15. 写入发布公钥
16. 回滚 / 安全 / 排查
17. 附录：实施顺序

------

## 1. 目录结构总览

text

```
infra_aws_ec2/                          # repo-root
├── .gitignore
├── modules/
│   └── ec2-app/
│       ├── versions.tf
│       ├── variables.tf
│       ├── main.tf                     # ★ 本次更新
│       └── outputs.tf
├── envs/
│   ├── dev/
│   │   ├── versions.tf
│   │   ├── providers.tf
│   │   ├── backend.tf
│   │   ├── variables.tf               # ★ 去掉 prevent_destroy
│   │   ├── terraform.tfvars            # ★ 去掉 prevent_destroy
│   │   ├── main.tf                     # ★ 去掉 prevent_destroy 传参
│   │   └── outputs.tf
│   └── prod/
│       ├── versions.tf
│       ├── providers.tf
│       ├── backend.tf
│       ├── variables.tf                # ★ 去掉 prevent_destroy
│       ├── terraform.tfvars            # ★ 去掉 prevent_destroy
│       ├── main.tf                     # ★ 去掉 prevent_destroy 传参
│       └── outputs.tf
├── scripts/
│   └── startup.sh
└── .github/
    └── workflows/
        ├── terraform-dev.yml
        ├── terraform-prod.yml
        ├── deploy-dev.yml
        └── deploy-prod.yml
```



------

## 2. `.gitignore`

gitignore

```
# ============================================================
# Terraform
# ============================================================
.terraform/
**/.terraform/*
.terraform.tfstate.lock.info

*.tfstate
*.tfstate.*
*.tfstate.backup

tfplan
*.tfplan
plan.out

override.auto.tfvars
*.auto.tfvars

crash.log
crash.*.log

# 注意：.terraform.lock.hcl 不忽略，应入库

# ============================================================
# 密钥 / 凭证
# ============================================================
*.pem
*.key

gha_key
gha_key.pub

.ssh/
id_rsa
id_rsa.pub
id_ed25519
id_ed25519.pub

.env
.env.*
!.env.example

.aws/
credentials

# ============================================================
# 构建产物 / 依赖
# ============================================================
dist/
build/
node_modules/
target/
*.tar.gz
*.zip

# ============================================================
# 系统 / 编辑器
# ============================================================
.DS_Store
Thumbs.db
.idea/
.vscode/
*.swp
*.swo
*~

# ============================================================
# 日志
# ============================================================
*.log
logs/
```



------

## 3. 上传前自检

bash

```
cd infra_aws_ec2

git status --short

git check-ignore -v .terraform/ 2>/dev/null || echo "NOT ignored (bad)"
git check-ignore -v envs/dev/terraform.tfstate 2>/dev/null || echo "NOT ignored (bad)"
git check-ignore -v tfplan 2>/dev/null || echo "NOT ignored (bad)"
git check-ignore -v gha_key 2>/dev/null || echo "NOT ignored (bad)"

git ls-files | grep -E '\.terraform/|\.tfstate|tfplan|gha_key|\.pem$|\.env$' \
  || echo "OK: no sensitive files tracked"
```



若已跟踪敏感文件：

bash

```
git rm --cached -r .terraform/
git rm --cached envs/dev/terraform.tfstate 2>/dev/null || true
git rm --cached tfplan 2>/dev/null || true
git rm --cached gha_key gha_key.pub 2>/dev/null || true
git add .gitignore
git commit -m "chore: add .gitignore for terraform artifacts and keys"
```



> 私钥一旦 push 过，视为泄漏：删旧 Key Pair、重建 `gha_key`、更新 Secrets、必要时 `git filter-repo` 清历史。

------

## 4. 前置准备 + `startup.sh`

bash

```
cd infra_aws_ec2
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1

# Key Pair（管理员登录用）
aws ec2 describe-key-pairs --region $REGION --key-names app-key >/dev/null 2>&1 || \
  aws ec2 create-key-pair --region $REGION --key-name app-key \
    --query 'KeyMaterial' --output text > ~/.ssh/app-key.pem
chmod 600 ~/.ssh/app-key.pem

# bootstrap 桶 + startup.sh
BUCKET=myapp-bootstrap-${ACCOUNT}
aws s3api head-bucket --bucket $BUCKET 2>/dev/null || \
  aws s3api create-bucket --bucket $BUCKET --region $REGION
aws s3api put-bucket-versioning --bucket $BUCKET --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket $BUCKET \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
dos2unix scripts/startup.sh 2>/dev/null || sed -i 's/\r$//' scripts/startup.sh
aws s3 cp scripts/startup.sh "s3://$BUCKET/scripts/startup.sh" \
  --region $REGION --content-type text/x-shellscript

# TF state 桶 + 锁表
TFSTATE_BUCKET=myapp-tfstate-${ACCOUNT}
TFLOCK_TABLE=myapp-tf-lock-${ACCOUNT}
aws s3api head-bucket --bucket $TFSTATE_BUCKET 2>/dev/null || \
  aws s3api create-bucket --bucket $TFSTATE_BUCKET --region $REGION
aws s3api put-bucket-versioning --bucket $TFSTATE_BUCKET --versioning-configuration Status=Enabled
aws dynamodb describe-table --table-name $TFLOCK_TABLE --region $REGION >/dev/null 2>&1 || \
  aws dynamodb create-table --table-name $TFLOCK_TABLE \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST --region $REGION
```



### `scripts/startup.sh`

bash

```
#!/bin/bash
# Idempotent startup script for EC2 hosts.
set -uo pipefail

LOG=/var/log/app-bootstrap.log
STATE_DIR=/var/lib/app-bootstrap
ENV_NAME="${ENV_NAME:-unknown}"
PROJECT="${PROJECT:-myapp}"
mkdir -p "$STATE_DIR"

log() { echo "[$(date -Is)] $*" | tee -a "$LOG"; }
mark_done() { touch "$STATE_DIR/$1.done"; }
is_done()   { [[ -f "$STATE_DIR/$1.done" ]]; }

step_hostname() {
  local ip suffix new_host current
  ip=$(curl -fsS --max-time 3 http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || true)
  if [[ -n "${ip}" ]]; then
    suffix=$(echo "$ip" | awk -F. '{printf "%02x%02x", $3, $4}')
  else
    suffix=$(hostname | md5sum | cut -c1-4)
  fi
  new_host="${PROJECT}-${ENV_NAME}-${suffix}"
  current=$(hostname)
  if [[ "$current" != "$new_host" ]]; then
    log "hostname: $current -> $new_host"
    hostnamectl set-hostname "$new_host"
    grep -q "$new_host" /etc/hosts || echo "127.0.1.1 $new_host" >> /etc/hosts
  else
    log "hostname already correct: $current"
  fi
  mark_done hostname
}

step_firewall() {
  if ! command -v firewall-cmd >/dev/null 2>&1; then
    log "firewalld not installed, skip"
    mark_done firewall
    return
  fi
  if [[ "$ENV_NAME" == "dev" ]]; then
    if systemctl is-active --quiet firewalld; then
      log "disabling firewalld (dev)"
      systemctl disable --now firewalld
    else
      log "firewalld already disabled"
    fi
  else
    systemctl enable --now firewalld >/dev/null 2>&1 || true
    if ! firewall-cmd --list-ports | grep -q "8080/tcp"; then
      log "opening 8080/tcp in firewalld (prod)"
      firewall-cmd --permanent --add-port=8080/tcp
      firewall-cmd --reload
    else
      log "8080/tcp already open"
    fi
  fi
  mark_done firewall
}

step_base() {
  if is_done base; then log "base already installed"; return; fi
  log "installing base packages"
  yum install -y git curl dos2unix >/dev/null
  if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
    yum install -y nodejs >/dev/null
  fi
  id deploy >/dev/null 2>&1 || useradd -m -s /bin/bash deploy
  mkdir -p /home/deploy/.ssh
  chmod 700 /home/deploy/.ssh
  touch /home/deploy/.ssh/authorized_keys
  chmod 600 /home/deploy/.ssh/authorized_keys
  chown -R deploy:deploy /home/deploy/.ssh
  mkdir -p /opt/app/releases /opt/app/shared
  chown -R deploy:deploy /opt/app
  mark_done base
}

step_app_unit() {
  local unit=/etc/systemd/system/app.service
  local desired
  desired=$(cat <<'UNIT'
[Unit]
Description=App Service
After=network.target

[Service]
Type=simple
User=deploy
WorkingDirectory=/opt/app/current
EnvironmentFile=/opt/app/shared/.env
ExecStart=/usr/bin/node dist/server.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
)
  if [[ ! -f "$unit" ]] || ! diff -q <(echo "$desired") "$unit" >/dev/null; then
    log "writing app.service"
    echo "$desired" > "$unit"
    systemctl daemon-reload
    systemctl enable app.service
  else
    log "app.service up to date"
  fi
  mark_done app_unit
}

step_env_file() {
  local f=/opt/app/shared/.env
  if [[ ! -f "$f" ]]; then
    log "creating $f"
    local node_env="development"
    [[ "$ENV_NAME" == "prod" ]] && node_env="production"
    cat >"$f" <<ENV
NODE_ENV=${node_env}
PORT=8080
APP_VERSION=bootstrap
ENV
    chown deploy:deploy "$f"
    chmod 600 "$f"
  else
    log ".env exists, keep as is"
  fi
  mark_done env_file
}

step_sudoers() {
  local f=/etc/sudoers.d/deploy-app
  if [[ ! -f "$f" ]]; then
    log "writing sudoers for deploy"
    cat >"$f" <<'SUDO'
deploy ALL=(ALL) NOPASSWD: /bin/systemctl restart app.service, /bin/systemctl status app.service, /bin/ln -sfn *, /bin/sed -i *
SUDO
    chmod 440 "$f"
    visudo -cf "$f" >/dev/null
  else
    log "sudoers already present"
  fi
  mark_done sudoers
}

main() {
  log "== startup.sh begin env=$ENV_NAME host=$(hostname) =="
  step_hostname
  step_firewall
  step_base
  step_app_unit
  step_env_file
  step_sudoers
  log "== startup.sh done =="
}

main "$@"
```



------

## 5. 模块 `modules/ec2-app`

### 5.1 `modules/ec2-app/versions.tf`

hcl

```
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```



### 5.2 `modules/ec2-app/variables.tf`

> **变化**：删除 `prevent_destroy`（`main.tf` 已不再使用）；其余不变。

hcl

```
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

variable "extra_tags" {
  description = "Additional tags merged into all resources"
  type        = map(string)
  default     = {}
}
```



### 5.3 `modules/ec2-app/main.tf`（**本次更新，逐字采用你提供的内容**）

hcl

```
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
    cidr_blocks = [var.internal_app_cidr]
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
```



### 5.4 `modules/ec2-app/outputs.tf`

hcl

```
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
```



------

## 6. `envs/dev`

### 6.1 `envs/dev/versions.tf`

hcl

```
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```



### 6.2 `envs/dev/providers.tf`

hcl

```
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "myapp"
      env       = "dev"
      ManagedBy = "terraform"
    }
  }
}
```



### 6.3 `envs/dev/backend.tf`

hcl

```
terraform {
  backend "s3" {
    bucket         = "myapp-tfstate-822952232701"
    key            = "terraform/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "myapp-tf-lock-822952232701"
    encrypt        = true
  }
}
```



### 6.4 `envs/dev/variables.tf`（**去掉 `prevent_destroy`**）

hcl

```
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
```



### 6.5 `envs/dev/terraform.tfvars`（**去掉 `prevent_destroy`**）

hcl

```
region        = "us-east-1"
instance_type = "t2.micro"

# DEV：可临时用本机出口 IP；多人协作时列多个
admin_cidrs = [
  "203.0.113.10/32",
]
```



### 6.6 `envs/dev/main.tf`（**去掉 `prevent_destroy` 传参**）

hcl

```
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

  extra_tags = {
    CostCenter = "dev"
  }
}
```



### 6.7 `envs/dev/outputs.tf`

hcl

```
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
```



------

## 7. `envs/prod`

### 7.1 `envs/prod/versions.tf`

hcl

```
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```



### 7.2 `envs/prod/providers.tf`

hcl

```
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "myapp"
      env       = "prod"
      ManagedBy = "terraform"
    }
  }
}
```



### 7.3 `envs/prod/backend.tf`

hcl

```
terraform {
  backend "s3" {
    bucket         = "myapp-tfstate-822952232701"
    key            = "terraform/prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "myapp-tf-lock-822952232701"
    encrypt        = true
  }
}
```



### 7.4 `envs/prod/variables.tf`（**去掉 `prevent_destroy`**）

hcl

```
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
```



### 7.5 `envs/prod/terraform.tfvars`（**去掉 `prevent_destroy`**）

hcl

```
region        = "us-east-1"
instance_type = "t2.micro"

# PROD：固定跳板机 CIDR，禁止自动探测
admin_cidrs = [
  "203.0.113.10/32",
]
```



### 7.6 `envs/prod/main.tf`（**去掉 `prevent_destroy` 传参**）

hcl

```
locals {
  project          = "myapp"
  env              = "prod"
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

  extra_tags = {
    CostCenter = "prod"
  }
}
```



### 7.7 `envs/prod/outputs.tf`

hcl

```
output "instance_id" {
  description = "PROD EC2 instance ID"
  value       = module.ec2_app.instance_id
}

output "public_ip" {
  description = "PROD EC2 public IP"
  value       = module.ec2_app.public_ip
}

output "private_ip" {
  description = "PROD EC2 private IP"
  value       = module.ec2_app.private_ip
}

output "sg_id" {
  description = "PROD Security Group ID"
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
  value       = "prod"
}
```



------

## 8. Terraform CI 用户（一次性）

bash

```
cd infra_aws_ec2
TF_CI_USER=myapp-ci-terraform
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
TFSTATE_BUCKET=myapp-tfstate-${ACCOUNT}
TFLOCK_TABLE=myapp-tf-lock-${ACCOUNT}
BOOTSTRAP_BUCKET=myapp-bootstrap-${ACCOUNT}

aws iam get-user --user-name $TF_CI_USER >/dev/null 2>&1 || \
  aws iam create-user --user-name $TF_CI_USER

cat >/tmp/ci-terraform-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Describe",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances","ec2:DescribeImages","ec2:DescribeVpcs",
        "ec2:DescribeSubnets","ec2:DescribeSecurityGroups","ec2:DescribeKeyPairs",
        "ec2:DescribeTags","ec2:DescribeInstanceTypes",
        "ec2:DescribeInstanceAttribute","ec2:DescribeInstanceStatus"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2Provision",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances","ec2:CreateTags",
        "ec2:CreateSecurityGroup","ec2:AuthorizeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress","ec2:RevokeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupEgress","ec2:DeleteSecurityGroup",
        "ec2:CreateKeyPair","ec2:DeleteKeyPair",
        "ec2:ModifyInstanceAttribute"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMForInstanceProfile",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole","iam:CreateRole","iam:DeleteRole",
        "iam:PutRolePolicy","iam:DeleteRolePolicy","iam:GetRolePolicy",
        "iam:AttachRolePolicy","iam:DetachRolePolicy",
        "iam:GetInstanceProfile","iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile","iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile"
      ],
      "Resource": [
        "arn:aws:iam::${ACCOUNT}:role/myapp-*-ec2-role",
        "arn:aws:iam::${ACCOUNT}:instance-profile/myapp-*-ec2-profile"
      ]
    },
    {
      "Sid": "PassRoleOnly",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::${ACCOUNT}:role/myapp-*-ec2-role",
      "Condition": {
        "StringEquals": { "iam:PassedToService": "ec2.amazonaws.com" }
      }
    },
    {
      "Sid": "S3ReadStartup",
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::${BOOTSTRAP_BUCKET}/scripts/startup.sh"
    },
    {
      "Sid": "TFState",
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:PutObject","s3:ListBucket","s3:GetBucketVersioning"],
      "Resource": [
        "arn:aws:s3:::${TFSTATE_BUCKET}",
        "arn:aws:s3:::${TFSTATE_BUCKET}/*"
      ]
    },
    {
      "Sid": "TFLock",
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem","dynamodb:PutItem","dynamodb:DeleteItem","dynamodb:DescribeTable"],
      "Resource": "arn:aws:dynamodb:us-east-1:${ACCOUNT}:table/${TFLOCK_TABLE}"
    }
  ]
}
EOF

aws iam put-user-policy --user-name $TF_CI_USER \
  --policy-name TerraformEC2Provision \
  --policy-document file:///tmp/ci-terraform-policy.json

aws iam list-access-keys --user-name $TF_CI_USER --query 'AccessKeyMetadata[0]' --output text | grep -q . \
  && echo "已存在 AccessKey" \
  || aws iam create-access-key --user-name $TF_CI_USER
```



GitHub Secrets：`TF_AWS_ACCESS_KEY_ID`、`TF_AWS_SECRET_ACCESS_KEY`。

------

## 9. `.github/workflows/terraform-dev.yml`

yaml

```
name: Terraform DEV (provision)

on:
  workflow_dispatch:
    inputs:
      action:
        description: "Terraform action"
        type: choice
        options: [plan, apply, destroy]
        default: plan
      admin_cidrs:
        description: "SSH allowed CIDRs (comma separated). Empty = use terraform.tfvars."
        required: false
        default: ""
      confirm_destroy:
        description: "Type 'destroy-dev' to confirm destroy"
        required: false
        default: ""

concurrency:
  group: terraform-dev
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  terraform:
    runs-on: ubuntu-latest
    environment: dev
    env:
      AWS_ACCESS_KEY_ID: ${{ secrets.TF_AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.TF_AWS_SECRET_ACCESS_KEY }}
      AWS_REGION: us-east-1
      TF_IN_AUTOMATION: "true"
      TF_INPUT: "false"
    defaults:
      run:
        working-directory: infra_aws_ec2/envs/dev
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.7.5"

      - name: Guard destroy
        if: ${{ inputs.action == 'destroy' }}
        run: |
          if [ "${{ inputs.confirm_destroy }}" != "destroy-dev" ]; then
            echo "::error::To destroy DEV, set confirm_destroy=destroy-dev"
            exit 1
          fi

      - name: Render tfvars override (admin_cidrs)
        if: ${{ inputs.admin_cidrs != '' }}
        run: |
          cat > override.auto.tfvars <<EOF
          admin_cidrs = [$(echo "${{ inputs.admin_cidrs }}" | awk -F',' '{for(i=1;i<=NF;i++){printf "\"%s\"%s", $i, (i<NF?",":"")}}')]
          EOF
          cat override.auto.tfvars

      - name: Terraform fmt
        run: terraform fmt -check -recursive || true

      - name: Terraform init
        run: terraform init -input=false

      - name: Terraform validate
        run: terraform validate

      - name: Terraform plan
        if: ${{ inputs.action != 'destroy' }}
        run: terraform plan -input=false -out=tfplan

      - name: Upload plan artifact
        if: ${{ inputs.action != 'destroy' }}
        uses: actions/upload-artifact@v4
        with:
          name: tfplan-dev
          path: infra_aws_ec2/envs/dev/tfplan
          retention-days: 7

      - name: Terraform apply
        if: ${{ inputs.action == 'apply' }}
        run: terraform apply -input=false -auto-approve tfplan

      - name: Terraform destroy
        if: ${{ inputs.action == 'destroy' }}
        run: terraform destroy -input=false -auto-approve

      - name: Output summary
        if: ${{ inputs.action != 'destroy' }}
        run: |
          {
            echo "### Terraform DEV (${{ inputs.action }})"
            echo '```'
            terraform output
            echo '```'
          } >> "$GITHUB_STEP_SUMMARY"
```



> 若仓库根就是 `infra_aws_ec2`（`.github` 在其下），把 `working-directory` 改成 `envs/dev`；否则保持 `infra_aws_ec2/envs/dev`。

------

## 10. `.github/workflows/terraform-prod.yml`

> **PROD 防误删**：模块已去掉 `prevent_destroy`，本 workflow **不提供 destroy 选项**，从流程上禁止误删；真要销毁走人工 `terraform destroy`。

yaml

```
name: Terraform PROD (provision)

on:
  workflow_dispatch:
    inputs:
      action:
        description: "Terraform action (apply requires approval)"
        type: choice
        options: [plan, apply]
        default: plan
      admin_cidrs:
        description: "SSH allowed CIDRs (comma separated). Empty = use terraform.tfvars."
        required: false
        default: ""

concurrency:
  group: terraform-prod
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  plan:
    runs-on: ubuntu-latest
    environment: prod
    outputs:
      has_changes: ${{ steps.plan.outputs.has_changes }}
    env:
      AWS_ACCESS_KEY_ID: ${{ secrets.TF_AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.TF_AWS_SECRET_ACCESS_KEY }}
      AWS_REGION: us-east-1
      TF_IN_AUTOMATION: "true"
      TF_INPUT: "false"
    defaults:
      run:
        working-directory: infra_aws_ec2/envs/prod
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: "1.7.5" }

      - name: Render tfvars override (admin_cidrs)
        if: ${{ inputs.admin_cidrs != '' }}
        run: |
          cat > override.auto.tfvars <<EOF
          admin_cidrs = [$(echo "${{ inputs.admin_cidrs }}" | awk -F',' '{for(i=1;i<=NF;i++){printf "\"%s\"%s", $i, (i<NF?",":"")}}')]
          EOF
          cat override.auto.tfvars

      - run: terraform init -input=false

      - id: plan
        run: |
          set +e
          terraform plan -input=false -out=tfplan -detailed-exitcode
          code=$?
          set -e
          if [ "$code" -eq 1 ]; then exit 1; fi
          echo "has_changes=$code" >> "$GITHUB_OUTPUT"

      - uses: actions/upload-artifact@v4
        with:
          name: tfplan-prod
          path: infra_aws_ec2/envs/prod/tfplan
          retention-days: 7

  apply:
    needs: plan
    if: ${{ inputs.action == 'apply' && needs.plan.outputs.has_changes == '2' }}
    runs-on: ubuntu-latest
    environment: prod
    env:
      AWS_ACCESS_KEY_ID: ${{ secrets.TF_AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.TF_AWS_SECRET_ACCESS_KEY }}
      AWS_REGION: us-east-1
      TF_IN_AUTOMATION: "true"
      TF_INPUT: "false"
    defaults:
      run:
        working-directory: infra_aws_ec2/envs/prod
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: "1.7.5" }

      - uses: actions/download-artifact@v4
        with:
          name: tfplan-prod
          path: infra_aws_ec2/envs/prod

      - run: terraform init -input=false
      - run: terraform apply -input=false -auto-approve tfplan

      - name: Output summary
        run: |
          {
            echo "### Terraform PROD applied"
            echo '```'
            terraform output
            echo '```'
          } >> "$GITHUB_STEP_SUMMARY"
```



------

## 11. 手动跑一遍 DEV

bash

```
cd infra_aws_ec2/envs/dev
ADMIN_IP=$(curl -fsS https://checkip.amazonaws.com)
# 编辑 terraform.tfvars：admin_cidrs = ["${ADMIN_IP}/32"]

terraform init
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform apply tfplan

DEV_IP=$(terraform output -raw public_ip)

for i in $(seq 1 18); do
  nc -zvw3 $DEV_IP 22 >/dev/null 2>&1 && { echo "SSH up"; break; }
  echo "waiting ssh... ($i)"; sleep 10
done

ssh -i ~/.ssh/app-key.pem ec2-user@$DEV_IP \
  "hostname && sudo tail -40 /var/log/app-bootstrap.log && systemctl is-enabled startup.service"

rm -f tfplan
```



写发布公钥：

bash

```
cd ../../
[[ -f ./gha_key ]] || ssh-keygen -t ed25519 -C "gha-deploy" -f ./gha_key -N ""
PUB=$(cat ./gha_key.pub)

ssh -i ~/.ssh/app-key.pem ec2-user@$DEV_IP \
  "sudo -u deploy bash -c 'grep -qF \"$PUB\" /home/deploy/.ssh/authorized_keys || echo \"$PUB\" >> /home/deploy/.ssh/authorized_keys'"
ssh -i ./gha_key -o BatchMode=yes deploy@$DEV_IP "echo deploy-ok && hostname"
```



------

## 12. `.github/workflows/deploy-dev.yml`

yaml

```
name: Deploy to DEV

on:
  push:
    branches: [dev]
  workflow_dispatch:

concurrency:
  group: deploy-dev
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: dev

    env:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_REGION: ${{ secrets.AWS_REGION }}
      APP_NAME: myapp
      APP_PORT: "8080"

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Build artifact
        run: |
          set -euo pipefail
          mkdir -p dist
          tar --exclude='.git' --exclude='dist' -czf dist/app.tar.gz .
          ls -lh dist/app.tar.gz

      - name: Upload artifact (workflow artifact)
        uses: actions/upload-artifact@v4
        with:
          name: app-dev-${{ github.sha }}
          path: dist/app.tar.gz
          retention-days: 7

      - name: Resolve DEV IP by tag
        id: host
        run: |
          set -euo pipefail
          IP=$(aws ec2 describe-instances \
            --filters "Name=tag:env,Values=dev" "Name=instance-state-name,Values=running" \
            --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
          if [ -z "$IP" ] || [ "$IP" == "None" ]; then
            echo "::error::No running DEV instance with tag env=dev. Run 'Terraform DEV (provision)' workflow first."
            exit 1
          fi
          echo "ip=$IP" >> "$GITHUB_OUTPUT"

      - name: Setup SSH
        run: |
          set -euo pipefail
          mkdir -p ~/.ssh
          echo "${{ secrets.DEV_SSH_PRIVATE_KEY }}" > ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519
          ssh-keyscan -H "${{ steps.host.outputs.ip }}" >> ~/.ssh/known_hosts

      - name: Version
        id: ver
        run: |
          VERSION="dev-${GITHUB_SHA::7}-$(date -u +%Y%m%d%H%M%S)"
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"
          echo "VERSION=$VERSION"

      - name: Upload artifact to server
        run: |
          set -euo pipefail
          scp -i ~/.ssh/id_ed25519 dist/app.tar.gz \
            deploy@${{ steps.host.outputs.ip }}:/tmp/app-${{ steps.ver.outputs.version }}.tar.gz

      - name: Release on server
        run: |
          set -euo pipefail
          ssh -i ~/.ssh/id_ed25519 deploy@${{ steps.host.outputs.ip }} \
            "VERSION='${{ steps.ver.outputs.version }}' PORT='${{ env.APP_PORT }}' bash -s" <<'EOF'
          set -euo pipefail
          echo "== Deploying $VERSION on $(hostname) =="

          REL_DIR="/opt/app/releases/$VERSION"
          mkdir -p "$REL_DIR"
          tar -xzf "/tmp/app-$VERSION.tar.gz" -C "$REL_DIR"
          rm -f "/tmp/app-$VERSION.tar.gz"

          sudo ln -sfn "$REL_DIR" /opt/app/current
          sudo sed -i "s/^APP_VERSION=.*/APP_VERSION=$VERSION/" /opt/app/shared/.env
          sudo systemctl restart app.service
          sleep 3

          for i in $(seq 1 10); do
            if curl -fsS "http://localhost:$PORT/health" >/dev/null 2>&1; then
              echo "health OK"; break
            fi
            echo "waiting health... ($i)"; sleep 3
            if [ "$i" -eq 10 ]; then
              echo "health check failed, rolling back"
              PREV=$(ls -1 /opt/app/releases | grep -v "^$VERSION$" | sort | tail -n1 || true)
              if [ -n "$PREV" ]; then
                sudo ln -sfn "/opt/app/releases/$PREV" /opt/app/current
                sudo systemctl restart app.service
                echo "rolled back to $PREV"
              fi
              exit 1
            fi
          done

          echo "== Deploy done: $VERSION =="
          EOF

      - name: Output summary
        if: always()
        run: |
          {
            echo "### Deploy to DEV"
            echo "- Version: \`${{ steps.ver.outputs.version }}\`"
            echo "- Host: \`${{ steps.host.outputs.ip }}\`"
            echo "- Commit: \`${{ github.sha }}\`"
          } >> "$GITHUB_STEP_SUMMARY"
```



------

## 13. `.github/workflows/deploy-prod.yml`

yaml

```
name: Deploy to PROD

on:
  push:
    tags:
      - 'v*.*.*'
  workflow_dispatch:
    inputs:
      tag:
        description: "Existing tag to deploy (e.g. v1.0.0)"
        required: true

concurrency:
  group: deploy-prod
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: prod

    env:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_REGION: ${{ secrets.AWS_REGION }}
      APP_NAME: myapp
      APP_PORT: "8080"

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Resolve version
        id: ver
        run: |
          set -euo pipefail
          if [ "${{ github.event_name }}" = "push" ]; then
            VERSION="${GITHUB_REF_NAME}"
          else
            VERSION="${{ inputs.tag }}"
          fi
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"
          echo "VERSION=$VERSION"

      - name: Verify tag is on main
        run: |
          set -euo pipefail
          VERSION="${{ steps.ver.outputs.version }}"
          git fetch origin main --tags
          if ! git rev-parse "refs/tags/$VERSION" >/dev/null 2>&1; then
            echo "::error::Tag $VERSION not found"
            exit 1
          fi
          TAG_SHA=$(git rev-list -n 1 "refs/tags/$VERSION")
          if ! git merge-base --is-ancestor "$TAG_SHA" origin/main; then
            echo "::error::Tag $VERSION is not on main branch"
            exit 1
          fi
          echo "tag $VERSION is on main ($TAG_SHA)"

      - name: Checkout tag
        run: |
          set -euo pipefail
          git checkout "${{ steps.ver.outputs.version }}"

      - name: Build artifact
        run: |
          set -euo pipefail
          mkdir -p dist
          tar --exclude='.git' --exclude='dist' -czf dist/app.tar.gz .
          ls -lh dist/app.tar.gz

      - name: Upload artifact (workflow artifact)
        uses: actions/upload-artifact@v4
        with:
          name: app-prod-${{ steps.ver.outputs.version }}
          path: dist/app.tar.gz
          retention-days: 30

      - name: Resolve PROD IP by tag
        id: host
        run: |
          set -euo pipefail
          IP=$(aws ec2 describe-instances \
            --filters "Name=tag:env,Values=prod" "Name=instance-state-name,Values=running" \
            --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
          if [ -z "$IP" ] || [ "$IP" == "None" ]; then
            echo "::error::No running PROD instance with tag env=prod. Run 'Terraform PROD (provision)' workflow first."
            exit 1
          fi
          echo "ip=$IP" >> "$GITHUB_OUTPUT"

      - name: Setup SSH
        run: |
          set -euo pipefail
          mkdir -p ~/.ssh
          echo "${{ secrets.PROD_SSH_PRIVATE_KEY }}" > ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519
          ssh-keyscan -H "${{ steps.host.outputs.ip }}" >> ~/.ssh/known_hosts

      - name: Upload artifact to server
        run: |
          set -euo pipefail
          scp -i ~/.ssh/id_ed25519 dist/app.tar.gz \
            deploy@${{ steps.host.outputs.ip }}:/tmp/app-${{ steps.ver.outputs.version }}.tar.gz

      - name: Release on server
        run: |
          set -euo pipefail
          ssh -i ~/.ssh/id_ed25519 deploy@${{ steps.host.outputs.ip }} \
            "VERSION='${{ steps.ver.outputs.version }}' PORT='${{ env.APP_PORT }}' bash -s" <<'EOF'
          set -euo pipefail
          echo "== Deploying $VERSION on $(hostname) =="

          REL_DIR="/opt/app/releases/$VERSION"
          mkdir -p "$REL_DIR"
          tar -xzf "/tmp/app-$VERSION.tar.gz" -C "$REL_DIR"
          rm -f "/tmp/app-$VERSION.tar.gz"

          PREV=$(readlink -f /opt/app/current || true)
          echo "previous: ${PREV:-none}"

          sudo ln -sfn "$REL_DIR" /opt/app/current
          sudo sed -i "s/^APP_VERSION=.*/APP_VERSION=$VERSION/" /opt/app/shared/.env
          sudo systemctl restart app.service
          sleep 5

          for i in $(seq 1 12); do
            if curl -fsS "http://localhost:$PORT/health" >/dev/null 2>&1; then
              echo "health OK"; break
            fi
            echo "waiting health... ($i)"; sleep 5
            if [ "$i" -eq 12 ]; then
              echo "health check failed, rolling back"
              if [ -n "${PREV:-}" ] && [ -d "$PREV" ]; then
                sudo ln -sfn "$PREV" /opt/app/current
                sudo systemctl restart app.service
                echo "rolled back to $PREV"
              fi
              exit 1
            fi
          done

          echo "== Deploy done: $VERSION =="
          EOF

      - name: Output summary
        if: always()
        run: |
          {
            echo "### Deploy to PROD"
            echo "- Version: \`${{ steps.ver.outputs.version }}\`"
            echo "- Host: \`${{ steps.host.outputs.ip }}\`"
            echo "- Tag: \`${{ steps.ver.outputs.version }}\`"
          } >> "$GITHUB_STEP_SUMMARY"
```



------

## 14. 发版流程（dev → main → tag）

bash

```
# 首次
git init
git checkout -b dev
git add .
#git add .gitignore modules envs scripts .github
git commit -m "feat: terraform ec2 module + deploy workflows + .gitignore"
git remote add origin https://github.com/HaoChen688/infra_aws_ec2.git
git push -u origin dev

# 迭代
git checkout dev && git pull
# ...改...
git add . && git commit -m "feat: xxx" && git push

# 发版（严格顺序）
git checkout main
git pull origin main
git merge --no-ff dev -m "release: v1.0.0"
# 先 push main，确认成功无冲突
git push origin main
# 再拉一次对齐
git pull origin main
# 对齐后打 tag、推 tag
git tag -a v1.0.0 -m "version v1.0.0 正式发布"
git push origin v1.0.0

# 回同步
git checkout dev
git merge --no-ff main -m "chore: sync main back to dev"
git push origin dev
```



> 先 push main 再 tag，确保 tag 指向已推送 commit；`deploy-prod.yml` 的 `Verify tag is on main` 才能通过。

------

## 15. 写入发布公钥（角色澄清 + 校验）

| 文件                     | 类型           | 归属                   | 用途                  |
| :----------------------- | :------------- | :--------------------- | :-------------------- |
| `app-key.pem`            | 私钥           | 管理员本地（忽略）     | 登录 `ec2-user`       |
| `app-key`（AWS KeyPair） | 公钥（AWS 侧） | EC2 注入 `ec2-user`    | 与 `app-key.pem` 配对 |
| `gha_key`                | 私钥           | GitHub Secrets（忽略） | 发布登录 `deploy`     |
| `gha_key.pub`            | 公钥           | 写入 `deploy`（忽略）  | 与 `gha_key` 配对     |

bash

```
cd infra_aws_ec2
[[ -f ./gha_key ]] || ssh-keygen -t ed25519 -C "gha-deploy" -f ./gha_key -N ""
PUB=$(cat ./gha_key.pub)

# DEV
ssh -i ~/.ssh/app-key.pem ec2-user@$DEV_IP \
  "sudo -u deploy bash -c 'grep -qF \"$PUB\" /home/deploy/.ssh/authorized_keys || echo \"$PUB\" >> /home/deploy/.ssh/authorized_keys'"
ssh -i ./gha_key -o BatchMode=yes deploy@$DEV_IP "echo deploy-ok && hostname"

# PROD
ssh -i ~/.ssh/app-key.pem ec2-user@$PROD_IP \
  "sudo -u deploy bash -c 'grep -qF \"$PUB\" /home/deploy/.ssh/authorized_keys || echo \"$PUB\" >> /home/deploy/.ssh/authorized_keys'"
ssh -i ./gha_key -o BatchMode=yes deploy@$PROD_IP "echo deploy-ok && hostname"
```



GitHub Secrets：

| Secret                     | 值                              | 用途               |
| :------------------------- | :------------------------------ | :----------------- |
| `DEV_SSH_PRIVATE_KEY`      | `cat ./gha_key`                 | `deploy-dev.yml`   |
| `PROD_SSH_PRIVATE_KEY`     | `cat ./gha_key`（或 PROD 专用） | `deploy-prod.yml`  |
| `AWS_ACCESS_KEY_ID`        | `myapp-ci-deployer` KeyId       | 发布 workflow      |
| `AWS_SECRET_ACCESS_KEY`    | 同上                            | 发布 workflow      |
| `AWS_REGION`               | `us-east-1`                     | 发布 workflow      |
| `TF_AWS_ACCESS_KEY_ID`     | `myapp-ci-terraform` KeyId      | Terraform workflow |
| `TF_AWS_SECRET_ACCESS_KEY` | 同上                            | Terraform workflow |

------

## 16. 回滚 / 安全 / 排查

**回滚**

- 自动：`deploy-*.yml` 健康检查失败切 `PREV`。
- 手动：`sudo ln -sfn /opt/app/releases/<prev> /opt/app/current && sudo systemctl restart app.service`。
- GitOps：旧版本合入 `main` → 打 patch tag（`v1.0.1`）→ 重走 PROD。

**安全**

- `.gitignore` 忽略 `.terraform/`、`*.tfstate*`、`tfplan`、`gha_key*`、`*.pem`、`.env`。
- `.terraform.lock.hcl` 入库。
- 私钥泄漏即轮换。
- **PROD 防误删**：模块不再用 `prevent_destroy`，改由 `terraform-prod.yml` **不提供 destroy 选项** 从流程上禁止；真要销毁走人工。
- `iam:PassRole` 收紧到 `myapp-*-ec2-role`。
- 推荐 SSM 替代 SSH。

**排查**

| 现象                            | 排查                                                         |
| :------------------------------ | :----------------------------------------------------------- |
| SG 22 端口 CIDR 被整体替换      | 预期：内联 `ingress.cidr_blocks = var.admin_cidrs` 是声明式覆盖，改列表即收敛 |
| `prevent_destroy` 变量报未使用  | 已从模块与 envs 删除；PROD 防删靠 workflow 无 destroy 选项   |
| `git status` 出现 `.terraform/` | `git check-ignore -v .terraform/`；确认 `.gitignore` 在 repo-root |
| 已 push 私钥                    | 立即轮换 + `git filter-repo`                                 |
| `deploy-dev.yml` 没触发         | push 到 `dev`（不是 `develop`）                              |
| `deploy-prod.yml` 被跳过        | tag 不在 `main` 或指向未推送 commit；按 14 节顺序            |
| `Permission denied (publickey)` | `DEV_SSH_PRIVATE_KEY` 与 `deploy` 的 `gha_key.pub` 不配对    |
| 健康检查失败                    | `journalctl -u app -n 100`；workflow 已自动回滚              |
| `working-directory` 不存在      | 确认 `infra_aws_ec2/envs/dev|prod`                           |

------

## 17. 附录：实施顺序

1. `cd infra_aws_ec2`
2. 创建 `.gitignore`，跑上传前自检
3. 前置：Key Pair、S3 bootstrap、TF state + 锁表、`startup.sh` 上传
4. 写模块（**用第 5.3 节新 `main.tf`**，模块 `variables.tf` 已删 `prevent_destroy`）+ `envs/dev` + `envs/prod`（已删 `prevent_destroy`）
5. `terraform init` 生成 `.terraform.lock.hcl`，入库
6. 建 `myapp-ci-terraform`，填 `TF_AWS_*`
7. 建 `myapp-ci-deployer`，填 `AWS_*`
8. 配 environments：`dev`、`prod`（Required reviewers ×2，branches=main）
9. 本地手动跑 DEV（第 11 节），`rm -f tfplan`
10. 切 CI：DEV 变更走 `terraform-dev.yml`
11. Git 首次：`git checkout -b dev` → `add .gitignore modules envs scripts .github` → `commit` → `push`
12. 迭代 push `dev`
13. 发版（第 14 节严格顺序）
14. PROD 建机 + 写 `deploy` 公钥
15. 回同步 `dev`
16. 回滚 / 监控 / `admin_cidrs` 治理

> **本次核心变化**：`modules/ec2-app/main.tf` 采用你提供的新内容（内联 SG `ingress/egress`、`lifecycle` 仅 `ignore_changes=[ami]`）；随之删除 `prevent_destroy` 变量与传参，PROD 防误删改为"`terraform-prod.yml` 无 destroy 选项 + 人工 destroy"。`.gitignore` 必配、`.terraform.lock.hcl` 必入；建机走 Terraform（本地先验证 DEV → `terraform-dev.yml` / `terraform-prod.yml`，PROD 两道审批）；发布走 `deploy-dev.yml`（push `dev`）/ `deploy-prod.yml`（tag `v*.*.*`，校验 tag 在 `main`，审批，失败回滚）；发版顺序 `checkout main → pull → merge --no-ff dev → push main → pull 对齐 → tag → push tag`。



#下面是手动跑terraform apply tfplan 结果

Apply complete! Resources: 1 added, 2 changed, 0 destroyed.

Outputs:

ami_used = "ami-0ce86737d705482ea"
env_tag = "dev"
iam_instance_profile_name = "myapp-dev-ec2-profile"
iam_role_name = "myapp-dev-ec2-role"
instance_id = "i-08296e60febf6b314"
private_ip = "172.31.12.120"
public_ip = "184.195.167.114"
sg_id = "sg-02291f21c2f78b5d3"



`workflow_dispatch` **只能手动触发**，GitHub 不支持被 `git push` 触发。所以：

| 你跑的命令                                          | 触发什么                                      | 是否建机 |
| :-------------------------------------------------- | :-------------------------------------------- | :------- |
| `git push -u origin dev`                            | `deploy-dev.yml`（`on.push.branches: [dev]`） | ❌ 不建机 |
| `git push`（迭代）                                  | `deploy-dev.yml`                              | ❌ 不建机 |
| `git push origin main`                              | 无（`deploy-prod.yml` 只认 tag）              | ❌ 不建机 |
| `git push origin v1.0.0`                            | `deploy-prod.yml`（`on.push.tags`）           | ❌ 不建机 |
| **Actions 页面手动点 `Terraform DEV (provision)`**  | `terraform-dev.yml`                           | ✅ 建机   |
| **Actions 页面手动点 `Terraform PROD (provision)`** | `terraform-prod.yml`                          | ✅ 建机   |

**建机只有两个入口**：手动点 `Terraform DEV (provision)` 或 `Terraform PROD (provision)`；或本地 `terraform apply`。