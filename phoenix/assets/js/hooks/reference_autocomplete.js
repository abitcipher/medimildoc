// Free text with suggestions from a big reference dataset (places,
// regions) or from values entered before (learned values, no code field): AppWeb.ReferenceComponents.autocomplete and
// docs/design/reference-data-and-files.md. The text field is an ordinary
// form field, so anything typed is kept. Picking a suggestion also sets the
// hidden code field; typing again clears the code, because the text no
// longer names that entry. Suggestions come from data-source (the app,
// which asks IHDS), narrowed to the country chosen in data-country-input.

const MIN_CHARS = 2
const DELAY_MS = 150

export const ReferenceAutocomplete = {
  mounted() {
    this.text = this.el.querySelector("[data-auto-text]")
    this.code = this.el.querySelector("[data-auto-code]")
    this.list = this.el.querySelector("[data-auto-list]")
    this.shown = []
    this.active = -1
    this.timer = null
    this.request = null

    this.text.addEventListener("input", () => {
      // Runs before the event reaches the form, so phx-change already
      // sees the cleared code.
      if (this.code && this.code.value !== "") this.code.value = ""
      clearTimeout(this.timer)
      this.timer = setTimeout(() => this.suggest(), DELAY_MS)
    })
    this.text.addEventListener("keydown", (e) => this.onKey(e))
    this.text.addEventListener("blur", () => setTimeout(() => this.close(), 150))
    this.list.addEventListener("mousedown", (e) => e.preventDefault())
    this.list.addEventListener("click", (e) => {
      const option = e.target.closest("[role=option]")
      if (option) this.choose(Number(option.dataset.index))
    })
  },

  destroyed() {
    clearTimeout(this.timer)
    this.request?.abort()
  },

  async suggest() {
    const query = this.text.value.trim()
    if (query.length < MIN_CHARS) return this.close()
    const url = new URL(this.el.dataset.source, window.location.origin)
    url.searchParams.set("q", query)
    const country = this.el.dataset.countryInput &&
      document.getElementById(this.el.dataset.countryInput)?.value
    if (country) url.searchParams.set("country", country)

    this.request?.abort()
    this.request = new AbortController()
    try {
      const response = await fetch(url, {
        credentials: "same-origin",
        headers: { accept: "application/json" },
        signal: this.request.signal,
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      this.render((await response.json()).entries)
    } catch (error) {
      if (error.name !== "AbortError") this.message(this.el.dataset.errorLabel)
    }
  },

  open() {
    this.list.hidden = false
    this.text.setAttribute("aria-expanded", "true")
  },

  close() {
    this.list.hidden = true
    this.text.setAttribute("aria-expanded", "false")
    this.text.removeAttribute("aria-activedescendant")
    this.active = -1
  },

  message(text) {
    const li = document.createElement("li")
    li.className = "px-2 py-1.5 text-sm opacity-70"
    li.textContent = text
    this.list.replaceChildren(li)
    this.shown = []
    this.open()
  },

  render(entries) {
    this.shown = entries
    if (entries.length === 0) {
      // Suggestion lists without an "empty" text (learned values) just close.
      return this.el.dataset.emptyLabel ? this.message(this.el.dataset.emptyLabel) : this.close()
    }
    this.list.replaceChildren(...entries.map((entry, i) => this.option(entry, i)))
    this.open()
    this.setActive(-1)
  },

  option(entry, index) {
    const li = document.createElement("li")
    li.id = `${this.list.id}-${index}`
    li.setAttribute("role", "option")
    li.setAttribute("aria-selected", "false")
    li.dataset.index = String(index)
    li.className =
      "flex cursor-pointer items-center gap-2 rounded-field px-2 py-1.5 text-sm " +
      "data-[active=true]:bg-base-200"
    if (entry.flag) {
      const img = document.createElement("img")
      img.src = `${this.el.dataset.flagBase}/${entry.flag}.svg`
      img.alt = ""
      img.className = "h-[0.9em] w-auto shrink-0 rounded-[2px] ring-1 ring-base-content/10"
      li.append(img)
    }
    const text = document.createElement("span")
    text.className = "min-w-0 grow truncate"
    const label = document.createElement("span")
    label.textContent = entry.label
    text.append(label)
    if (entry.context) {
      const context = document.createElement("span")
      context.className = "ms-1.5 text-xs opacity-60"
      context.textContent = entry.context
      text.append(context)
    }
    li.append(text)
    return li
  },

  setActive(index) {
    const options = this.list.querySelectorAll("[role=option]")
    this.active = index
    options.forEach((li, i) => {
      li.dataset.active = String(i === index)
      li.setAttribute("aria-selected", String(i === index))
    })
    if (index >= 0 && options[index]) {
      this.text.setAttribute("aria-activedescendant", options[index].id)
      options[index].scrollIntoView({ block: "nearest" })
    } else {
      this.text.removeAttribute("aria-activedescendant")
    }
  },

  onKey(e) {
    const open = !this.list.hidden && this.shown.length > 0
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      if (!open) return
      e.preventDefault()
      const step = e.key === "ArrowDown" ? 1 : -1
      const count = this.shown.length
      this.setActive((this.active + step + count) % count)
    } else if (e.key === "Enter" && open && this.active >= 0) {
      e.preventDefault()
      this.choose(this.active)
    } else if (e.key === "Escape" && !this.list.hidden) {
      e.preventDefault()
      this.close()
    }
  },

  choose(index) {
    const entry = this.shown[index]
    if (!entry) return
    this.text.value = entry.label
    this.close()
    // Text first (its input handler clears the code), then the code.
    this.text.dispatchEvent(new Event("input", { bubbles: true }))
    clearTimeout(this.timer)
    if (this.code) {
      this.code.value = entry.code
      this.code.dispatchEvent(new Event("input", { bubbles: true }))
    }
    this.fillRegion(entry)
  },

  // A place fills its region when the region field is still empty.
  fillRegion(entry) {
    const id = this.el.dataset.regionInput
    if (!id || !entry.region) return
    const regionText = document.getElementById(id)
    const regionBox = regionText?.closest("[phx-hook=ReferenceAutocomplete]")
    const regionCode = regionBox?.querySelector("[data-auto-code]")
    if (!regionText || !regionCode || regionText.value.trim() !== "") return
    regionText.value = entry.region_label || ""
    regionCode.value = entry.region
    regionCode.dispatchEvent(new Event("input", { bubbles: true }))
  },
}
