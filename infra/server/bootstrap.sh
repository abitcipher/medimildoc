#!/usr/bin/env bash
# One-time (and re-runnable) preparation of a fresh Debian/Ubuntu VPS for
# this app. Run as root:
#
#   DEPLOY_PUBKEY="$(cat ~/.ssh/hrda_deploy.pub)" bash bootstrap.sh
#
# What it does (each step is skipped when already done):
#   1. creates the unprivileged deploy user (default `hrda`) with sudo
#      and the given SSH public key;
#   2. adds a swap file when the box has none (the stack needs ~1.2 GB
#      of RAM; small VPSes otherwise get OOM-killed);
#   3. installs Docker Engine + the Compose plugin from Docker's own
#      apt repository and lets the deploy user run it;
#   4. installs Nginx, certbot and unattended security upgrades;
#   5. firewall: SSH, HTTP, HTTPS only (mail ports are opened by
#      infra/mail/stalwart-setup.sh if mail is enabled);
#   6. creates the app directory (default /opt/medimildoc) owned by the
#      deploy user.
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-hrda}"
APP_DIR="${APP_DIR:-/opt/medimildoc}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
DEPLOY_PUBKEY="${DEPLOY_PUBKEY:-}"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
log() { printf '\n==> %s\n' "$*"; }

log "Base packages"
apt-get update -q
apt-get install -y -q --no-install-recommends \
  ca-certificates curl gnupg sudo ufw nginx certbot python3-certbot-nginx \
  unattended-upgrades rsync git tmux

# sudo warns on every call when the host name does not resolve.
getent hosts "$(hostname)" >/dev/null || echo "127.0.1.1 $(hostname)" >> /etc/hosts

log "Deploy user: $DEPLOY_USER"
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$DEPLOY_USER"
fi
usermod -aG sudo "$DEPLOY_USER"
# Key-only account: sudo without a password (there is no password).
echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$DEPLOY_USER"
chmod 0440 "/etc/sudoers.d/90-$DEPLOY_USER"
visudo -cf "/etc/sudoers.d/90-$DEPLOY_USER" >/dev/null
if [ -n "$DEPLOY_PUBKEY" ]; then
  home="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
  install -d -m 0700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  grep -qxF "$DEPLOY_PUBKEY" "$home/.ssh/authorized_keys" || echo "$DEPLOY_PUBKEY" >> "$home/.ssh/authorized_keys"
  chown "$DEPLOY_USER:$DEPLOY_USER" "$home/.ssh/authorized_keys"
  chmod 0600 "$home/.ssh/authorized_keys"
fi

log "Swap"
if [ -z "$(swapon --show --noheadings)" ]; then
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/90-swappiness.conf
  sysctl -q -p /etc/sysctl.d/90-swappiness.conf
fi

log "Docker"
if ! command -v docker >/dev/null; then
  . /etc/os-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
# Keep container logs from filling the disk.
if [ ! -f /etc/docker/daemon.json ]; then
  cat > /etc/docker/daemon.json <<'JSON'
{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "5" } }
JSON
  systemctl restart docker
fi
systemctl enable --now docker >/dev/null
usermod -aG docker "$DEPLOY_USER"

log "Unattended security upgrades"
dpkg-reconfigure -f noninteractive unattended-upgrades

log "Firewall"
ufw allow OpenSSH >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null
ufw status | sed -n '1,20p'

log "App directory: $APP_DIR"
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$APP_DIR"
# ACME HTTP-01 challenges for certbot --webroot.
install -d /var/www/letsencrypt

log "Done"
