# apps_script/ — Sheets sidebar shim

Thin shim only (menu item, sidebar iframe host, context/token handoff). All
business logic lives in `phoenix/`.

## Setup (one-time, not run yet)

```bash
npm install
clasp login                 # opens a browser, needs a Google account
clasp create --type sheets --title "App shim" --rootDir dist
# ^ overwrites .clasp.json's scriptId with the newly created project's id
```

Then set the shared HMAC secret used by `mintToken()`  on the Apps
Script project itself (Project Settings → Script properties), key
`SHARED_SECRET` — not committed here.

**Also enable the Google Sheets API as an Advanced Service** (script editor
→ Services → **+** → Google Sheets API → Add) — confirmed live (
) that without this step, Phoenix's own `App.Google.Sheets` REST calls
 fail with `403 forbidden`, even though
`ScriptApp.getOAuthToken()` itself works fine and the built-in
`SpreadsheetApp` service (which this shim doesn't otherwise use) wouldn't
need this step at all. One-time, per script project.

## Build & deploy

```bash
npm run build   # rollup -> dist/main.js, plus copies sidebar.html + appsscript.json
npm run push    # build, then clasp push
```

## M0/M1/M2 status

`APP_ORIGIN` in `src/main.ts` still points at the placeholder
`https://app.example.com`. For local dev, point it at a real `https://`
tunnel to `phoenix`'s `/sheets` route (cloudflared, ngrok, or an SSH tunnel
like `localhost.run`) — **not** bare `http://localhost`, confirmed live
: the page itself loads fine over bare localhost, but the
LiveView WebSocket join doesn't (Chrome drops the `SameSite=Lax` session
cookie in this third-party-iframe context, so every join fails CSRF and
the client reload-loops forever). If your tunnel is a raw TCP forward
(no HTTP-aware reverse proxy in front, e.g. `localhost.run`) rather than
something like cloudflared/ngrok, also set `infra/.env`'s `PHX_HOST` to
the tunnel's own hostname, or Phoenix's `check_origin` rejects the
WebSocket handshake outright. Swap `APP_ORIGIN` back to the real one
before any actual deploy.

`appsscript.json` declares explicit `oauthScopes` (minimal-privilege, ADR-7):
`spreadsheets` (SpreadsheetApp reads here + the OAuth token forwarded to
Phoenix, ADR-5), `script.container.ui` (menu/sidebar), `script.external_request`
(the onEdit webhook's `UrlFetchApp.fetch` to our own, non-Google domain),
`userinfo.email`. Providing this list explicitly means GAS no longer
auto-detects scopes from what the script calls — if you add a call needing a
new scope, add it here too, or authorization will fail at runtime, not build
time.

`onOpen()` installs an **installable** `onEdit` trigger (`ensureEditTrigger`
→ `onSheetEdit`) the first time the menu loads, idempotently (checks
`ScriptApp.getProjectTriggers()` first). This is deliberate, not simple
`onEdit(e)`: a simple trigger runs with restricted permissions and cannot
call `UrlFetchApp` at all. `onSheetEdit` POSTs a
`{sheetName, a1}` nudge to `/webhooks/sheets/edit`, HMAC-signed the same way
as `mintToken()`; failures are swallowed on purpose (`onEdit` isn't
transactional or guaranteed, so a lost nudge must never surface as an error
to the person editing the sheet).
