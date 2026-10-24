#!/usr/bin/env bash
# First-time setup of the Stalwart mail server on the VPS (infra/README.md →
# Mail). Run from the repository as the deploy user (sudo is used for the
# firewall, Nginx and certbot):
#
#   cd ~/hrda && bash infra/mail/stalwart-setup.sh
#
# Secrets never go into the repository: the administrator and sender
# credentials are written to ~/hrda-mail/ (readable by the owner only).
# Each step can be re-run; steps already done are skipped.
set -euo pipefail

HOST=mail.artcomplect.com
DOMAIN=artcomplect.com
REPO="$HOME/hrda"
MAILDIR="$HOME/hrda-mail"
CLI_VERSION=v1.0.13
API=http://127.0.0.1:8086

cd "$REPO/infra"
umask 077
mkdir -p "$MAILDIR/bin"
step() { printf '\n== %s\n' "$*"; }

step "1. Firewall: open the mail ports"
for port in 25 465 587 993; do sudo ufw allow "$port/tcp"; done

step "2. Nginx: the web admin at https://$HOST"
# Only once: certbot (step 3) adds the HTTPS block to this file afterwards.
if [ ! -f "/etc/nginx/sites-available/$HOST" ]; then
  sudo install -m 644 mail/nginx-mail.artcomplect.com.conf "/etc/nginx/sites-available/$HOST"
  sudo ln -sf "/etc/nginx/sites-available/$HOST" "/etc/nginx/sites-enabled/$HOST"
  sudo nginx -t
  sudo systemctl reload nginx
fi

step "3. TLS certificate for $HOST (certbot, renewed automatically)"
if ! sudo test -d "/etc/letsencrypt/live/$HOST"; then
  sudo certbot --nginx -d "$HOST" --non-interactive --agree-tos --redirect
fi

step "4. Certificate copies for Stalwart, and the renewal hook"
sudo install -m 755 mail/certbot-deploy-hook.sh /etc/letsencrypt/renewal-hooks/deploy/stalwart.sh
sudo RENEWED_LINEAGE="/etc/letsencrypt/live/$HOST" /etc/letsencrypt/renewal-hooks/deploy/stalwart.sh

step "5. stalwart-cli $CLI_VERSION (checksum verified)"
if [ ! -x "$MAILDIR/bin/stalwart-cli" ]; then
  arch=$(uname -m)
  base="https://github.com/stalwartlabs/cli/releases/download/$CLI_VERSION/stalwart-cli-$arch-unknown-linux-musl.tar.xz"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/cli.tar.xz" "$base"
  curl -fsSL -o "$tmp/cli.sha256" "$base.sha256"
  [ "$(sha256sum "$tmp/cli.tar.xz" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$tmp/cli.sha256")" ] || { echo "checksum mismatch"; exit 1; }
  tar -xJf "$tmp/cli.tar.xz" -C "$tmp"
  install -m 700 "$(find "$tmp" -name stalwart-cli -type f | head -1)" "$MAILDIR/bin/stalwart-cli"
  rm -rf "$tmp"
fi
CLI="$MAILDIR/bin/stalwart-cli --url $API --no-color"

step "6. Start Stalwart (bootstrap mode on first start)"
docker compose up -d stalwart
sleep 10

step "7. Bootstrap: hostname, domain, DKIM keys, console logs; permanent admin"
if [ ! -f "$MAILDIR/stalwart-admin.env" ]; then
  tmp_password=$(docker compose logs stalwart 2>&1 | grep -A4 'temporary administrator' | sed -n 's/.*password: *//p' | head -1)
  [ -n "$tmp_password" ] || { echo "temporary admin password not found in the logs"; exit 1; }
  $CLI --user admin --password "$tmp_password" update Bootstrap --file mail/bootstrap.json > "$MAILDIR/bootstrap-output.txt"
  admin_user=$(sed -n 's/.*username: *"\(.*\)".*/\1/p' "$MAILDIR/bootstrap-output.txt")
  admin_password=$(sed -n 's/.*secret: *"\(.*\)".*/\1/p' "$MAILDIR/bootstrap-output.txt")
  printf 'STALWART_USER=%s\nSTALWART_PASSWORD=%s\n' "$admin_user" "$admin_password" > "$MAILDIR/stalwart-admin.env"
  rm -f "$MAILDIR/bootstrap-output.txt"
  docker compose restart stalwart
  sleep 10
fi
set -a; . "$MAILDIR/stalwart-admin.env"; set +a

step "8. TLS certificate from the copied files"
if ! $CLI query Certificate | grep -q "$HOST"; then
  $CLI create Certificate --json '{"certificate":{"@type":"File","filePath":"/certs/fullchain.pem"},"privateKey":{"@type":"File","filePath":"/certs/privkey.pem"}}'
fi

step "9. Submission listener on 587 (STARTTLS)"
if ! $CLI query NetworkListener | grep -q ':587'; then
  $CLI create NetworkListener --json '{"name":"submission","bind":{"[::]:587":true},"protocol":"smtp","useTls":true,"tlsImplicit":false}'
fi

step "10. Sender account noreply@$DOMAIN for the app"
if [ ! -f "$MAILDIR/noreply.password" ]; then
  domain_id=$($CLI query Domain --json | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if line:
        d = json.loads(line)
        if d.get('name') == '$DOMAIN':
            print(d['id'])")
  openssl rand -hex 24 > "$MAILDIR/noreply.password"
  $CLI create Account --json "{\"@type\":\"User\",\"name\":\"noreply\",\"domainId\":\"$domain_id\",\"description\":\"HR Admin notifications\",\"credentials\":{\"0\":{\"@type\":\"Password\",\"secret\":\"$(cat "$MAILDIR/noreply.password")\"}}}"
fi

step "10b. Never ban Docker's own addresses; bans by the real client address"
# Through Nginx and Docker every visitor arrives from the Docker gateway:
# one scanner hitting /wp-json/ once got the gateway — so everyone — banned
# from the web admin (2026-10-06). Nginx overwrites X-Forwarded-For with the
# real address (mail/nginx-mail.artcomplect.com.conf), Stalwart uses it.
if ! $CLI query AllowedIp | grep -q '172.16.0.0/12'; then
  $CLI create AllowedIp --json '{"address":"172.16.0.0/12","reason":"Docker networks: Nginx and the app reach Stalwart through the gateway"}'
  $CLI create AllowedIp --json '{"address":"127.0.0.0/8","reason":"Loopback"}'
fi
$CLI update Http singleton --json '{"useXForwarded":true}'

step "11. Restart to start the new listener and load the certificate"
docker compose restart stalwart
sleep 10

step "12. DNS records Stalwart recommends (saved to $MAILDIR/dns-zone.txt)"
domain_id=$($CLI query Domain --json | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if line:
        d = json.loads(line)
        if d.get('name') == '$DOMAIN':
            print(d['id'])")
$CLI get Domain "$domain_id" --json --fields dnsZoneFile | python3 -c "import json, sys; print(json.load(sys.stdin)['dnsZoneFile'])" > "$MAILDIR/dns-zone.txt"
cat "$MAILDIR/dns-zone.txt"

step "13. The app sends e-mail through noreply@$DOMAIN"
if ! grep -q '^NOTIFY_EMAIL_URL=.' .env; then
  cp -p .env "$HOME/hrda-backups/infra-env-$(date +%F-%H%M).bak"
  sed -i '/^NOTIFY_EMAIL_URL=$/d' .env
  echo "NOTIFY_EMAIL_URL=mailtos://noreply:$(cat "$MAILDIR/noreply.password")@$HOST:465?mode=ssl&user=noreply@$DOMAIN&from=noreply@$DOMAIN" >> .env
  docker compose up -d app
fi

step "14. Test: Apprise → Stalwart (465) → the local noreply mailbox"
docker compose exec -T apprise apprise -t "Stalwart test" -b "Sent through $HOST:465" \
  "mailtos://noreply:$(cat "$MAILDIR/noreply.password")@$HOST:465?mode=ssl&user=noreply@$DOMAIN&from=noreply@$DOMAIN&to=noreply@$DOMAIN"

echo
echo "Done. Admin: https://$HOST/admin — credentials in $MAILDIR/stalwart-admin.env"
