// Thin shim only: menu item, sidebar iframe host, context handoff, token
// minting, and forwarding the onEdit signal. No business logic here
//
// M0/M1/M2: during local development this MUST be a real https:// origin
// — either infra/'s local-dev tunnel mode ( recommended —
// our own VPS, not a third-party tunnel service) or a generic tunnel
// (cloudflared/ngrok/localhost.run) — never bare http://localhost,
// confirmed live 2026-09-08. The page itself loads fine over bare
// localhost (Chrome's secure-context exception for localhost lets an
// https:// Google Sheets page embed an http://localhost iframe past the
// usual mixed-content block), but the LiveView WebSocket join doesn't:
// Phoenix's session cookie is SameSite=Lax by default, which Chrome
// refuses to send back in this third-party-iframe context, so the join
// fails CSRF validation every time and phoenix_live_view's client falls
// back to a full page reload — forever, every ~4s. Only SameSite=None;
// Secure survives a third-party context, and Secure requires real HTTPS
// — see for the fix. A raw TCP tunnel (no HTTP-aware
// reverse proxy in front, e.g. an SSH tunnel) also needs PHX_HOST set to
// the tunnel's own hostname (Phoenix's LiveView socket check_origin
// rejects the WS handshake otherwise: "Could not check origin") — the
// real prod deploy (behind Nginx, ) doesn't need this,
// Nginx forwards the real Host already. One caveat regardless of
// tunnel/local/prod: onSheetEdit()'s UrlFetchApp.fetch below runs on
// Google's servers, not the browser — it can never reach a bare
// localhost, only a real reachable URL — harmless here, failures are
// swallowed, see the comment on onSheetEdit.
//
// APP_ORIGIN itself is build-time config (), not a
// hand-edited constant — apps_script/.env's APP_ORIGIN (read by
// rollup.config.mjs, gitignored, mirrors infra/.env's own pattern) if
// set, else the real deployed origin, so a plain `npm run push` with no
// .env at all still does the right (production) thing. See
// apps_script/README.md for local-dev-tunnel setup. `process` doesn't
// really exist at runtime here (GAS's V8 has no such global) —
// `@rollup/plugin-replace` substitutes this whole expression for a
// literal string at build time, before this ever reaches GAS; see
// rollup.config.mjs and src/env.d.ts.
//
// Two unrelated tokens travel through this file:
//   - mintToken()'s HMAC token : authenticates the LiveView session
//     to Phoenix itself.
//   - ScriptApp.getOAuthToken() : the user's own Google access token,
//     forwarded so Phoenix can call the Sheets API *as that user* — never a
//     shared service account / goth token.
const APP_ORIGIN = process.env.APP_ORIGIN;

function onOpen(): void {
  SpreadsheetApp.getUi().createMenu('App').addItem('Open panel', 'showSidebar').addToUi();
}

// Idempotent: installable triggers (unlike the simple onEdit(e) global,
// which can't call UrlFetchApp — restricted permissions)
// must be created explicitly and aren't automatically deduplicated by GAS.
// Called from showSidebar(), not onOpen(): onOpen runs as a simple trigger
// without the user's authorization, where ScriptApp.getProjectTriggers()
// fails ("Specified permissions are not sufficient…", seen live
// 2026-09-28). Needs the script.scriptapp scope (appsscript.json). The
// trigger belongs to the user who opened the panel; each user gets their
// own (getProjectTriggers() lists only the current user's). A failure here
// must not stop the panel from opening.
function ensureEditTrigger(): void {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const alreadyInstalled = ScriptApp.getProjectTriggers().some(
    (t) => t.getHandlerFunction() === 'onSheetEdit' && t.getTriggerSourceId() === ss.getId()
  );
  if (!alreadyInstalled) {
    ScriptApp.newTrigger('onSheetEdit').forSpreadsheet(ss).onEdit().create();
  }
}

function showSidebar(): void {
  try {
    ensureEditTrigger();
  } catch (err) {
    console.error('ensureEditTrigger failed (non-fatal): ' + err);
  }
  const template = HtmlService.createTemplateFromFile('sidebar');
  // Single source of truth for the trusted origin: sidebar.html reads it
  // back via `<?!= appOrigin ?>` instead of hardcoding its own copy.
  template.appOrigin = APP_ORIGIN;
  const html = template
    .evaluate()
    .setTitle('App')
    .setSandboxMode(HtmlService.SandboxMode.IFRAME);
  SpreadsheetApp.getUi().showSidebar(html);
}

interface SheetContext {
  spreadsheetId: string;
  sheetName: string;
  a1: string;
  email: string;
  token: string;
  googleAccessToken: string;
}

function getContext(): SheetContext {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const sheet = ss.getActiveSheet();
  const activeRange = sheet.getActiveRange();
  return {
    spreadsheetId: ss.getId(),
    sheetName: sheet.getName(),
    a1: activeRange ? activeRange.getA1Notation() : '',
    email: Session.getActiveUser().getEmail(),
    token: mintToken(ss.getId()),
    // ADR-5: the user's own Sheets-scoped OAuth token, forwarded as-is so
    // Phoenix can call the Sheets API on their behalf. Always fresh/valid —
    // GAS mints it per execution, no manual refresh needed on our end.
    googleAccessToken: ScriptApp.getOAuthToken(),
  };
}

// SHEETS-UI (docs/design/sheets-ui.md): just where the cursor is, for the
// sidebar's row form, which asks every 2 s while it is shown — no token
// minted, unlike getContext().
interface SheetSelection {
  sheetName: string;
  a1: string;
}

function getSelection(): SheetSelection {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getActiveSheet();
  const range = sheet.getActiveRange();
  return { sheetName: sheet.getName(), a1: range ? range.getA1Notation() : '' };
}

// SHEETS-UI.18: the sidebar's Find goes to a person's row. Only a plain
// A1 reference on an existing tab; anything else is ignored.
function selectRange(sheetName: string, a1: string): void {
  if (typeof sheetName !== 'string' || typeof a1 !== 'string') return;
  if (!/^[A-Z]{1,3}[0-9]{1,7}(:[A-Z]{1,3}[0-9]{1,7})?$/.test(a1)) return;
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const sheet = ss.getSheetByName(sheetName);
  if (!sheet) return;
  ss.setActiveSheet(sheet);
  sheet.setActiveRange(sheet.getRange(a1));
}

// HMAC-SHA256 via Utilities — the GAS V8 runtime has no crypto/TextEncoder.
function mintToken(spreadsheetId: string): string {
  const secret = PropertiesService.getScriptProperties().getProperty('SHARED_SECRET');
  if (!secret) {
    throw new Error('SHARED_SECRET script property is not set');
  }
  const payload = Utilities.base64EncodeWebSafe(
    JSON.stringify({
      sub: Session.getActiveUser().getEmail(),
      ssid: spreadsheetId,
      exp: Math.floor(Date.now() / 1000) + 300,
    })
  );
  const sig = Utilities.base64EncodeWebSafe(Utilities.computeHmacSha256Signature(payload, secret));
  return `${payload}.${sig}`;
}

// Installed by ensureEditTrigger(), not called directly by GAS as a simple
// trigger. onEdit is not transactional and delivery isn't
// guaranteed — this is a best-effort "something changed, go re-fetch" nudge
// for already-open LiveViews Sheets is a view, never the source of
// truth), not a critical path. Failures are swallowed on purpose — a lost
// nudge just means an open sidebar shows slightly stale data until its next
// manual refresh; it must never surface as an error to the person editing
// the sheet.
function onSheetEdit(e: GoogleAppsScript.Events.SheetsOnEdit): void {
  const spreadsheetId = e.source.getId();
  const payload = {
    sheetName: e.range.getSheet().getName(),
    a1: e.range.getA1Notation(),
  };
  try {
    UrlFetchApp.fetch(`${APP_ORIGIN}/webhooks/sheets/edit`, {
      method: 'post',
      contentType: 'application/json',
      headers: {Authorization: `Bearer ${mintToken(spreadsheetId)}`},
      payload: JSON.stringify(payload),
      muteHttpExceptions: true,
    });
  } catch (err) {
    console.error('onSheetEdit webhook failed (non-fatal): ' + err);
  }
}
