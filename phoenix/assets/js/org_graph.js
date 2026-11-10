// The org graph (docs/design/org-graph.md, task ORG-GRAPH): Cytoscape.js
// over the elements the page sends (App.OrgGraph). Built as its own ES
// module (esbuild profile `org_graph`) and imported by the OrgGraph hook
// only on that page — Cytoscape is ~430 KB.
//
// Cytoscape 3.34.3, vendored from npm (sha512 checked against the
// registry), MIT — assets/vendor/cytoscape.LICENSE.
import cytoscape from "../vendor/cytoscape.esm.min.mjs"

// Theme colours: daisyUI defines them in oklch, which Cytoscape can't
// parse — let a canvas turn each into rgb.
const probe = document.createElement("canvas").getContext("2d", { willReadFrequently: true })
const rgb = (name, fallback) => {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  if (!value) return fallback
  probe.clearRect(0, 0, 1, 1)
  probe.fillStyle = fallback
  probe.fillStyle = value
  probe.fillRect(0, 0, 1, 1)
  const [r, g, b] = probe.getImageData(0, 0, 1, 1).data
  return `rgb(${r}, ${g}, ${b})`
}

const palette = () => ({
  text: rgb("--color-base-content", "#1f2937"),
  bg: rgb("--color-base-100", "#ffffff"),
  line: rgb("--color-base-300", "#d1d5db"),
  unit: rgb("--color-neutral", "#374151"),
  unitText: rgb("--color-neutral-content", "#ffffff"),
  post: rgb("--color-base-200", "#f3f4f6"),
  person: rgb("--color-primary", "#2563eb"),
  provider: rgb("--color-info", "#0891b2"),
  place: rgb("--color-success", "#16a34a"),
  accent: rgb("--color-accent", "#db2777"),
  warning: rgb("--color-warning", "#d97706"),
  secondary: rgb("--color-secondary", "#7c3aed"),
  danger: rgb("--color-error", "#dc2626"),
})

const style = (c) => [
  { selector: "node", style: {
    // A collapsed unit shows how much is folded into it (ORG-GRAPH.3).
    // ORG-GRAPH.6: a unit's vacant places when that overlay is on.
    label: (n) => {
      let text = n.data("label")
      if (n.data("folded")) text += ` (+${n.data("folded")})`
      if (n.data("remote")) text += ` (+${n.data("remote")} …)`
      if (n.data("vacant_total")) text += ` · ${n.data("vacant_total")}`
      return text
    }, color: c.text, "font-size": 11, "text-valign": "bottom", "text-margin-y": 4,
    "text-wrap": "ellipsis", "text-max-width": 140, "min-zoomed-font-size": 7,
    // Edges pass behind labels instead of striking names through.
    "text-background-color": c.bg, "text-background-opacity": 1, "text-background-padding": 1,
    "text-background-shape": "roundrectangle",
    "border-width": 1, "border-color": c.line, "background-color": c.post,
  } },
  { selector: "node.unit", style: {
    shape: "round-rectangle", width: 46, height: 30, "background-color": c.unit,
    "font-size": 13, "font-weight": "bold", "border-width": 0,
  } },
  { selector: "node.post", style: { shape: "rectangle", width: 18, height: 18 } },
  { selector: "node.post.leader", style: { "border-width": 3, "border-color": c.secondary } },
  { selector: "node.post.vacant", style: { "border-style": "dashed", "border-width": 2, "border-color": c.warning } },
  { selector: "node.person", style: { shape: "ellipse", width: 16, height: 16, "background-color": c.person, "border-width": 0 } },
  { selector: "node.provider", style: { shape: "diamond", width: 24, height: 24, "background-color": c.provider, "border-width": 0 } },
  { selector: "node.place", style: { shape: "hexagon", width: 26, height: 22, "background-color": c.place, "border-width": 0 } },
  { selector: "edge", style: {
    width: 1, "line-color": c.text, "line-opacity": 0.3, "curve-style": "bezier",
  } },
  { selector: "edge.part_of", style: { width: 3, "line-color": c.unit, opacity: 0.6 } },
  { selector: "edge.holds", style: { "line-color": c.person, "line-opacity": 0.6 } },
  // From the superior post to the subordinate; the arrow points up, to the superior.
  { selector: "edge.reports_to", style: {
    "line-style": "dashed", "line-color": c.secondary, "line-opacity": 0.8, "source-arrow-shape": "triangle",
    "source-arrow-color": c.secondary, "arrow-scale": 0.8,
  } },
  { selector: "edge.deputy", style: {
    "line-style": "dotted", width: 2, "line-color": c.accent, "target-arrow-shape": "vee",
    "target-arrow-color": c.accent,
  } },
  { selector: "edge.serves", style: { "line-style": "dashed", "line-color": c.provider } },
  // Relations (ORG-GRAPH.4); a pair seen several times shows how often.
  { selector: "edge.duty_with", style: { width: 2, "line-color": c.warning, "line-opacity": 0.7 } },
  { selector: "edge.approves", style: { width: 2, "line-color": c.provider, "line-opacity": 0.7, "target-arrow-shape": "triangle", "target-arrow-color": c.provider } },
  { selector: "edge.acknowledged", style: { "line-style": "dashed", "line-color": c.place, "target-arrow-shape": "triangle", "target-arrow-color": c.place } },
  { selector: "edge.referred", style: { "line-style": "dashed", width: 2, "line-color": c.danger, "target-arrow-shape": "triangle", "target-arrow-color": c.danger } },
  { selector: "edge.family", style: { "line-color": c.accent, "line-opacity": 0.7 } },
  { selector: "edge[count > 1]", style: { label: "data(count)", "font-size": 9, color: c.text, "text-background-color": c.bg, "text-background-opacity": 1, "text-background-padding": 1 } },
  // Overlays (ORG-GRAPH.6): readiness, away on the date, vacancies.
  { selector: "node.person.ov-none", style: { "background-color": c.line } },
  { selector: "node.person.ov-fit_for_duty", style: { "background-color": c.place } },
  { selector: "node.person.ov-downgraded", style: { "background-color": c.warning } },
  { selector: "node.person.ov-non_effective", style: { "background-color": c.danger } },
  { selector: "node.person.ov-away", style: { "background-color": c.warning, width: 20, height: 20 } },
  { selector: "node.person.ov-sick", style: { "background-color": c.danger } },
  { selector: "node.person.ov-trip", style: { "background-color": c.provider } },
  { selector: "node.unit.has-vacancies", style: { color: c.danger, "font-weight": "bold" } },
  // Changes between two dates (ORG-GRAPH.5).
  { selector: "node.person.joined", style: { "border-width": 3, "border-color": c.place } },
  { selector: "edge.holds.joined", style: { "line-color": c.place, width: 2, "line-opacity": 0.9 } },
  { selector: "node.person.left", style: { "background-color": c.bg, "border-width": 2, "border-style": "dashed", "border-color": c.danger, "text-opacity": 0.6 } },
  { selector: "edge.holds.left", style: { "line-style": "dashed", "line-color": c.danger, "line-opacity": 0.6 } },
  { selector: "node.relative", style: { shape: "ellipse", width: 12, height: 12, "background-color": c.bg, "border-width": 2, "border-color": c.accent } },
  { selector: "edge.located_in", style: { "line-style": "dotted", "line-color": c.place } },
  // The org chart (Hierarchy, ORG-GRAPH.2): right-angled tree edges;
  // a post's holders listed under it with their names to the right.
  { selector: "edge.chart", style: { "curve-style": "taxi", "taxi-direction": "downward", "taxi-turn": 24 } },
  { selector: "edge.chart-hidden", style: { display: "none" } },
  { selector: "node.post.carded", style: {
    "text-halign": "right", "text-valign": "center", "text-margin-x": 6, "text-margin-y": 0, "font-weight": "bold",
  } },
  // Grouping and collapsing (ORG-GRAPH.3).
  { selector: ".folded-away, .grouped-hidden", style: { display: "none" } },
  // Not opened yet (ORG-GRAPH.7): its contents are on the server.
  { selector: "node.unit.remote", style: { "border-width": 2, "border-style": "dashed", "border-color": c.secondary } },
  { selector: "node.unit.collapsed", style: { "border-width": 3, "border-style": "double", "border-color": c.accent } },
  { selector: "node.unit:parent", style: {
    shape: "round-rectangle", "background-color": c.unit, "background-opacity": 0.07, "border-width": 1,
    "border-color": c.unit, color: c.text, "text-valign": "top", "text-margin-y": -4, padding: 14,
  } },
  { selector: "node.person.stacked", style: {
    "text-halign": "right", "text-valign": "center", "text-margin-x": 6, "text-margin-y": 0, "text-max-width": 120,
  } },
  { selector: ".faded", style: { opacity: 0.12, "text-opacity": 0 } },
  { selector: "node.match", style: { "border-width": 4, "border-color": c.accent, "font-weight": "bold" } },
  { selector: "node:selected", style: { "border-width": 4, "border-color": c.accent } },
]

// --- The org chart (ORG-GRAPH.2) ---------------------------------------
// A tidy tree, no extra library: every node hangs under one parent
// (unit → sub-unit, unit → its top posts, superior post → subordinate,
// post → holders, unit → its care providers); a subtree is as wide as its
// children side by side; a post's holders are stacked in up to three
// columns under it (labels to the right) instead of one long row. Places
// go in a last row. Positions are preset; the tree edges get right angles.
const SLOT = 150, LEVEL = 90, PERSON_W = 150, PERSON_H = 22, MAX_COLS = 3

const chartParent = (cy) => {
  const parent = new Map()
  const take = (selector, from, keep = () => true) => cy.edges(selector).forEach((e) => {
    const child = from === "target" ? e.target() : e.source()
    const up = from === "target" ? e.source() : e.target()
    // Folded away under a collapsed unit: not in the chart.
    if (child.hasClass("folded-away") || up.hasClass("folded-away")) return
    if (!parent.has(child.id()) && keep(e)) parent.set(child.id(), { node: up, edge: e })
  })
  // A post hangs under its superior only inside the same unit; otherwise
  // under its unit (a company commander under the company, not under the
  // battalion commander) — the reporting line then crosses as a dashed edge.
  const unitOf = new Map()
  cy.edges("edge.post_in").forEach((e) => unitOf.set(e.target().id(), e.source().id()))
  take("edge.reports_to:visible", "target", (e) => unitOf.get(e.source().id()) === unitOf.get(e.target().id()))
  take("edge.part_of:visible", "target")
  take("edge.post_in:visible", "target")
  take("edge.holds:visible", "target")
  take("edge.serves:visible", "source") // provider → unit: the provider hangs under the unit
  return parent
}

const orgChart = (cy) => {
  const parent = chartParent(cy)
  const children = new Map()
  parent.forEach(({ node: up }, id) => {
    if (!children.has(up.id())) children.set(up.id(), [])
    children.get(up.id()).push(cy.getElementById(id))
  })
  const kids = (n) => (children.get(n.id()) || []).sort((a, b) => a.data("label").localeCompare(b.data("label")))
  const leafPerson = (n) => n.data("type") === "person" && !children.has(n.id())
  const split = (n) => {
    const all = kids(n)
    return { people: all.filter(leafPerson), rest: all.filter((c) => !leafPerson(c)) }
  }
  const cols = (count) => Math.min(MAX_COLS, Math.max(1, Math.ceil(count / 8)))
  const block = (count) => count === 0
    ? { w: 0, h: 0 }
    : { w: cols(count) * PERSON_W, h: Math.ceil(count / cols(count)) * PERSON_H + 16 }

  const width = new Map()
  const measure = (n) => {
    const { people, rest } = split(n)
    const restW = rest.reduce((sum, c) => sum + measure(c), 0)
    const w = Math.max(SLOT, block(people.length).w, restW)
    width.set(n.id(), w)
    return w
  }

  const positions = {}
  let bottom = 0
  const place = (n, left, y) => {
    const w = width.get(n.id())
    const cx = left + w / 2
    positions[n.id()] = { x: cx, y }
    bottom = Math.max(bottom, y)
    const { people, rest } = split(n)
    const b = block(people.length)
    people.forEach((p, i) => {
      const c = cols(people.length), row = Math.floor(i / c), col = i % c
      // Dots at the left of each column, names to the right.
      positions[p.id()] = { x: cx - b.w / 2 + col * PERSON_W + 10, y: y + 34 + row * PERSON_H }
      p.addClass("stacked")
      bottom = Math.max(bottom, positions[p.id()].y)
    })
    let x = left + (w - rest.reduce((s, c) => s + width.get(c.id()), 0)) / 2
    rest.forEach((c) => { place(c, x, y + LEVEL + b.h); x += width.get(c.id()) })
  }

  const inTree = cy.nodes(":visible").filter((n) => n.data("type") !== "place")
  const roots = inTree.filter((n) => !parent.has(n.id()))
    .sort((a, b) => (a.data("type") === "unit" ? -1 : 1) - (b.data("type") === "unit" ? -1 : 1))
  let left = 0
  roots.forEach((r) => { measure(r); place(r, left, 0); left += width.get(r.id()) + SLOT / 2 })

  // Places: a row under everything.
  const places = cy.nodes(".place:visible")
  places.forEach((n, i) => { positions[n.id()] = { x: i * SLOT, y: bottom + LEVEL * 1.5 } })

  parent.forEach(({ edge }) => edge.addClass("chart"))
  // "Post in" edges of posts that hang under their superior: redundant here.
  cy.edges("edge.post_in").filter((e) => !e.hasClass("chart")).addClass("chart-hidden")
  return positions
}

// --- Grouping and collapsing (ORG-GRAPH.3) -------------------------------
// What lies under a unit in the structure: its sub-units, their posts,
// the holders, the care providers attached to them.
const below = (unit) => {
  const seen = new Set([unit.id()])
  const out = []
  const queue = [unit]
  while (queue.length) {
    const n = queue.shift()
    const next = n.outgoers("edge.part_of, edge.post_in, edge.holds").targets()
      .union(n.incomers("edge.serves").sources())
    next.forEach((m) => {
      if (seen.has(m.id())) return
      seen.add(m.id()); out.push(m); queue.push(m)
    })
  }
  return out
}

// Units nested by "part of", posts in their unit, holders in their post's
// unit — as compound boxes (Network and Circles).
const group = (cy, on) => {
  cy.batch(() => {
    cy.nodes().forEach((n) => { if (n.parent().nonempty()) n.move({ parent: null }) })
    cy.edges().removeClass("grouped-hidden")
    if (!on) return
    const parentOf = new Map()
    cy.edges("edge.part_of").forEach((e) => parentOf.set(e.target().id(), e.source().id()))
    cy.edges("edge.post_in").forEach((e) => parentOf.set(e.target().id(), e.source().id()))
    cy.edges("edge.holds").forEach((e) => {
      const up = e.source()
      const unit = up.data("type") === "unit" ? up.id() : parentOf.get(up.id())
      if (unit && !parentOf.has(e.target().id())) parentOf.set(e.target().id(), unit)
    })
    // Parents first, so a sub-unit moves into an already placed unit.
    const depth = (id) => (parentOf.has(id) ? 1 + depth(parentOf.get(id)) : 0)
    ;[...parentOf.keys()].sort((a, b) => depth(a) - depth(b)).forEach((id) => {
      const node = cy.getElementById(id)
      if (node.nonempty()) node.move({ parent: parentOf.get(id) })
    })
    cy.edges("edge.part_of, edge.post_in").addClass("grouped-hidden")
  })
}

// Grouped by unit: nested boxes, packed — a unit's posts as small cards
// (the post with its holders under it) in rows, its sub-units' boxes in
// rows below. Force layouts overlap nested boxes; this doesn't.
const CARD_W = 170, ROW_H = 18, GAP = 30
const boxLayout = (cy) => {
  const positions = {}
  const visible = (c) => c.filter((n) => !n.hasClass("folded-away"))
  const card = (post) => {
    const holders = visible(post.outgoers("edge.holds").targets())
    return { post, holders, w: CARD_W, h: 30 + holders.length * ROW_H }
  }
  // Rows of items no wider than `limit`.
  const pack = (items, limit) => {
    let x = 0, y = 0, rowH = 0, width = 0
    const placed = items.map((it) => {
      if (x > 0 && x + it.w > limit) { x = 0; y += rowH + GAP; rowH = 0 }
      const at = { it, x, y }
      x += it.w + GAP; rowH = Math.max(rowH, it.h); width = Math.max(width, x - GAP)
      return at
    })
    return { placed, w: width, h: items.length ? y + rowH : 0 }
  }
  const measure = (unit) => {
    const posts = visible(unit.children(".post")).sort((a, b) => a.data("label").localeCompare(b.data("label")))
    const others = visible(unit.children()).filter((n) => !n.isParent() && n.data("type") !== "post" && n.data("type") !== "person")
    const subs = visible(unit.children()).filter((n) => n.isParent() || n.data("type") === "unit")
    const cards = [...posts.map(card), ...others.map((n) => ({ node: n, w: CARD_W, h: 30 }))]
    const boxes = subs.map(measure)
    const limit = Math.max(3 * (CARD_W + GAP), Math.sqrt(cards.length) * (CARD_W + GAP) * 1.4)
    const top = pack(cards, limit)
    // Sub-unit boxes in a near-square grid.
    const perRow = Math.ceil(Math.sqrt(boxes.length))
    const widest = Math.max(0, ...boxes.map((b) => b.w))
    const bottom = pack(boxes, Math.max(limit, top.w, perRow * (widest + GAP)))
    const w = Math.max(top.w, bottom.w, CARD_W)
    const h = top.h + (boxes.length ? GAP * 1.5 + bottom.h : 0)
    return { unit, top, bottom, w: w + 40, h: h + 60 }
  }
  const place = (box, x0, y0) => {
    const x = x0 + 20, y = y0 + 40
    if (!box.unit.isParent()) positions[box.unit.id()] = { x: x0 + box.w / 2, y: y0 + box.h / 2 }
    box.top.placed.forEach(({ it, x: cx, y: cy0 }) => {
      if (it.node) { positions[it.node.id()] = { x: x + cx + 10, y: y + cy0 } ; return }
      positions[it.post.id()] = { x: x + cx + 10, y: y + cy0 }
      it.post.addClass("carded")
      it.holders.forEach((h, i) => {
        if (!positions[h.id()]) positions[h.id()] = { x: x + cx + 18, y: y + cy0 + 26 + i * ROW_H }
        h.addClass("stacked")
      })
    })
    const below = y + box.top.h + (box.top.h ? GAP * 1.5 : 0)
    box.bottom.placed.forEach(({ it, x: bx, y: by }) => place(it, x + bx, below + by))
  }
  const roots = cy.nodes(".unit").filter((n) => n.parent().empty() && !n.hasClass("folded-away"))
  let left = 0
  roots.forEach((r) => { const b = measure(r); place(b, left, 0); left += b.w + GAP * 2 })
  // Whatever is outside every unit (providers, places): a row underneath.
  let x = 0
  const maxY = Math.max(0, ...Object.values(positions).map((p) => p.y))
  cy.nodes().filter((n) => !positions[n.id()] && !n.isParent() && !n.hasClass("folded-away")).forEach((n) => {
    positions[n.id()] = { x, y: maxY + 120 }; x += CARD_W
  })
  return positions
}

// Concentric rings: units in the middle, places outside.
const ring = { unit: 5, post: 4, person: 3, provider: 2, place: 1 }

const layouts = {
  // An org chart: down the edges (unit → its top posts → subordinate posts
  // → holders); a post under a superior post isn't also hung on its unit.
  hierarchy: (cy) => {
    const positions = orgChart(cy)
    return { name: "preset", positions: (n) => positions[n.id()] || { x: 0, y: 0 }, padding: 20, animate: false }
  },
  network: () => ({ name: "cose", animate: false, padding: 20, nodeRepulsion: () => 9000, idealEdgeLength: () => 60, randomize: true }),
  circles: () => ({ name: "concentric", concentric: (n) => ring[n.data("type")] || 0, levelWidth: () => 1, minNodeSpacing: 12, padding: 20, animate: false }),
}

// --- Export (ORG-GRAPH.8): what is shown, as SVG, GraphML or CSV --------
const xml = (s) => String(s ?? "").replace(/[<>&"']/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;", "'": "&apos;" })[c])
const csvCell = (s) => { const v = String(s ?? ""); return /[",\n;]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v }
const shown = (cy) => cy.elements(":visible")

// Nodes as their shape, edges as lines (right-angled in the org chart),
// labels as text — the graph's own colours, no rasterising.
const toSvg = (cy, bg) => {
  const els = shown(cy)
  const bb = els.boundingBox({ includeLabels: true })
  const pad = 20
  const X = (x) => (x - bb.x1 + pad).toFixed(1), Y = (y) => (y - bb.y1 + pad).toFixed(1)
  // Text may run wider in the SVG's font than on the canvas: widen to fit.
  let right = bb.x2
  const out = []
  els.edges().forEach((e) => {
    const s = e.source().position(), t = e.target().position()
    const stroke = e.style("line-color"), width = parseFloat(e.style("width")) || 1
    const dash = e.style("line-style") === "dashed" ? ' stroke-dasharray="6 4"' : e.style("line-style") === "dotted" ? ' stroke-dasharray="2 3"' : ""
    const opacity = e.style("line-opacity") ?? 1
    const points = e.hasClass("chart")
      ? [[s.x, s.y], [s.x, (s.y + t.y) / 2], [t.x, (s.y + t.y) / 2], [t.x, t.y]]
      : [[s.x, s.y], [t.x, t.y]]
    out.push(`<polyline fill="none" stroke="${stroke}" stroke-width="${width}" stroke-opacity="${opacity}"${dash} points="${points.map(([x, y]) => `${X(x)},${Y(y)}`).join(" ")}"/>`)
  })
  els.nodes().forEach((n) => {
    const p = n.position(), w2 = n.width() / 2, h2 = n.height() / 2
    const fill = n.style("background-color"), stroke = n.style("border-color"), sw = parseFloat(n.style("border-width")) || 0
    const common = `fill="${fill}" fill-opacity="${n.isParent() ? 0.07 : 1}" stroke="${stroke}" stroke-width="${sw}"`
    const shape = n.style("shape")
    if (shape === "ellipse") out.push(`<ellipse cx="${X(p.x)}" cy="${Y(p.y)}" rx="${w2}" ry="${h2}" ${common}/>`)
    else if (shape === "diamond") out.push(`<polygon points="${X(p.x)},${Y(p.y - h2)} ${X(p.x + w2)},${Y(p.y)} ${X(p.x)},${Y(p.y + h2)} ${X(p.x - w2)},${Y(p.y)}" ${common}/>`)
    else out.push(`<rect x="${X(p.x - w2)}" y="${Y(p.y - h2)}" width="${(2 * w2).toFixed(1)}" height="${(2 * h2).toFixed(1)}" rx="${shape === "round-rectangle" ? 6 : 0}" ${common}/>`)
    const label = n.style("label")
    if (!label) return
    const toRight = n.style("text-halign") === "right", top = n.style("text-valign") === "top"
    const size = parseFloat(n.style("font-size")) || 11
    const tx = toRight ? p.x + w2 + 6 : p.x
    right = Math.max(right, tx + label.length * size * (toRight ? 0.6 : 0.3))
    const ty = toRight ? p.y + 4 : top ? p.y - h2 - 6 : p.y + h2 + 13
    out.push(`<text x="${X(tx)}" y="${Y(ty)}" font-size="${size}" text-anchor="${toRight ? "start" : "middle"}" fill="${n.style("color")}">${xml(label)}</text>`)
  })
  const w = (right - bb.x1 + 2 * pad).toFixed(0), h = (bb.h + 2 * pad).toFixed(0)
  return [`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" font-family="sans-serif">`,
    `<rect width="100%" height="100%" fill="${bg}"/>`, ...out, "</svg>"].join("\n")
}

const toGraphml = (cy) => {
  const els = shown(cy)
  const lines = ['<?xml version="1.0" encoding="UTF-8"?>',
    '<graphml xmlns="http://graphml.graphdrawing.org/xmlns">',
    '<key id="label" for="node" attr.name="label" attr.type="string"/>',
    '<key id="type" for="all" attr.name="type" attr.type="string"/>',
    '<key id="count" for="edge" attr.name="count" attr.type="int"/>',
    '<graph id="org-graph" edgedefault="directed">']
  els.nodes().forEach((n) => lines.push(`<node id="${xml(n.id())}"><data key="label">${xml(n.data("label"))}</data><data key="type">${xml(n.data("type"))}</data></node>`))
  els.edges().forEach((e) => lines.push(`<edge source="${xml(e.data("source"))}" target="${xml(e.data("target"))}"><data key="type">${xml(e.data("type"))}</data>${e.data("count") ? `<data key="count">${e.data("count")}</data>` : ""}</edge>`))
  lines.push("</graph>", "</graphml>")
  return lines.join("\n")
}

const toCsv = (cy, kind) => {
  const els = shown(cy)
  const rows = kind === "nodes"
    ? [["id", "type", "label"], ...els.nodes().map((n) => [n.id(), n.data("type"), n.data("label")])]
    : [["source", "target", "type", "count"], ...els.edges().map((e) => [e.data("source"), e.data("target"), e.data("type"), e.data("count") ?? ""])]
  // A BOM so spreadsheet programs read the names as UTF-8.
  return "\ufeff" + rows.map((r) => r.map(csvCell).join(",")).join("\r\n")
}

export function createGraph(container, { onSelect, onExpand }) {
  const cy = cytoscape({
    container, style: style(palette()), wheelSensitivity: 0.3, minZoom: 0.05, maxZoom: 4,
    boxSelectionEnabled: false,
  })
  let current = "hierarchy"
  let grouped = false
  const collapsed = new Set()

  // Hide what lies under collapsed units; a unit shows the count.
  const refold = () => {
    cy.batch(() => {
      cy.nodes().removeClass("folded-away").forEach((n) => n.removeData("folded"))
      cy.nodes(".unit").removeClass("collapsed")
      collapsed.forEach((id) => {
        const unit = cy.getElementById(id)
        if (unit.empty() || unit.hasClass("folded-away")) return
        const hidden = below(unit)
        hidden.forEach((n) => n.addClass("folded-away"))
        unit.addClass("collapsed").data("folded", hidden.length)
      })
    })
  }

  const clear = () => cy.elements().removeClass("faded match")
  const focus = (node) => {
    const near = node.closedNeighborhood()
    cy.elements().addClass("faded")
    near.removeClass("faded")
  }

  cy.on("tap", "node", (e) => { clear(); focus(e.target); onSelect(e.target.id()) })
  cy.on("tap", (e) => { if (e.target === cy) { clear(); onSelect(null) } })
  // Double-click: a unit folds or unfolds; anything else is zoomed to.
  cy.on("dbltap", "node", (e) => {
    const n = e.target
    // A unit whose contents are still on the server: fetch them.
    if (n.hasClass("remote")) return onExpand && onExpand(n.id())
    if (n.data("type") === "unit" && below(n).length > 0) return toggle(n.id())
    cy.animate({ fit: { eles: n.closedNeighborhood(), padding: 40 } }, { duration: 300 })
  })

  // The theme switch (HeaderControls) changes <html data-theme>.
  const themes = new MutationObserver(() => cy.style(style(palette())))
  themes.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme", "class"] })

  const run = (name) => {
    current = layouts[name] ? name : "network"
    cy.elements().removeClass("chart chart-hidden stacked carded")
    // The org chart is a tree already; boxes are for the other layouts.
    group(cy, grouped && current !== "hierarchy")
    const boxed = grouped && current !== "hierarchy"
    const { eles, ...options } = boxed
      ? (() => { const positions = boxLayout(cy); return { name: "preset", positions: (n) => positions[n.id()], padding: 20, animate: false } })()
      : layouts[current](cy)
    ;(eles || cy.elements()).filter(":visible").layout(options).run()
    cy.fit(cy.elements(":visible"), 20)
  }

  const toggle = (id) => {
    collapsed.has(id) ? collapsed.delete(id) : collapsed.add(id)
    refold()
    run(current)
  }

  // A big structure starts with every unit below the top level collapsed.
  const LARGE = 400
  const collapseBelowTop = () => {
    collapsed.clear()
    cy.nodes(".unit").forEach((u) => { if (u.incomers("edge.part_of").nonempty()) collapsed.add(u.id()) })
  }

  return {
    setData(elements, layout, options = {}) {
      grouped = !!options.group
      cy.elements().remove()
      cy.add(elements)
      if (cy.nodes().length > LARGE) collapseBelowTop()
      else [...collapsed].forEach((id) => { if (cy.getElementById(id).empty()) collapsed.delete(id) })
      refold()
      run(layout)
    },
    view(layout, group) { grouped = !!group; run(layout) },
    // ORG-GRAPH.7: a new sub-graph — add what is new, drop what went,
    // refresh what changed (a unit's waiting count), then lay out again.
    merge(elements) {
      const ids = new Set(elements.map((el) => el.data.id))
      cy.batch(() => {
        cy.elements().filter((el) => !ids.has(el.id())).remove()
        const fresh = elements.filter((el) => {
          const old = cy.getElementById(el.data.id)
          if (old.empty()) return true
          old.data(el.data)
          if (!el.data.remote) old.removeData("remote")
          old.classes(el.classes)
          return false
        })
        // Nodes before edges.
        cy.add(fresh.filter((el) => !el.data.source))
        cy.add(fresh.filter((el) => el.data.source))
      })
      refold()
      run(current)
    },
    toggle,
    collapseAll() { collapseBelowTop(); refold(); run(current) },
    expandAll() { collapsed.clear(); refold(); run(current) },
    layout: run,
    highlight(ids) {
      clear()
      if (!ids || ids.length === 0) return
      const found = cy.collection(ids.map((id) => cy.getElementById(id)).filter((n) => n.nonempty()))
      if (found.empty()) return
      cy.elements().addClass("faded")
      found.closedNeighborhood().removeClass("faded")
      found.addClass("match")
      cy.animate({ fit: { eles: found.closedNeighborhood(), padding: 60 } }, { duration: 300 })
    },
    select(id) {
      const node = id && cy.getElementById(id)
      if (!node || node.empty()) return
      clear(); focus(node)
      cy.animate({ fit: { eles: node.closedNeighborhood(), padding: 60 } }, { duration: 300 })
    },
    fit() { clear(); cy.animate({ fit: { padding: 20 } }, { duration: 300 }) },
    png() {
      return cy.png({ full: true, scale: 2, bg: palette().bg })
    },
    svg: () => toSvg(cy, palette().bg),
    graphml: () => toGraphml(cy),
    csv: (kind) => toCsv(cy, kind),
    destroy() { themes.disconnect(); cy.destroy() },
  }
}
