# infra/ — deploying the Phoenix app

Bare-minimum deployment: one VPS, Docker Compose, no
Kubernetes/orchestration. Two containers — `db` (Postgres, not exposed to
the internet) and `app` (the Phoenix release, built from
`phoenix/Dockerfile`), bound to loopback only. TLS termination and reverse
proxying is handled by an **Nginx already running on the host** (not part
of this compose file) — see `infra/nginx/`.

Sized for a **4 vCPU / 8 GB RAM / 80 GB disk** box (e.g. a Hetzner CPX31/CX32
— names Hetzner specifically). Provisioning that box with Terraform is
other half and **not covered here** — this assumes the server
already exists, reachable over SSH, with a public IPv4 address and Nginx
already installed and running.

---

## 1. One-time server setup

Tested against Ubuntu 22.04/24.04; adjust package-manager commands if you're
on something else.

```bash
# As a non-root sudo user on the fresh VPS:

# Docker Engine + Compose plugin (official convenience script)
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
# log out and back in for the group change to take effect

# Firewall: only SSH, HTTP, HTTPS from the internet. Nothing else — in
# particular, Postgres's 5432 is never exposed (docker-compose.yml doesn't
# map it to the host at all), and `app`'s own port is bound to loopback
# only (127.0.0.1:5085, mapped from the container's internal 4000 — see
# docker-compose.yml) — this is defense in depth, not the only layer.
sudo apt-get update && sudo apt-get install -y ufw
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

**DNS**: point an A record (and AAAA, if the box has IPv6) for the domain
you're deploying to at this server's IP *before* running `certbot` below —
it needs the domain to actually resolve here to issue a certificate.

## 1a. Nginx site config

`infra/nginx/hrda.artcomplect.com.conf` is a **reference template** — on
this deploy, the actual `server`/`upstream` blocks live inline in
`/etc/nginx/sites-available/default` (a file shared with other sites on
this box), not as their own file. Keep that file and this template in
sync by hand; there's no `certbot --nginx` auto-edit step here, since the
TLS cert (`/etc/letsencrypt/live/artcomplect.com/...`) already covers this
subdomain.

Read the comments at the top of `infra/nginx/hrda.artcomplect.com.conf`
before changing the real config: every `proxy_set_header` in it maps to a
real failure mode that this exact app hit when fronted by
a reverse proxy that didn't set them — in particular, a `Connection "";`
line silently disables the LiveView WebSocket upgrade instead of failing
loudly, so it's easy to miss.

## 2. Get the code onto the server

```bash
git clone <this-repo-url> app
cd app/infra
```

(Or `rsync`/`scp` a checkout over, if the server shouldn't have its own
clone/git credentials.)

## 3. Configure secrets

```bash
cp .env.example .env
```

Edit `.env` (never committed — see the repo's root `.gitignore`) and fill
in every blank:

| Variable | How to generate |
|---|---|
| `PHX_HOST` | the domain from step 1 |
| `POSTGRES_PASSWORD` | `openssl rand -hex 32` — **not** `-base64`: it goes unescaped into `DATABASE_URL` (`ecto://user:pass@db/...`), and a stray `/` or `+` from base64 output corrupts the parsed URL, failing every migration/query at boot (confirmed live). |
| `SECRET_KEY_BASE` | `openssl rand -base64 48` (or `mix phx.gen.secret` if you have Elixir locally) |
| `SHEETS_SHARED_SECRET` | `openssl rand -base64 32` — **must match** the value you set as the `SHARED_SECRET` script property in the Apps Script project (Project Settings → Script properties). See `apps_script/README.md`. |
| `TOKEN_SIGNING_SECRET` | `openssl rand -base64 48` — signs login sessions for the standalone forms UI (`/people`, `/organizations`, `/positions`). Unrelated to `SHEETS_SHARED_SECRET` above — see the note in `.env.example`. |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | From [Google Cloud Console](https://console.cloud.google.com) → APIs & Services → Credentials → Create Credentials → OAuth client ID (Web application). |
| `GOOGLE_REDIRECT_URI` | `https://<PHX_HOST>/auth/` (**the router's `/auth` prefix plus a trailing slash, both required** — confirmed live: missing either crashes the app on the first `/auth/user/google` request) — the resulting callback URL, `https://<PHX_HOST>/auth/user/google/callback`, is what you add as an **Authorized redirect URI** on that OAuth client. |

The forms UI (`/people`, `/organizations`, `/positions`) requires a signed-in
Google account to view at all — "just authenticated vs not", no roles yet
The embedded `/sheets` sidebar route is unaffected: it
authenticates via ADR-3's separate HMAC token, not this login.

## 4. Build and start

```bash
docker compose build
docker compose up -d
docker compose logs -f
```

First boot: `app` waits for `db`'s healthcheck, runs pending migrations
(`/app/bin/migrate`), then starts the release server on loopback-only
`127.0.0.1:5085` (mapped from the container's internal port 4000), which
Nginx (step 1a, already running) reverse proxies to.

Verify:

```bash
curl -sI https://$PHX_HOST/          # 200, Phoenix's default page
curl -sI https://$PHX_HOST/sheets    # 200, CSP frame-ancestors header present
```

### Test data

There is no real personal data. To fill the database with synthetic test
data (a demo brigade, ~150 people with records of every kind, one demo user
per role and access profile — all marked `synthetic`, see
`docs/design/access-control-phase1.md` §7):

```bash
docker compose exec app /app/bin/app eval "App.Release.seed_demo()"
docker compose exec app /app/bin/app eval "App.Release.purge_demo()"   # remove it again
```

Re-running `seed_demo` replaces the previous synthetic set. The VPS runs
Docker 29 with the Compose plugin (`docker compose`; the standalone
`docker-compose` v1 is gone since 2026-10-06).

The default synthetic set is also the FSDC reference dataset
(`docs/design/data-consistency.md`): after a deployment check the rules
against it (read-only) with

```bash
docker compose exec app /app/bin/app eval "App.Release.verify_rules()"
```

or the "Reference check" button on `/rules`. This VPS is the staging
environment: the reference set stays here. To keep a copy of a seeded set
as JSON files (decrypted, synthetic only):

```bash
docker compose exec app /app/bin/app eval "App.Release.export_demo(\"/tmp/demo-export\")"
docker cp $(docker compose ps -q app):/tmp/demo-export ~/hrda-reference/demo-seed1-$(date +%F)
```

## 5. Point the Apps Script shim at it

Set `APP_ORIGIN` in `apps_script/.env` to `https://<your-domain>` (see
`apps_script/README.md`), then `npm run push`. VPS mode: point it at the
real deployed domain from step 1 — this is the normal path, no tunnel
involved at all.

## Local-dev tunnel mode

The Apps Script sidebar runs on Google's own servers, reaching *out* to
your app over real HTTPS — a bare `http://localhost` is categorically
unreachable from there. To iterate locally against a real Google Sheet
without a third-party tunnel service (confirmed live to be unreliable —
random subdomains, mid-session drops, slow relays — this is what
prompted this section), reuse the VPS you already have as a private
reverse-tunnel relay.

**One-time VPS setup:**

1. Point a second DNS A/AAAA record at the same server, e.g.
   `dev.hrda.artcomplect.com`.
2. Reissue the certificate to cover it too (adjust names for your
   domain):
   ```bash
   sudo systemctl stop nginx
   sudo certbot certonly --cert-name artcomplect.com \
     -d artcomplect.com -d www.artcomplect.com \
     -d hrda.artcomplect.com -d dev.hrda.artcomplect.com \
     --standalone
   sudo systemctl start nginx
   ```
3. Add `infra/nginx/dev.hrda.artcomplect.com.conf`'s content into the
   VPS's real Nginx config (same "reference template, real config lives
   inline" caveat as step 1a) — its upstream is `127.0.0.1:5086` (or
   whatever `TUNNEL_REMOTE_PORT` you pick), nothing but the far end of
   the reverse tunnel below.
4. Generate a **dedicated** SSH key — never reuse your own login key for
   this:
   ```bash
   ssh-keygen -t ed25519 -N "" -f dev_tunnel_key
   ```
5. Add its public key to the VPS's `~/.ssh/authorized_keys`, locked down
   to forwarding only (adjust the port to match `TUNNEL_REMOTE_PORT`):
   ```
   command="/bin/false",restrict,port-forwarding,permitopen="127.0.0.1:5086" ssh-ed25519 AAAA... your-comment
   ```
   Confirmed live that `restrict` alone does **not** block non-interactive
   command execution (only pty/agent/X11 forwarding and `~/.ssh/rc`) — a
   key with just `restrict,port-forwarding` can still run arbitrary
   one-off commands (`ssh -i key host "whoami"` succeeds). The
   `command="/bin/false"` prefix is required to actually prevent that; it
   doesn't affect `-N`-only (forwarding, no command) sessions like the
   `tunnel` service uses.

**Every local dev session**, in `infra/.env`:

```bash
PHX_HOST=dev.hrda.artcomplect.com
GOOGLE_REDIRECT_URI=https://dev.hrda.artcomplect.com/auth/
TUNNEL_USER=<vps-ssh-user>
TUNNEL_HOST=<vps-hostname>
TUNNEL_SSH_KEY_PATH=/absolute/path/to/dev_tunnel_key
TUNNEL_REMOTE_PORT=5086
```

```bash
docker compose --profile tunnel up -d
```

`--profile tunnel` is required — without it, `docker compose up` starts
only `db`/`app`, same as VPS mode. Then point
`apps_script/.env`'s `APP_ORIGIN` at `https://dev.hrda.artcomplect.com`
and `npm run push` (see `apps_script/README.md`) — the sidebar now
reaches your local `app` container through the VPS.

If the sidebar reports something like "*dev.hrda.artcomplect.com is
taking too long to respond*", that means nothing's listening on the far
end — either the `tunnel` container isn't running, or it hasn't
finished (re)connecting. `infra/nginx/dev.hrda.artcomplect.com.conf` sets
a short `proxy_connect_timeout` specifically so this fails fast and
obviously rather than hanging.

## File storage (RustFS)

Photos, scans and imaging are stored in RustFS
(`docs/design/reference-data-and-files.md` §4), the `rustfs` service.

1. Set `RUSTFS_ACCESS_KEY` and `RUSTFS_SECRET_KEY` in `infra/.env`
   (`openssl rand -hex 16` / `openssl rand -hex 32`). The app gets them as
   `STORAGE_ACCESS_KEY`/`STORAGE_SECRET_KEY`; the bucket (`hrda-files`) is
   created at every start if missing.
2. Add the `location /hrda-files/` block from
   `infra/nginx/hrda.artcomplect.com.conf` to the site's `server` block
   and reload Nginx. Downloads are short-lived signed links to
   `https://<host>/hrda-files/…`, fetched straight from RustFS; the block
   keeps the `Host` header (it is signed), allows only GET/HEAD and sends
   `nosniff`. Uploads go through the app (LiveView), up to 200 MB a file.
3. Check: open a person, Files tab, upload a PDF, open it. `curl -I
   https://<host>/hrda-files/` must not return a listing (403).

## Updating

```bash
cd app && git pull
cd infra
docker compose build app ihds
docker compose up -d rustfs ihds app
```

`ihds` (reference data: countries, languages, currencies, places, search —
`docs/design/reference-data-and-files.md` §3): its seed files are baked into
the image and the search index is rebuilt at every start, so a new seed
version is just a rebuild. Its only state is the learned values
(organisational names entered before, no link to any person) on the
`ihds_data` volume. It needs about 300 MB of RAM. It has no host port; only `app`
reaches it (`IHDS_URL=http://ihds:4100`). If it is down, the app keeps
working and shows country codes instead of names.

Migrations run automatically on every `app` start (step 4's `command:`) —
no separate migration step needed for routine deploys.

## Encryption key (`CLOAK_KEY`)

Medical and vetting records, pay/family records, national ID numbers and
document numbers are stored encrypted (AES-256-GCM,
`docs/design/access-control-phase1.md`). The key is `CLOAK_KEY` in
`infra/.env`.

- **Keep a copy outside this server.** Without the key, every encrypted
  field is unreadable, backups included. A database dump alone reveals none
  of those fields.
- The old plaintext columns are gone (migration `DropPlaintextColumns`,
  2026-09-28): the database holds these fields only as ciphertext.

**Rotating the key** (no downtime needed beyond one restart):

1. Generate a new key: `openssl rand -base64 32`.
2. In `phoenix/config/runtime.exs`, make the new key the `default` cipher
   with a new tag (e.g. `"AES.GCM.V2"`) and keep the old key as a second,
   `retired` cipher so existing values stay readable. Put both keys in
   `infra/.env` (e.g. `CLOAK_KEY` and `CLOAK_KEY_OLD`).
3. Deploy, then re-encrypt everything under the new key:
   `docker compose exec app /app/bin/app eval "App.Release.reencrypt_all()"`.
4. Remove the old cipher and `CLOAK_KEY_OLD`, deploy again.

`test/app/encryption_test.exs` exercises this exact sequence.

## Mail (Stalwart)

The `stalwart` service (Stalwart 0.16) is the mail server for
`artcomplect.com`: SMTP on 25, submission on 465 (TLS) and 587 (STARTTLS),
IMAPS on 993; its web admin is reached only through the host Nginx at
`https://mail.artcomplect.com/admin`. The app sends notifications as
`noreply@artcomplect.com` (`NOTIFY_EMAIL_URL`).

First-time setup — everything is in `infra/mail/stalwart-setup.sh` (re-runnable;
secrets go to `~/hrda-mail/`, never into the repository):

```bash
cd ~/hrda && bash infra/mail/stalwart-setup.sh
```

What it does, step by step (the main commands):

1. Firewall — `sudo ufw allow 25/tcp`, `465/tcp`, `587/tcp`, `993/tcp`.
2. Nginx site for the admin — `infra/mail/nginx-mail.artcomplect.com.conf` →
   `/etc/nginx/sites-available/mail.artcomplect.com`, symlink in
   `sites-enabled`, `sudo nginx -t && sudo systemctl reload nginx`.
3. Certificate — `sudo certbot --nginx -d mail.artcomplect.com --redirect`
   (renewed by certbot's timer).
4. Renewal hook — `infra/mail/certbot-deploy-hook.sh` →
   `/etc/letsencrypt/renewal-hooks/deploy/stalwart.sh`: copies the certificate
   to `infra/mail-certs/` (owned by the container's user 2000) and reloads it
   in Stalwart (`stalwart-cli create Action '{"@type":"ReloadTlsCertificates"}'`).
5. `stalwart-cli` v1.0.13 downloaded to `~/hrda-mail/bin/`, checksum verified.
6. `docker compose up -d stalwart` — the first start is "bootstrap mode" with a
   temporary `admin` password printed in the log.
7. Bootstrap — `stalwart-cli update Bootstrap --file infra/mail/bootstrap.json`:
   hostname `mail.artcomplect.com`, domain `artcomplect.com`, **DKIM keys
   generated** (RSA and Ed25519), logs to the console, no ACME (Nginx owns
   80/443). It answers with the permanent administrator
   (`admin@artcomplect.com`) and its password → `~/hrda-mail/stalwart-admin.env`.
   Then `docker compose restart stalwart`.
8. Certificate from the copied files — `stalwart-cli create Certificate`
   with `{"@type":"File","filePath":"/certs/fullchain.pem"}` and the key.
9. Submission listener on 587 — `stalwart-cli create NetworkListener`
   (`[::]:587`, STARTTLS).
10. **Sender account** — `stalwart-cli create Account`
    `{"@type":"User","name":"noreply","domainId":…,"credentials":{"0":{"@type":"Password","secret":…}}}`;
    the password (random) → `~/hrda-mail/noreply.password`.
    Then Docker's networks and loopback go on the allow list (`AllowedIp`
    `172.16.0.0/12`, `127.0.0.0/8`) and Stalwart takes the client address
    from `X-Forwarded-For` (`Http.useXForwarded`), which the Nginx site
    overwrites with the real address. Without this, one web scanner gets
    the Docker gateway — every visitor of the admin — banned (502).
11. `docker compose restart stalwart`.
12. DNS records Stalwart recommends — `stalwart-cli get Domain <id> --fields dnsZoneFile`
    → `~/hrda-mail/dns-zone.txt` (DKIM, DMARC, MTA-STS, TLS-RPT, SRV…).
13. `NOTIFY_EMAIL_URL=mailtos://noreply:<password>@mail.artcomplect.com:465?mode=ssl&user=noreply@artcomplect.com&from=noreply@artcomplect.com`
    appended to `infra/.env` (backup first), `docker compose up -d app`.
    `mode=ssl` matters: 465 is TLS from the first byte.
14. Test — Apprise sends through 465 to the local `noreply` mailbox.

Running `stalwart-cli` when the admin is unreachable (e.g. banned): copy it
into the container and use its own loopback —
`docker cp ~/hrda-mail/bin/stalwart-cli infra_stalwart_1:/tmp/`, then
`docker exec -e HOME=/tmp -e STALWART_USER -e STALWART_PASSWORD
infra_stalwart_1 /tmp/stalwart-cli --url http://127.0.0.1:8080 …`
(remove it afterwards). Lift a ban: `query BlockedIp`, `delete BlockedIp --ids <id>`.

DNS (at the registrar): MX `artcomplect.com` → `mail.artcomplect.com`, A
`mail.artcomplect.com` → the VPS, SPF, the DKIM TXT records from
`dns-zone.txt`, DMARC (start with `p=none`), and reverse DNS of the VPS
address → `mail.artcomplect.com` (Hetzner console).

## Notifications (RabbitMQ + Apprise)

`rabbitmq` and `apprise` (Apprise API, stateless) run beside the app with
no host ports (docs/design/search-timeline-notifications.md). `.env`
needs `RABBITMQ_PASSWORD` (`openssl rand -hex 32`). Each channel is used
once its sender is set as an Apprise URL — `NOTIFY_EMAIL_URL`,
`NOTIFY_TELEGRAM_URL`, `NOTIFY_SIGNAL_URL`, `NOTIFY_MATRIX_URL`
(examples in `.env.example`); until then its messages wait in the outbox
and users see them in the app (`/notifications`). Recreate the app after
changing them (`docker compose up -d app`).

## Local copy of the staging stack

When the VPS is unreachable, the same images run on a workstation as a
separate Compose project (`hrda-local`, own volumes), with local-only
secrets in `~/hrda-local/.env` (never the VPS values) and
`~/hrda-local/override.yml` (file storage on `127.0.0.1:9110`,
`STORAGE_PUBLIC_URL=http://localhost:9110`):

```bash
cd infra
DC="docker compose -p hrda-local --env-file ~/hrda-local/.env -f docker-compose.yml -f ~/hrda-local/override.yml"
$DC up -d --build db ihds rustfs rabbitmq apprise app   # app on http://localhost:5085
$DC exec app /app/bin/app eval "App.Release.seed_demo()"
$DC exec app /app/bin/app rpc "App.Release.verify_rules()"
$DC down                                     # stop (volumes kept)
```

Google sign-in needs an OAuth client with the redirect
`http://localhost:5085/auth/user/google/callback`; without it, sign in on
the dev server (`mix phx.server`, `/dev/sign-in`) or mint a session
(tools and checks).

## Go-live checklist (before real personal data)

1. `ADMIN_FULL_DATA_ACCESS=false` in `infra/.env`, restart. Confirm the
   startup warning is gone and an admin can no longer open medical records.
2. ~~`CLOAK_KEY` is backed up somewhere other than this server, and who
   holds it is written down~~ — done (user).
3. Remove test data: `docker compose exec app /app/bin/app eval "App.Release.purge_demo()"`.
4. ~~Drop the empty plaintext columns~~ — done 
   (`DropPlaintextColumns`).
5. Review every user's role and access profiles on `/users`.
5a. `REQUIRE_SECOND_APPROVAL=true` in `infra/.env` once there are at least two
    administrators: granting clinician, command surgeon, security officer,
    CISO or the admin role then needs a second approver.
5b. Link every account to its person on `/users`: unit-scoped profiles see
    nothing without it, and clearances come from the linked person.
5c. Event log (`/events`): decide whether `Publish to subscribers` is on;
    a subscriber binds its own queue to the exchange `hrda.events`
    (e.g. `hrda.auth.#`). `EVENTS_INSTANCE` (default `PHX_HOST`) names
    this server in each event's source.
6. Give someone the CISO profile and check `/access-log` shows reads.
7. Stored files (RustFS) are not encrypted by the app (chosen: signed links
   and the access log instead). Put the Docker volumes — at least
   `rustfs_data` and `db_data` — on an encrypted disk (LUKS or the
   provider's encrypted volumes) before real scans and imaging arrive.
8. ~~Rotate `RUSTFS_ACCESS_KEY`/`RUSTFS_SECRET_KEY` away from any value
   used during testing~~ — done 2026-09-28. To rotate again: new values
   in `infra/.env`, then `docker compose up -d rustfs app` (RustFS keeps
   its data when its root keys change; checked).

## Backups

Not automated by this compose file (deliberately out of "bare minimum"
scope). At minimum, before relying on this in production, set up one of:

- A cron job running `docker compose exec db pg_dump -U $POSTGRES_USER
  $POSTGRES_DB` to off-box storage, or
- Your VPS provider's block-storage snapshot feature on the volume backing
  `db_data` (check where Docker actually stores named volumes on your setup
  — `docker volume inspect infra_db_data`).

Stored files live in the `rustfs_data` volume and must be backed up with
the database (a file row without its object, or the reverse, is useless):
snapshot both volumes together, or copy the bucket with any S3 tool
(`rclone`, `aws s3 sync` against `http://127.0.0.1:9100`).

## Why the Nginx config's `proxy_set_header` lines are not optional

`config/prod.exs` enables `AppWeb.Endpoint`'s `force_ssl`, with
`rewrite_on: [:x_forwarded_proto]` — it trusts whatever the reverse proxy
in front says about the original request's scheme, rather than the raw
(plain HTTP) connection Phoenix itself actually sees from Nginx. Same
story for the session cookie's `same_site: "None"` (`config/prod.exs`'s
`session_same_site`, needed by the embedded `/sheets` route inside
Google's own sandboxed iframe): `SameSite=None` requires
the `Secure` attribute, and Plug infers that from the same rewritten
scheme.

If Nginx doesn't send `X-Forwarded-Proto: https` (and `Host`,
`X-Forwarded-For`) on every request, none of that works — confirmed live
in against a different reverse proxy (a raw SSH tunnel)
that didn't send these, which redirect-looped every request to the wrong
host. `infra/nginx/hrda.artcomplect.com.conf` documents them (the real
config lives inline in this VPS's shared `default` site file — see step
1a); if you ever replace or hand-edit it, keep them — and keep
`Upgrade`/`Connection: upgrade` too: an early draft of
this exact config had `Connection "";` instead, which silently disables
the LiveView WebSocket upgrade rather than failing loudly.
