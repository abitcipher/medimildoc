// Searchable picker for small reference datasets (countries), see
// AppWeb.ReferenceComponents.country_picker and
// docs/design/reference-data-and-files.md. The whole list (a few
// hundred entries, labels in the user's language) is loaded once from
// data-source and filtered in the browser, so typing is instant. The
// chosen code goes into the hidden [data-picker-value] input, and an
// "input" event lets the surrounding LiveView form see the change.

const cache = new Map()

// Alphabetical order depends on the language (Ukrainian "і" comes before
// "к"; code-point order puts it after "я"), so the list the server sends
// is re-sorted here with the page language's collation.
const collate = (entries) => {
  const collator = new Intl.Collator(document.documentElement.lang || undefined)
  return [...entries].sort((a, b) => collator.compare(a.label, b.label))
}

const load = (url) => {
  if (!cache.has(url)) {
    const request = fetch(url, { credentials: "same-origin", headers: { accept: "application/json" } })
      .then((response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        return response.json()
      })
      .then((body) => collate(body.entries))
    request.catch(() => cache.delete(url))
    cache.set(url, request)
  }
  return cache.get(url)
}

// Same folding as AppWeb.ReferenceController: lowercase, accents removed.
export const normalize = (text) =>
  text.toLowerCase().normalize("NFD").replace(/\p{M}/gu, "")

const queryWords = (text) => normalize(text).split(/[^\p{L}\p{N}]+/u).filter(Boolean)

// Every query word must start some word of the entry. Ranked: exact code
// or alternative name, label starting with the query, label containing
// it, any other match; ties alphabetically (the list comes sorted).
export const filter = (entries, query) => {
  const words = queryWords(query)
  if (words.length === 0) return entries
  const needle = normalize(query.trim())
  const ranked = []
  entries.forEach((entry, order) => {
    const matches = words.every((w) => entry.words.some((word) => word.startsWith(w)))
    if (!matches) return
    const label = normalize(entry.label)
    const rank = entry.exact.includes(needle)
      ? 0
      : label.startsWith(needle)
        ? 1
        : label.includes(needle)
          ? 2
          : 3
    ranked.push({ entry, rank, order })
  })
  ranked.sort((a, b) => a.rank - b.rank || a.order - b.order)
  return ranked.map((r) => r.entry)
}

export const ReferencePicker = {
  mounted() {
    this.value = this.el.querySelector("[data-picker-value]")
    this.toggle = this.el.querySelector("[data-picker-toggle]")
    this.current = this.el.querySelector("[data-picker-current]")
    this.panel = this.el.querySelector("[data-picker-panel]")
    this.search = this.el.querySelector("[data-picker-search]")
    this.list = this.el.querySelector("[data-picker-list]")
    this.entries = null
    this.shown = []
    this.active = -1

    // Start loading as soon as the user heads for the button.
    const prefetch = () => load(this.el.dataset.source).catch(() => {})
    this.toggle.addEventListener("pointerenter", prefetch, { once: true })
    this.toggle.addEventListener("focus", prefetch, { once: true })
    this.toggle.addEventListener("click", () => (this.isOpen() ? this.close(true) : this.open()))
    this.toggle.addEventListener("keydown", (e) => {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault()
        this.open()
      }
    })
    // The search box is not a form field: keep its keystrokes away from
    // the LiveView form's phx-change.
    this.search.addEventListener("input", (e) => {
      e.stopPropagation()
      this.render()
    })
    this.search.addEventListener("change", (e) => e.stopPropagation())
    this.search.addEventListener("keydown", (e) => this.onKey(e))
    this.list.addEventListener("mousedown", (e) => e.preventDefault())
    this.list.addEventListener("click", (e) => {
      const option = e.target.closest("[role=option]")
      if (option) this.choose(Number(option.dataset.index))
    })
    this.outside = (e) => {
      if (this.isOpen() && !this.el.contains(e.target)) this.close(false)
    }
    document.addEventListener("pointerdown", this.outside)
  },

  destroyed() {
    document.removeEventListener("pointerdown", this.outside)
  },

  isOpen() {
    return !this.panel.hidden
  },

  async open() {
    this.panel.hidden = false
    this.toggle.setAttribute("aria-expanded", "true")
    this.search.value = ""
    this.search.focus()
    if (!this.entries) {
      this.message(this.el.dataset.loadingLabel || "…")
      try {
        this.entries = await load(this.el.dataset.source)
      } catch (_error) {
        this.message(this.el.dataset.errorLabel)
        return
      }
    }
    this.render()
  },

  close(refocus) {
    this.panel.hidden = true
    this.toggle.setAttribute("aria-expanded", "false")
    this.search.removeAttribute("aria-activedescendant")
    if (refocus) this.toggle.focus()
  },

  message(text) {
    this.list.replaceChildren()
    const li = document.createElement("li")
    li.className = "px-2 py-1.5 text-sm opacity-70"
    li.textContent = text
    this.list.append(li)
  },

  // Options shown: an optional "none" entry, then the filtered countries.
  render() {
    if (!this.entries) return
    const matches = filter(this.entries, this.search.value)
    const clear = this.el.dataset.allowClear === "true" && this.search.value.trim() === ""
    this.shown = clear ? [{ code: "", label: this.el.dataset.clearLabel }, ...matches] : matches
    if (this.shown.length === 0) {
      this.message(this.el.dataset.emptyLabel)
      this.active = -1
      return
    }
    const selected = this.value.value
    this.list.replaceChildren(...this.shown.map((entry, i) => this.option(entry, i, selected)))
    const at = this.shown.findIndex((e) => e.code === selected)
    this.setActive(this.search.value.trim() === "" && at >= 0 ? at : 0)
  },

  option(entry, index, selected) {
    const li = document.createElement("li")
    li.id = `${this.list.id}-${index}`
    li.setAttribute("role", "option")
    li.setAttribute("aria-selected", String(entry.code === selected))
    li.dataset.index = String(index)
    li.className =
      "flex cursor-pointer items-center gap-2 rounded-field px-2 py-1.5 text-sm " +
      "aria-selected:font-semibold data-[active=true]:bg-base-200"
    if (entry.flag) {
      const img = document.createElement("img")
      img.src = `${this.el.dataset.flagBase}/${entry.flag}.svg`
      img.alt = ""
      img.loading = "lazy"
      img.className = "h-[0.9em] w-auto shrink-0 rounded-[2px] ring-1 ring-base-content/10"
      li.append(img)
    }
    const label = document.createElement("span")
    label.className = "grow truncate"
    label.textContent = entry.label
    li.append(label)
    if (entry.code) {
      const code = document.createElement("span")
      code.className = "font-mono text-xs opacity-60"
      code.textContent = entry.code
      li.append(code)
    }
    return li
  },

  setActive(index) {
    const options = this.list.querySelectorAll("[role=option]")
    if (options.length === 0) return
    this.active = Math.max(0, Math.min(index, options.length - 1))
    options.forEach((li, i) => (li.dataset.active = String(i === this.active)))
    const li = options[this.active]
    this.search.setAttribute("aria-activedescendant", li.id)
    li.scrollIntoView({ block: "nearest" })
  },

  onKey(e) {
    const moves = { ArrowDown: 1, ArrowUp: -1, PageDown: 8, PageUp: -8 }
    if (e.key in moves) {
      e.preventDefault()
      this.setActive(this.active + moves[e.key])
    } else if (e.key === "Enter") {
      e.preventDefault()
      if (this.active >= 0) this.choose(this.active)
    } else if (e.key === "Escape") {
      e.preventDefault()
      this.close(true)
    } else if (e.key === "Tab") {
      this.close(false)
    }
  },

  choose(index) {
    const entry = this.shown[index]
    if (!entry) return
    this.value.value = entry.code
    this.current.replaceChildren()
    if (entry.code) {
      // Flag and name only; the code chip stays in the list.
      const [flag, label] = this.option(entry, index, entry.code).children
      this.current.append(...[flag, label].filter(Boolean))
    } else {
      const none = document.createElement("span")
      none.className = "opacity-60"
      none.textContent = entry.label
      this.current.append(none)
    }
    this.close(true)
    this.value.dispatchEvent(new Event("input", { bubbles: true }))
  },
}
