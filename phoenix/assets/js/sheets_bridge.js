// Browser-side half of the postMessage bridge whose other half is
// apps_script/src/sidebar.html . Runs once at page load,
// BEFORE the LiveSocket connects — not a phx-hook, since connect_params are
// only read at connect time and hooks only mount after the socket is
// already up.
//
// Parent origin is unpredictable: the sidebar is itself served from one of
// Google's sandboxed googleusercontent.com subdomains (which one varies),
// mirroring the CSP `frame-ancestors` allowlist in
// AppWeb.Plugs.FrameAncestors. We can't target our outgoing message at an
// exact origin either, so it goes to '*' — acceptable since it carries no
// secret, just a request marker; what matters is validating what comes back.
export const PARENT_ORIGIN_PATTERN = /^https:\/\/([a-z0-9-]+\.)?googleusercontent\.com$/

/**
 * Resolves with the {spreadsheetId, sheetName, a1, email, token} payload
 * from the parent sidebar, or `null` if we're not embedded in one (e.g.
 * hitting /sheets directly in a plain browser tab during local dev), or
 * `{error}` when the sidebar reports a failure (CONTEXT_ERROR, e.g. the
 * SHARED_SECRET script property is missing) or doesn't answer in time
 * (`error: "timeout"`). A cold Apps Script start plus the first
 * authorization can take well over the usual 1–2 s, hence
 * the generous timeout.
 */
export function waitForSheetsContext({timeoutMs = 15000} = {}) {
  return new Promise((resolve) => {
    if (window.parent === window) {
      resolve(null)
      return
    }

    let settled = false
    const finish = (context) => {
      if (settled) return
      settled = true
      window.removeEventListener("message", onMessage)
      resolve(context)
    }

    function onMessage(event) {
      if (!PARENT_ORIGIN_PATTERN.test(event.origin)) return
      if (event.data && event.data.type === "CONTEXT") finish(event.data.payload)
      if (event.data && event.data.type === "CONTEXT_ERROR")
        finish({error: String(event.data.message || "error").slice(0, 300)})
    }

    window.addEventListener("message", onMessage)
    window.parent.postMessage({type: "REQUEST_CONTEXT"}, "*")
    setTimeout(() => finish({error: "timeout"}), timeoutMs)
  })
}

/**
 * Keeps a context fresh while the page is open: asks the sidebar for a new
 * one every `everyMs` and hands each successful answer to `onContext`.
 * The sign-in token lives 5 minutes (apps_script/src/main.ts mintToken),
 * and LiveView reuses its connect params on every reconnect, so without
 * this any reconnect after 5 minutes (sleep, network, a deploy) would fail
 * as expired. Failed refreshes are ignored: the current token stays.
 */
export function keepSheetsContextFresh(onContext, {everyMs = 4 * 60 * 1000} = {}) {
  if (window.parent === window) return
  setInterval(() => {
    waitForSheetsContext().then((context) => {
      if (context && context.token) onContext(context)
    })
  }, everyMs)
}
