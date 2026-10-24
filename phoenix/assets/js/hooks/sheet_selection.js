// SHEETS-UI (docs/design/sheets-ui.md): tells the selected-row section
// (AppWeb.SheetsSelectionComponent) which cell is selected in the sheet.
// The sidebar can't see the selection by itself, so while the panel is
// shown it asks the Apps Script sidebar every 2 s: REQUEST_SELECTION
// (getSelection(), cheap) — or, with a shim pushed before SHEETS-UI that
// doesn't answer it, REQUEST_CONTEXT (getContext(), which also mints a
// token, so every 4 s). Only a changed selection goes to the server.
//
// Markup: <div phx-hook="SheetSelection"> … <button data-selection-refresh>
import { PARENT_ORIGIN_PATTERN } from "../sheets_bridge"

export const SheetSelection = {
  mounted() {
    this.last = null
    this.mode = "selection" // or "context" once the shim proves old
    this.answered = false

    this.onMessage = (event) => {
      if (!PARENT_ORIGIN_PATTERN.test(event.origin) || !event.data) return
      const { type, payload } = event.data
      if (type === "SELECTION") this.answered = true
      if ((type !== "SELECTION" && type !== "CONTEXT") || !payload || !payload.a1) return
      const key = `${payload.sheetName}!${payload.a1}`
      if (key === this.last) return
      this.last = key
      this.pushEventTo(this.el, "selection", { sheet: payload.sheetName, a1: payload.a1 })
    }
    window.addEventListener("message", this.onMessage)

    this.onClick = (event) => {
      if (event.target.closest("[data-selection-refresh]")) {
        this.last = null
        this.ask()
      }
    }
    this.el.addEventListener("click", this.onClick)

    // SHEETS-UI.18: Find → select the person's row in the sheet (the
    // shim's selectRange()); the polling then opens it here.
    this.handleEvent("sheets:select", ({ sheet, a1 }) => {
      if (window.parent === window) return
      window.parent.postMessage({ type: "SELECT_RANGE", payload: { sheetName: sheet, a1 } }, "*")
      this.last = null
      setTimeout(() => this.ask(), 800)
    })

    this.schedule()
    this.ask()
    // No answer to the first REQUEST_SELECTION: an older shim.
    this.probe = setTimeout(() => {
      if (!this.answered) {
        this.mode = "context"
        this.schedule()
      }
    }, 5000)
  },

  // After a reconnect (a deploy, a network drop) the server starts with
  // nothing selected: send the current selection again.
  reconnected() {
    this.last = null
    this.ask()
  },

  schedule() {
    clearInterval(this.timer)
    this.timer = setInterval(() => this.ask(), this.mode === "selection" ? 2000 : 4000)
  },

  ask() {
    if (window.parent === window || document.hidden || this.el.offsetParent === null) return
    const type = this.mode === "selection" ? "REQUEST_SELECTION" : "REQUEST_CONTEXT"
    window.parent.postMessage({ type }, "*")
  },

  destroyed() {
    clearInterval(this.timer)
    clearTimeout(this.probe)
    window.removeEventListener("message", this.onMessage)
    this.el.removeEventListener("click", this.onClick)
  },
}
