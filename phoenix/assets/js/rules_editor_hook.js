// Mounts the FSDC rule editor (GoRules JDM Editor, built separately into
// /assets/rules_editor/, docs/design/data-consistency.md) on the
// /rules/:key page. The editor bundle is loaded only here, on demand.
//
// Events on the element (sent with JS.dispatch from the page):
//   rules:save      -> pushes "save_graph" with the edited graph
//   rules:simulate  -> pushes "simulate" with the graph and the test context
// From the server:
//   rules:simulation -> the traced result, shown in the editor
export const RulesEditor = {
  async mounted() {
    const css = document.createElement("link")
    css.rel = "stylesheet"
    css.href = this.el.dataset.css
    document.head.append(css)
    this.css = css

    const module = await import(/* external */ this.el.dataset.module)
    this.el.innerHTML = ""
    this.editor = module.mount(this.el, { graph: JSON.parse(this.el.dataset.graph) })

    this.el.addEventListener("rules:save", () =>
      this.pushEvent("save_graph", { graph: this.editor.getGraph() })
    )
    this.el.addEventListener("rules:simulate", () => {
      const context = document.getElementById("simulate-context").value
      this.pushEvent("simulate", { context, graph: this.editor.getGraph() })
    })
    this.handleEvent("rules:simulation", (simulation) => this.editor.setSimulate(simulation))
  },

  destroyed() {
    if (this.editor) this.editor.unmount()
    if (this.css) this.css.remove()
  },
}
