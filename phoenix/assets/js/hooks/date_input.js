// Date input shown as dd.mm.yyyy, or date and time as dd.mm.yyyy HH:MM
// (docs/design/reference-data-and-files.md, clinical-module.md). The
// visible text field has no name; the hidden native <input type="date"> or
// <input type="datetime-local"> next to it carries the ISO value that the form
// submits, and opens the browser's calendar from the button. The pattern
// comes from AppWeb.DateFormat via data-format, so a later per-user format
// setting doesn't need changes here beyond supporting its tokens.
const pad = (n, width) => String(n).padStart(width, "0")

// "dd.mm.yyyy HH:MM" -> [{token: "dd", sep: "."}, …, {token: "MM", sep: ""}]
const parts = (format) =>
  [...format.matchAll(/(dd|mm|yyyy|HH|MM)([^dmyHM]*)/g)].map(([, token, sep]) => ({ token, sep }))

// ISO "2026-09-27" or "2026-09-27T14:05" -> text in the display format.
const toDisplay = (iso, format) => {
  const match = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}))?/.exec(iso || "")
  if (!match) return ""
  const [, yyyy, mm, dd, HH = "00", MM = "00"] = match
  const values = { dd, mm, yyyy, HH, MM }
  const tokens = parts(format)
  return tokens.map(({ token, sep }, i) => values[token] + (i < tokens.length - 1 ? sep : "")).join("")
}

// Text in the display format -> ISO (date, or date and time when the
// format has hours and minutes), or null if it isn't a real date/time.
const toIso = (text, format) => {
  const tokens = parts(format)
  const pieces = text.split(/\D+/).filter(Boolean)
  if (pieces.length !== tokens.length) return null
  const v = {}
  tokens.forEach(({ token }, i) => (v[token] = pieces[i]))
  if (String(v.yyyy).length !== 4) return null
  const [y, m, d] = [v.yyyy, v.mm, v.dd].map(Number)
  const date = new Date(Date.UTC(y, m - 1, d))
  const realDate =
    date.getUTCFullYear() === y && date.getUTCMonth() === m - 1 && date.getUTCDate() === d
  if (!y || !m || !d || !realDate) return null
  const day = `${pad(y, 4)}-${pad(m, 2)}-${pad(d, 2)}`
  if (!("HH" in v)) return day
  const [h, min] = [Number(v.HH), Number(v.MM)]
  if (!(h >= 0 && h <= 23 && min >= 0 && min <= 59)) return null
  return `${day}T${pad(h, 2)}:${pad(min, 2)}`
}

// Keeps digits and inserts separators as the user types ("311220251405"
// -> "31.12.2025 14:05"), following the token lengths of the pattern.
const mask = (text, format) => {
  const digits = text.replace(/\D/g, "")
  let out = ""
  let at = 0
  parts(format).forEach(({ token, sep }, i, all) => {
    if (at >= digits.length) return
    const chunk = digits.slice(at, at + token.length)
    at += token.length
    out += chunk + (chunk.length === token.length && i < all.length - 1 && at < digits.length ? sep : "")
  })
  return out
}

export const DateInput = {
  mounted() {
    this.format = this.el.dataset.format || "dd.mm.yyyy"
    this.display = this.el.querySelector("[data-date-display]")
    this.value = this.el.querySelector("[data-date-value]")
    this.button = this.el.querySelector("[data-date-calendar]")
    this.invalidMessage = this.el.dataset.invalidMessage || "Invalid date"

    this.display.value = toDisplay(this.value.value, this.format)

    this.display.addEventListener("input", () => {
      const masked = mask(this.display.value, this.format)
      if (masked !== this.display.value) this.display.value = masked
      this.sync(false)
    })
    this.display.addEventListener("blur", () => this.sync(true))

    // The browser calendar (or anything else) changed the ISO value.
    this.value.addEventListener("change", () => {
      this.display.value = toDisplay(this.value.value, this.format)
      this.display.setCustomValidity("")
    })

    this.button.addEventListener("click", () => {
      try {
        this.value.showPicker()
      } catch (_e) {
        this.display.focus()
      }
    })
  },

  updated() {
    if (document.activeElement !== this.display) {
      this.display.value = toDisplay(this.value.value, this.format)
    }
  },

  // Copies the typed date into the hidden ISO input (and tells LiveView),
  // or marks the field invalid. `final` is true on blur: then an incomplete
  // entry is reported, while typing it is not.
  sync(final) {
    const text = this.display.value.trim()
    const iso = text === "" ? "" : toIso(text, this.format)
    const complete = text.length >= this.format.length

    if (iso === null) {
      this.display.setCustomValidity(final || complete ? this.invalidMessage : "")
      if (final || complete) this.display.reportValidity()
      return
    }

    this.display.setCustomValidity("")
    if (this.value.value !== iso) {
      this.value.value = iso
      this.value.dispatchEvent(new Event("input", { bubbles: true }))
    }
  },
}
