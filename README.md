### Documentation Management for a Medical Paramilitary Organization

This file is just an entry point.

```
.
├── apps_script/   # thin Apps Script shim — menu item, sidebar iframe host,
│                  # getContext()/mintToken(). No business logic.
├── phoenix/       # the actual application — Phoenix/LiveView + Ash.
└── infra/         # deployment: docker-compose.yml + install instructions.
```

#### Status:

- `phoenix/` — generated Phoenix 1.8/LiveView app (`mix phx.new --app app
  --module App`), `AppWeb.SheetsLive` mounted at `/sheets`, the
  `frame-ancestors` CSP override required, the postMessage handshake +
  HMAC token verification binding the LiveView session to a `spreadsheetId`
  + user (M1), `App.Google.Sheets` — a thin Sheets API v4 client
  authenticated with the user's own forwarded OAuth token (M2),
  reading/writing a range from the LiveView, plus a `POST
  /webhooks/sheets/edit` route that the shim's onEdit trigger calls,
  broadcasting over PubSub to nudge open LiveViews to re-fetch — `App.People`
  (M3), an Ash domain modeling people/organizations/positions/assignment
  history plus a JSON-Schema-validated extensible record type for whatever
  else accrues around a person (medical, status changes, ...) — and now a
  standalone forms UI at `/people`, `/organizations`, `/positions` driven by
  a hand-rolled JSON Schema/UI Schema renderer (`AppWeb.JsonSchemaForm`),
  with `/people/:id` composing a person's identity + assignment history +
  records into one page — full create/edit/delete now, across all five
  resources. Also: Postgres 18 + UUIDv7, an Ash↔JSON-Schema
  drift-check mechanism, and three illustrative (explicitly unverified)
  `PersonRecord` kinds for APERSP-01/STANAG 5046/STANAG 6001. See `phoenix/README.md`.
- `apps_script/` — hand-written TS shim (Rollup bundle, not built via
  HtmlService), pointed at the same `/sheets` route; `getContext()`/
  `mintToken()` and the sidebar postMessage bridge were already in place
  from M0, now also forwarding `ScriptApp.getOAuthToken()` (M2) and
  installing an `onEdit` trigger that posts to the webhook above. See
  `apps_script/README.md`.
- `infra/` — bare-minimum single-VPS deploy: `docker-compose.yml`
  (Postgres + the Phoenix release + Caddy for automatic HTTPS) and a step-by-
  step install guide, sized for a 4 vCPU / 8 GB RAM / 80 GB disk box. The
  Terraform half (provisioning the VPS itself) isn't built yet —
  this assumes the server already exists. See `infra/README.md`.

Not done yet: real auth (the forms UI runs on a placeholder actor,`AppWeb.PlaceholderActor`), Terraform provisioning for `infra/`.

### Quickstart

```bash
# backend
cd phoenix && mix setup && mix phx.server

# shim (build only — clasp login/push needs your own Google account, see apps_script/README.md)
cd apps_script && npm install && npm run build
```
. . .

