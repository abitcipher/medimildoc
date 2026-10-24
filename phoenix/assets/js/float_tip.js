// Tooltips that scrolling areas can't clip: any element with
// data-float-tip="…" shows its text in one tooltip element placed in
// <body> with position: fixed, above the element (below if there is no
// room), kept inside the window. Shown on hover and keyboard focus,
// hidden on leave, blur, scroll and Escape. The element keeps its own
// aria-label for screen readers; the tooltip is aria-hidden.
// (daisyUI's CSS tooltips are drawn inside the element, so an
// overflow: auto list cuts them off whatever their z-index.)

const GAP = 6
const MARGIN = 4
let tip = null
let current = null

const element = () => {
  if (!tip) {
    tip = document.createElement("div")
    tip.setAttribute("aria-hidden", "true")
    tip.className =
      "pointer-events-none fixed z-[1000] max-w-xs rounded-field bg-neutral px-2 py-1 " +
      "text-xs text-neutral-content shadow-lg"
    tip.hidden = true
    document.body.append(tip)
  }
  return tip
}

const place = (el) => {
  const box = el.getBoundingClientRect()
  const size = tip.getBoundingClientRect()
  let top = box.top - size.height - GAP
  if (top < MARGIN) top = box.bottom + GAP
  const left = Math.max(
    MARGIN,
    Math.min(box.left + box.width / 2 - size.width / 2, window.innerWidth - size.width - MARGIN)
  )
  tip.style.top = `${top}px`
  tip.style.left = `${left}px`
}

// `data-float-tip-truncated`: only when the text is cut off (a
// `.badge-text` inside, or the element itself, narrower than its text).
const truncated = (el) => {
  const box = el.querySelector(".badge-text") || el
  return box.scrollWidth > box.clientWidth
}

const show = (el) => {
  const text = el.dataset.floatTip
  if (!text) return
  if ("floatTipTruncated" in el.dataset && !truncated(el)) return
  element().textContent = text
  tip.hidden = false
  current = el
  place(el)
}

const hide = () => {
  if (tip) tip.hidden = true
  current = null
}

const target = (event) => event.target instanceof Element && event.target.closest("[data-float-tip]")

export const installFloatTips = () => {
  document.addEventListener("pointerover", (e) => {
    const el = target(e)
    if (el && el !== current) show(el)
    else if (!el && current) hide()
  })
  document.addEventListener("focusin", (e) => {
    const el = target(e)
    if (el) show(el)
  })
  document.addEventListener("focusout", hide)
  document.addEventListener("scroll", hide, { capture: true, passive: true })
  document.addEventListener("keydown", (e) => e.key === "Escape" && hide())
  // A LiveView patch may remove the element under the pointer.
  window.addEventListener("phx:page-loading-start", hide)
}
