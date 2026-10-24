# ORG-GRAPH — the organisation as an interactive graph

**Task name: `ORG-GRAPH`.** Use this name to come back to the page and
extend it ("ORG-GRAPH: add …"); follow-ups are numbered `ORG-GRAPH.n`
below.

Status: **v1 done** (2026-10-08, user's request: a dedicated page that
shows the whole structure — people, their places, reporting lines and
other connections — with Cytoscape.js).

## What v1 shows

Page `/org-graph` (nav "Org graph", permission `people.read`).

| Node | Shape | From |
|---|---|---|
| Unit | dark rounded box | `Organization` |
| Post | small square; dashed border = vacant places, thick = others report to it | `Position` (`strength` − current holders) |
| Person | dot | current `Assignment` |
| Care provider | diamond | `App.Care.Provider` |
| Place | hexagon | provider's country + locality |

| Edge | Drawn | Direction |
|---|---|---|
| part of | thick | parent unit → sub-unit |
| post in | thin | unit → post |
| holds | thin, person colour | post → person (unit → person when posts are hidden) |
| reports to | dashed, arrow at the superior | superior post → subordinate post |
| deputy | dotted arrow | deputy → the person they stand in for |
| serves | dashed | provider → unit |
| located in | dotted | provider → place |

- **Toolbar:** unit (the whole tree or one unit with everything under
  it), layout, layers (each with its swatch and count), search (highlights
  matches and their neighbours, zooms to them). Unit, layout and layers
  are in the URL, so a view can be shared.
- **Layouts:** *Network* (force-directed, default — best for the whole
  structure), *Hierarchy* (an org chart: unit → its top posts →
  subordinate posts → holders; a post under a superior post is not also
  hung on its unit), *Circles* (rings by type).
- **Interaction:** click a node → details panel (unit: parent, posts,
  people, sub-units; post: unit, grade, strength, vacant, reports to,
  holders; person: posts, deputies, link to the person's page; provider,
  place) — names in the panel select those nodes; double-click zooms to a
  node's neighbourhood; buttons: fit to screen, save as PNG. Colours follow
  the theme (light/dark switch restyles the graph).

## Decisions

- **Cytoscape.js 3.34.3** (MIT, The Cytoscape Consortium), vendored as
  `assets/vendor/cytoscape.esm.min.mjs` (sha512 checked against the npm
  registry; sha256 `c299a4d5…e816`) with its licence. Why: built-in
  layouts, selectors and styles, canvas rendering that holds thousands of
  nodes, no other dependencies. No CDN (the app serves everything itself).
- **Loaded only on this page:** a separate esbuild profile `org_graph`
  builds `js/org_graph.js` as an ES module; the hook `OrgGraph` (in
  `app.js`) imports it by its digested URL (`data-src`). `app.js` doesn't
  grow by ~430 KB. `mix assets.build`/`assets.deploy` and the dev watcher
  build both.
- **Server builds, browser draws:** `App.OrgGraph.Data.load/2` reads as
  the viewer; `App.OrgGraph.elements/2` (pure) turns it into Cytoscape
  elements with typed ids (`u:`, `p:`, `h:`, `c:`, `l:`); the page sends
  them in the reply to the hook's `ready` and on every change
  (`graph:data`), plus `graph:layout`, `graph:highlight`, `graph:select`.
  Details and search are computed on the server (translations stay there).
- **Access:** the same read rules as the rest of the app — units, posts,
  assignments and providers need `people.read`; people the viewer can't
  read are left out (their posts show as vacant); deputies are visible to
  the two people involved and to `users.manage`. Nothing encrypted is
  read, so nothing is written to the access log.
- **Places** are units' and providers' localities (ORG-GRAPH.1).

## Code

- `lib/app/org_graph.ex` — `elements/2`, `layers/0`, `place_id/1`,
  `overlay/3`, `subgraph/3` (pure).
- `lib/app/org_graph/data.ex` — `load/3` (`on:`, `compare:`, `relations:`).
- `lib/app/org_graph/relations.ex` — relation layers (ORG-GRAPH.4).
- `lib/app/org_graph/overlay.ex` — overlays (ORG-GRAPH.6).
- `lib/app_web/live/org_graph_live.ex` — the page.
- `assets/js/org_graph.js` — Cytoscape styles and layouts;
  `assets/js/hooks/org_graph.js` — the hook.
- Tests: `test/app/org_graph_test.exs`, `test/app/org_graph/relations_test.exs`,
  `test/app_web/live/org_graph_live_test.exs`.

To add a relation: a node/edge type in `App.OrgGraph` (a layer name in
`@layers` if it can be toggled), its data in `App.OrgGraph.Data` (read as
the viewer), its style in `org_graph.js`, a label and swatch in the page,
a details clause.

## Follow-ups (ORG-GRAPH.n)

Done 2026-10-09 (1–8):

1. **Unit locations** — `Organization.country`/`locality`/`locality_code`
   (IHDS pickers in the form); units joined to places (`located_in`); a
   unit without its own place inherits its parent's; people's place shown
   through their unit ("Demo City (as A Company)").
2. **Org chart layout** — Hierarchy is a tidy tree computed in
   `org_graph.js` (`orgChart`), no extension: people stacked under their
   post, reporting lines inside a unit, right-angled edges, places last.
3. **Grouping and collapsing** — "Group by unit" (`?group=1`) draws units
   as boxes with their posts and holders (`boxLayout`); double-click or
   the details button collapses a unit's sub-tree ("(+N)"); toolbar
   collapse/expand all; above 400 nodes the graph starts collapsed below
   the top units.
4. **More relations** (`App.OrgGraph.Relations`, loaded only when the
   layer is shown) — on duty together this month, who approves/signs
   whose documents and who acknowledged whose orders (90 days; counted
   edges), referrals to providers and family (dependants) — the last two
   sensitive (lock icon): read as the viewer, referrals written to the
   access log as `org-graph:<type>` (fail closed), dependants through
   their record policy.
5. **As of a date / changes** — `on` (holders and deputies on that date
   from assignment history) and `compare` (who joined a post since —
   green; who left — faded, dashed red; summary badges). Units and posts
   have no history yet and show as they are.
6. **Overlays** (`App.OrgGraph.Overlay`, one at a time, `?overlay=`) —
   readiness (latest fitness-for-duty status, readable records only),
   away on the graph's date (leave, sick leave, business trip —
   `CalendarData.away_types/3`), vacancies per unit with its sub-units
   (shown next to the unit's name); a legend under the toolbar.
7. **Large structures** — above 600 nodes (or `?progressive=1`) the page
   sends units plus the opened units' contents (`OrgGraph.subgraph/3`);
   a unit not opened shows "(+N …)" and opens on double-click or "Show N
   more" (`graph:merge`); a search opens the units of its matches.
8. **Export** — PNG, SVG (the graph's own shapes and colours), GraphML,
   nodes/edges CSV (UTF-8 with BOM) of what is shown; built in the
   browser, no dependency.

Open:

9. **Sheets sidebar** — a compact mode for the narrow sidebar.
