// Colour glow on content sections near the pointer (docs/design/ui-preferences.md
// section 5; the look is in app.css "Content sections"). One pointer
// listener for the whole app: on each frame it finds the sections near the
// pointer and gives each the pointer position inside it (--gx, --gy) and
// whether to show the light (--glow-on); the hue follows the pointer across
// the screen (--glow-hue on #app-main), so the light changes colour as it
// moves. Off when the viewer chose a frame only or nothing
// (data-sections on #app-main), on touch screens, and with reduced motion.
const SECTIONS = "section:not(section section):not([role=tabpanel])"
const REACH = 120 // px around a section where its border starts to light up
const BASE_HUE = 190
const SPREAD = 170

export function installSectionGlow() {
  const capable = window.matchMedia("(hover: hover) and (pointer: fine)")
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)")
  let pointer = null
  let frame = null
  let lit = new Set()

  const enabled = (main) =>
    main && main.dataset.sections === "glow" && capable.matches && !reduced.matches

  const clear = () => {
    lit.forEach((el) => el.style.setProperty("--glow-on", "0"))
    lit = new Set()
  }

  const update = () => {
    frame = null
    const main = document.getElementById("app-main")
    if (!pointer || !enabled(main)) return clear()

    const { x, y } = pointer
    main.style.setProperty("--glow-hue", (BASE_HUE + (x / window.innerWidth) * SPREAD).toFixed(0))
    const now = new Set()

    main.querySelectorAll(SECTIONS).forEach((el) => {
      const r = el.getBoundingClientRect()
      const near =
        x > r.left - REACH && x < r.right + REACH && y > r.top - REACH && y < r.bottom + REACH
      if (!near) return
      el.style.setProperty("--gx", `${(x - r.left).toFixed(0)}px`)
      el.style.setProperty("--gy", `${(y - r.top).toFixed(0)}px`)
      el.style.setProperty("--glow-on", "1")
      now.add(el)
    })

    lit.forEach((el) => now.has(el) || el.style.setProperty("--glow-on", "0"))
    lit = now
  }

  const schedule = () => {
    if (frame === null) frame = window.requestAnimationFrame(update)
  }

  document.addEventListener("pointermove", (e) => {
    if (e.pointerType !== "mouse" && e.pointerType !== "pen") return
    pointer = { x: e.clientX, y: e.clientY }
    schedule()
  }, { passive: true })

  // The page moves under a still pointer.
  window.addEventListener("scroll", schedule, { passive: true, capture: true })
  // The pointer left the window.
  document.addEventListener("mouseout", (e) => {
    if (!e.relatedTarget) { pointer = null; schedule() }
  })
  // After LiveView navigation, sections are new elements.
  window.addEventListener("phx:page-loading-stop", schedule)
}
