#!/usr/bin/env bash
# Runs ON the server as the deploy user (sudo available), from the synced
# infra/ directory. Called by infra/deploy.sh; safe to re-run.
#
#   PHX_HOST=hrda.artcomplect.com IMAGE_TAG=abc1234 bash server/install.sh
#
#   1. first install only: creates infra/.env from .env.example with fresh
#      random secrets (existing .env is never overwritten);
#   2. Nginx site + Let's Encrypt certificate for PHX_HOST;
#   3. starts the stack with the given image tag and waits until the app
#      answers.
set -euo pipefail
cd "$(dirname "$0")/.."

PHX_HOST="${PHX_HOST:?set PHX_HOST}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
CERT_EMAIL="${CERT_EMAIL:-}"
log() { printf '\n==> %s\n' "$*"; }

setv() { # setv NAME VALUE — replace (or append) NAME=VALUE in .env
  local k="$1" v="$2"
  if grep -q "^$k=" .env; then
    k="$k" v="$v" python3 - <<'PY'
import os, re
k, v = os.environ["k"], os.environ["v"]
s = open(".env").read()
s = re.sub(rf"(?m)^{re.escape(k)}=.*$", lambda _: f"{k}={v}", s, count=1)
open(".env", "w").write(s)
PY
  else
    printf '%s=%s\n' "$k" "$v" >> .env
  fi
}

if [ ! -f .env ]; then
  log "Creating .env with fresh secrets"
  ( umask 077; cp .env.example .env )
  setv PHX_HOST "$PHX_HOST"
  setv GOOGLE_REDIRECT_URI "https://$PHX_HOST/auth/"
  setv POSTGRES_PASSWORD "$(openssl rand -hex 32)"
  setv SECRET_KEY_BASE "$(openssl rand -base64 48 | tr -d '\n')"
  setv SHEETS_SHARED_SECRET "$(openssl rand -base64 32 | tr -d '\n')"
  setv TOKEN_SIGNING_SECRET "$(openssl rand -base64 48 | tr -d '\n')"
  setv CLOAK_KEY "$(openssl rand -base64 32 | tr -d '\n')"
  setv RUSTFS_ACCESS_KEY "$(openssl rand -hex 16)"
  setv RUSTFS_SECRET_KEY "$(openssl rand -hex 32)"
  setv RABBITMQ_PASSWORD "$(openssl rand -hex 32)"
  # Real values come from Google Cloud Console (infra/README.md §3);
  # until then the app runs but Google sign-in does not work.
  setv GOOGLE_CLIENT_ID "set-me"
  setv GOOGLE_CLIENT_SECRET "set-me"
  setv ADMIN_FULL_DATA_ACCESS "false"
  echo "Created infra/.env. Back up CLOAK_KEY off this server."
fi
setv IMAGE_TAG "$IMAGE_TAG"
setv IMAGE_PREFIX "${IMAGE_PREFIX:-medimildoc}"

log "Nginx site for $PHX_HOST"
site="/etc/nginx/sites-available/$PHX_HOST"
if [ ! -f "/etc/letsencrypt/live/$PHX_HOST/fullchain.pem" ]; then
  if [ -n "$CERT_EMAIL" ]; then email=(--email "$CERT_EMAIL"); else email=(--register-unsafely-without-email); fi
  # The nginx authenticator answers the challenge through whatever site
  # serves port 80 now (Debian's default one on a fresh box).
  sudo certbot certonly --nginx --non-interactive --agree-tos "${email[@]}" \
    --cert-name "$PHX_HOST" -d "$PHX_HOST"
fi
sudo install -m 0644 "nginx/$PHX_HOST.conf" "$site"
sudo ln -sf "$site" "/etc/nginx/sites-enabled/$PHX_HOST"
sudo nginx -t
sudo systemctl reload nginx

log "Starting the stack (images tag $IMAGE_TAG)"
[ "${PULL:-0}" = 1 ] && docker compose pull app ihds
docker compose up -d --no-build --remove-orphans
docker image prune -f >/dev/null

log "Waiting for the app"
for _ in $(seq 1 90); do
  code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5085/ || true)"
  case "$code" in 2??|3??) echo "app answers ($code)"; break ;; esac
  sleep 2
done
docker compose ps
case "$code" in 2??|3??) ;; *) echo "app did not come up; see: docker compose logs app" >&2; exit 1 ;; esac
