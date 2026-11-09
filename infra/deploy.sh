#!/usr/bin/env bash
# Deploy the current checkout to a server prepared by infra/server/bootstrap.sh.
#
#   infra/deploy.sh hrda@hrda.artcomplect.com
#
# Builds the `app` and `ihds` images here (a small VPS does not have the
# memory to compile them), streams them to the server over SSH, syncs
# infra/ to $APP_DIR/infra and runs infra/server/install.sh there.
#
# Environment:
#   PHX_HOST    public host name            (default hrda.artcomplect.com)
#   APP_DIR     install directory on server (default /opt/medimildoc)
#   IMAGE_TAG   image tag                   (default: short git commit)
#   SSH_KEY     private key for the deploy user (optional)
#   PULL=1      do not build/ship: the server pulls IMAGE_PREFIX/*:IMAGE_TAG
#               from a registry (used by .github/workflows/deploy.yml)
#   CERT_EMAIL  Let's Encrypt account e-mail (optional)
set -euo pipefail

TARGET="${1:?usage: infra/deploy.sh user@host}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHX_HOST="${PHX_HOST:-hrda.artcomplect.com}"
APP_DIR="${APP_DIR:-/opt/medimildoc}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "$ROOT" rev-parse --short HEAD)}"
IMAGE_PREFIX="${IMAGE_PREFIX:-medimildoc}"
ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)
[ -n "${SSH_KEY:-}" ] && ssh_opts+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
remote() { ssh "${ssh_opts[@]}" "$TARGET" "$@"; }
log() { printf '\n==> %s\n' "$*"; }

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  echo "note: the working tree has uncommitted changes; they are deployed too" >&2
fi

if [ "${PULL:-0}" != 1 ]; then
  log "Building images ($IMAGE_PREFIX/*:$IMAGE_TAG)"
  # Compose checks every required (${VAR:?}) variable even to build;
  # placeholders are enough, nothing here reaches the images.
  build_env="$(mktemp)"; trap 'rm -f "$build_env"' EXIT
  grep -o '\${[A-Z_]*:?' "$ROOT/infra/docker-compose.yml" | tr -d '${:?' | sort -u \
    | sed 's/$/=build-placeholder/' > "$build_env"
  IMAGE_PREFIX="$IMAGE_PREFIX" IMAGE_TAG="$IMAGE_TAG" \
    docker compose -f "$ROOT/infra/docker-compose.yml" --env-file "$build_env" build app ihds

  log "Shipping images to $TARGET"
  docker save "$IMAGE_PREFIX/app:$IMAGE_TAG" "$IMAGE_PREFIX/ihds:$IMAGE_TAG" \
    | gzip -1 | remote 'gunzip | docker load'
fi

log "Syncing infra/ to $APP_DIR/infra"
rsync -az --delete -e "ssh ${ssh_opts[*]}" \
  --exclude '.env' --exclude 'mail-certs/' --exclude '*tunnel_key*' \
  "$ROOT/infra/" "$TARGET:$APP_DIR/infra/"

log "Installing on the server"
remote "cd $APP_DIR/infra && \
  PHX_HOST='$PHX_HOST' IMAGE_TAG='$IMAGE_TAG' IMAGE_PREFIX='$IMAGE_PREFIX' CERT_EMAIL='${CERT_EMAIL:-}' \
  ${PULL:+PULL=$PULL} bash server/install.sh"

log "Deployed: https://$PHX_HOST/"
