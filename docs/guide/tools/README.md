# Screenshot tools for the guides

- `cookie.sh <email>` — a signed session cookie for a demo user of the local
  copy (container `hrda-local-app-1`, Ukrainian UI).
- `shoot.mjs <shots.json> <outdir>` — Playwright screenshots of the local copy
  at http://localhost:5085 (not 127.0.0.1: the LiveView origin check), 2×.
  Shots: `{file, email, path, width?, height?, wait?, select?: [[sel, value]], click?: [sel]}`.
- `cdp.mjs` — raw CDP helper for the visible Chromium (port 9333, profile
  `~/snap/chromium/common/hrda-test-profile`) driving the real test spreadsheet:
  `newwin <url> WxH`, `eval`, `shot`, `click 'sel|text'`, `type`, `keys`, `key`.
- `snap.sh <out.png> side|full|grid` — window screenshot cropped to the sidebar
  and/or grid (below Google's own menus); `g.sh` — shell helpers (source it).

Paths inside the scripts point to the session scratchpad they were written in;
adjust `D=` / paths before reuse. `../build-pdf.sh` builds both PDFs.
