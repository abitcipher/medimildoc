// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"
// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.
// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/app";
import { DateInput } from "./hooks/date_input";
import { ReferencePicker } from "./hooks/reference_picker";
import { ReferenceAutocomplete } from "./hooks/reference_autocomplete";
import { PagerTop } from "./hooks/pager_top";
import { OrgGraph } from "./hooks/org_graph";
import { SheetSelection } from "./hooks/sheet_selection";
import { installFloatTips } from "./float_tip";
import { installSectionGlow } from "./section_glow";
import topbar from "../vendor/topbar";
import { keepSheetsContextFresh, waitForSheetsContext } from "./sheets_bridge";
import { RulesEditor } from "./rules_editor_hook";
import MishkaComponents from "../vendor/mishka_components.js";
const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");
// Show progress bar on live navigation and form submits
topbar.config({
  barColors: {
    0: "#29d",
  },
  shadowColor: "rgba(0, 0, 0, .3)",
});
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// Sidebar: mark the link of the current page (docs/design/ui-plan.md
// item 6) with aria-current="page", which screen readers announce and
// app.css highlights. A link also counts for its sub-pages
// (/people matches /people/123). Runs on load and after every LiveView
// navigation.
const markCurrentNav = () => {
  const path = window.location.pathname;
  document.querySelectorAll("#app-sidebar a.sidebar-item-link").forEach((link) => {
    const href = link.getAttribute("href");
    const current = href === path || (href !== "/" && path.startsWith(`${href}/`));
    if (current) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  });
};
window.addEventListener("phx:page-loading-stop", markCurrentNav);
document.addEventListener("DOMContentLoaded", markCurrentNav);
// Hold the LiveSocket connect until the Sheets context (and its tokens) has arrived from the
// parent sidebar — or we give up waiting — so `params` below can read it
// synchronously at actual connect time. AppWeb.SheetsLive.mount/3 verifies
// sheets_token server-side; google_access_token isn't itself verified (it's
// Google's own token, not ours) and is used only for Sheets API calls made
// on the user's behalf. sheet_name/a1 are unsigned, informational only
// (note on App.SheetsToken) — used to pick a default range to
// display, never for authorization.
waitForSheetsContext().then((context) => {
  const liveSocket = new LiveSocket("/live", Socket, {
    longPollFallbackMs: 2500,
    params: (_liveViewName) => ({
      _csrf_token: csrfToken,
      sheets_token: context && context.token,
      google_access_token: context && context.googleAccessToken,
      sheet_name: context && context.sheetName,
      a1: context && context.a1,
      // Why there is no token, when there isn't one (sheets_bridge.js).
      sheets_error: context && context.error,
    }),
    hooks: {
      ...colocatedHooks,
      ...MishkaComponents,
      DateInput, ReferencePicker, ReferenceAutocomplete, RulesEditor, PagerTop, OrgGraph, SheetSelection,
    },
  });
  liveSocket.connect();
  // A fresh sign-in token for every later reconnect: `params` above is
  // evaluated again on each (re)connect and reads `context` then.
  keepSheetsContextFresh((fresh) => { context = fresh; });

  // Tooltips for data-float-tip elements (lists that scroll; see float_tip.js).
  installFloatTips();
  // Colour glow on content sections near the pointer (section_glow.js).
  installSectionGlow();
  // expose liveSocket on window for web console debug logs and latency simulation:
  // >> liveSocket.enableDebug()
  // >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
  // >> liveSocket.disableLatencySim()
  window.liveSocket = liveSocket;
});
// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      // Enable server log streaming to client.
      // Disable with reloader.disableServerLogs()
      reloader.enableServerLogs();
      // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
      //
      //   * click with "c" key pressed to open at caller location
      //   * click with "d" key pressed to open at function component definition location
      let keyDown;
      window.addEventListener("keydown", (e) => (keyDown = e.key));
      window.addEventListener("keyup", (_e) => (keyDown = null));
      window.addEventListener(
        "click",
        (e) => {
          if (keyDown === "c") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === "d") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true,
      );
      window.liveReloader = reloader;
    },
  );
}
