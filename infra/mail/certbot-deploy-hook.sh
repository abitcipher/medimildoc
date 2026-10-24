#!/bin/sh
# certbot deploy hook (installed as /etc/letsencrypt/renewal-hooks/deploy/stalwart.sh):
# after mail.artcomplect.com is issued or renewed, copy it where the Stalwart
# container reads it (infra/mail-certs, owned by the container's user 2000)
# and tell Stalwart to reload its certificates.
set -eu
HOST=mail.artcomplect.com
REPO=/home/artcomplect/hrda
MAILDIR=/home/artcomplect/hrda-mail

case "${RENEWED_LINEAGE:-}" in
  */$HOST) ;;
  *) exit 0 ;;
esac

install -d -o 2000 -g 2000 -m 700 "$REPO/infra/mail-certs"
install -o 2000 -g 2000 -m 644 "$RENEWED_LINEAGE/fullchain.pem" "$REPO/infra/mail-certs/fullchain.pem"
install -o 2000 -g 2000 -m 600 "$RENEWED_LINEAGE/privkey.pem" "$REPO/infra/mail-certs/privkey.pem"

if [ -f "$MAILDIR/stalwart-admin.env" ]; then
  . "$MAILDIR/stalwart-admin.env"
  STALWART_URL=http://127.0.0.1:8086 STALWART_USER="$STALWART_USER" STALWART_PASSWORD="$STALWART_PASSWORD" \
    "$MAILDIR/bin/stalwart-cli" create Action --no-color --json '{"@type":"ReloadTlsCertificates"}' || true
fi
