// The org graph page (AppWeb.OrgGraphLive, docs/design/org-graph.md, task
// ORG-GRAPH). Cytoscape comes as a separate module (data-src, built by the
// esbuild profile `org_graph`), loaded only here. The server sends the
// elements and what to highlight; a click on a node goes back as "select".
//
// Markup: <div phx-hook="OrgGraph" data-src=…> <div data-graph-canvas
// phx-update="ignore"></div> buttons with data-graph-action="fit|png" </div>
export const OrgGraph = {
  mounted() {
    this.graph = import(this.el.dataset.src).then(({ createGraph }) => {
      const canvas = this.el.querySelector("[data-graph-canvas]")
      const graph = createGraph(canvas, {
        onSelect: (id) => this.pushEvent("select", { id }),
        onExpand: (id) => this.pushEvent("expand", { id }),
      })
      this.pushEvent("ready", {}, (reply) => graph.setData(reply.elements, reply.layout, { group: reply.group }))
      return graph
    })

    this.handleEvent("graph:data", ({ elements, layout, group }) => this.graph.then((g) => g.setData(elements, layout, { group })))
    this.handleEvent("graph:layout", ({ layout, group }) => this.graph.then((g) => g.view(layout, group)))
    this.handleEvent("graph:toggle", ({ id }) => this.graph.then((g) => g.toggle(id)))
    this.handleEvent("graph:merge", ({ elements }) => this.graph.then((g) => g.merge(elements)))
    this.handleEvent("graph:highlight", ({ ids }) => this.graph.then((g) => g.highlight(ids)))
    this.handleEvent("graph:select", ({ id }) => this.graph.then((g) => g.select(id)))

    this.onClick = (e) => {
      const button = e.target.closest("[data-graph-action]")
      if (!button || !this.el.contains(button)) return
      this.graph.then((g) => {
        if (button.dataset.graphAction === "fit") g.fit()
        if (button.dataset.graphAction === "collapse") g.collapseAll()
        if (button.dataset.graphAction === "expand") g.expandAll()
        // ORG-GRAPH.8: what is shown, in several formats.
        const save = (href, name) => {
          const link = document.createElement("a")
          link.href = href
          link.download = name
          link.click()
          if (href.startsWith("blob:")) setTimeout(() => URL.revokeObjectURL(href), 1000)
        }
        const blob = (text, type) => URL.createObjectURL(new Blob([text], { type }))
        button.closest("details")?.removeAttribute("open")
        const action = button.dataset.graphAction
        if (action === "png") save(g.png(), "org-graph.png")
        if (action === "svg") save(blob(g.svg(), "image/svg+xml"), "org-graph.svg")
        if (action === "graphml") save(blob(g.graphml(), "application/xml"), "org-graph.graphml")
        if (action === "csv-nodes") save(blob(g.csv("nodes"), "text/csv"), "org-graph-nodes.csv")
        if (action === "csv-edges") save(blob(g.csv("edges"), "text/csv"), "org-graph-edges.csv")
      })
    }
    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    this.graph && this.graph.then((g) => g.destroy())
  },
}
