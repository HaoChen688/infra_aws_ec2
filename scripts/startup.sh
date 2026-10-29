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