// Page navigation above a Cinder table as well as below it
// (AppWeb.CoreComponents.top_pager/1). Cinder renders its pagination only
// under the table, so this hook copies that control into a slot above it
// whenever the table re-renders. The copied buttons keep their
// phx-click="goto_page" and phx-target (the table component's id), and
// LiveView handles clicks by delegation, so they page the table exactly as
// the originals do. The page-size menu stays below only: its push has no
// target and would go to the page instead of the table.
//
// Markup: <div phx-hook="PagerTop"> <div data-pager-slot phx-update="ignore">
// </div> <div data-pager-table>…Cinder…</div> </div>
export const PagerTop = {
  mounted() {
    this.slot = this.el.querySelector("[data-pager-slot]")
    this.table = this.el.querySelector("[data-pager-table]")
    this.copy()
    // Cinder's own updates patch inside the component, not this hook's
    // element, so updated() alone would miss them.
    this.observer = new MutationObserver(() => this.copy())
    this.observer.observe(this.table, { childList: true, subtree: true, attributes: true })
  },

  updated() {
    this.copy()
  },

  destroyed() {
    this.observer && this.observer.disconnect()
  },

  copy() {
    const source = this.table.querySelector('[data-key="pagination_wrapper_class"]')
    const html = source ? this.navigation(source) : ""
    // Only when it changed: writing the slot doesn't touch the observed
    // table, but skipping no-op writes keeps focus and avoids flicker.
    if (this.slot.innerHTML !== html) this.slot.innerHTML = html
  },

  navigation(source) {
    const copy = source.cloneNode(true)
    copy.querySelectorAll('[data-key="page_size_container_class"]').forEach((el) => el.remove())
    // No duplicate ids on the page.
    copy.querySelectorAll("[id]").forEach((el) => el.removeAttribute("id"))
    return copy.outerHTML
  },
}
