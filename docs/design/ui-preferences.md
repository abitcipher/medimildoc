# Usability: files, pagination, interface settings

Status: **done** (2026-10-06). The user's usability recommendations.

## 1. SVG and EPS files (People → Files → Add files)

Accepted, recognised from the file's content like every other type
(`App.People.Files`): SVG by its `<svg>` root element after an optional
XML declaration, comments and doctype; EPS by the PostScript header naming
`EPSF` or the binary DOS-EPS header. Plain PostScript is refused.

**Only ever downloaded, never shown in the browser** — files are served
from the app's own domain, and an SVG can carry scripts that would run as
the app; EPS is a PostScript program. Not accepted as portrait photos.

Alternative for later: a PNG preview of SVG rendered on the server
(Typst, already in the image, draws SVG without running scripts). EPS
previews would need Ghostscript, which has a long record of
vulnerabilities on untrusted input — not recommended.

## 2. Page navigation above tables

Cinder (0.17) draws its page navigation only under the table and has no
option to move it. `<.top_pager id=…>` around a `Cinder.collection` adds
the same navigation above the table (hook `PagerTop`): the control is
copied whenever the table changes, and the copied buttons page the table
itself (LiveView handles clicks by delegation; they keep the table's
`phx-target`). The page-size menu stays below only — its push has no
target. Every Cinder table in the app is wrapped; a new one should be too.

## 3. Interface settings (`/interface`, account menu)

Each user's own (`User.ui_preferences`, changed only by that user through
`:update_preferences`), stored in the database so they follow the user to
every browser. Each setting is chosen **separately for narrow screens**
(phones, below the `md` breakpoint, 768 px) **and wide screens**:

| Setting | Choices |
|---|---|
| Edit forms | in the page (default) · in a window (modal) |
| New entry forms | always shown under the list · button above it (default since 2026-10-06) · compact icon button (＋, the name on hover) · in the ⋮ menu |
| Add controls per form | for each form with an add control (organization, position, provider; on the person page assignment, national ID, identity document): follow the general choice ("General: …", default) or its own choice, per screen width |

A "New …" form opened by its button appears as set for edit forms. The
settings page adapts too: on a phone each choice is a full-width row, on a
wide screen a row of segmented buttons; the row for the screen in use is
marked "this screen".

Applies to: organizations, positions, care providers (edit and "New"),
the person page's record form, and the person page's list sections. Later pages use the same components
(`AppWeb.FormPanels.form_panel/1`, `create_actions/1`).

Implementation: one DOM for both widths — the server knows the settings,
not the screen, so each choice becomes Tailwind classes with and without
`md:`. A modal closes with the backdrop, the × button or Escape; focus
moves into an opened form.

## 4. List sections on the person page (2026-10-06)

The user found three always-visible forms on the Identity tab confusing
("Add an identifier", the identity documents list, "Add a document").
Assignments had the same layout. Now each list is a section of one
familiar shape:

- **Header** — title, count, and the add control on the right, where the
  settings put it (button, compact ＋, ⋮ menu, or the form always shown).
- **List** — a table on wide screens, cards (label: value) on phones; no
  sideways scrolling.
- **Row actions** — compact icon buttons (edit ✎, remove 🗑), names on hover
  and for screen readers; the row being edited is highlighted.
- **Forms on demand** — add and edit forms open as the settings say (in
  the page under the list, or in a window), one at a time; × or Escape
  closes them.

Components: `AppWeb.DataList` (`section_header/1`, `data_list/1`,
`row_actions/1`) with `AppWeb.FormPanels`; the person page's sections are
`AppWeb.PersonListSections` (markup only — the events stay in
`AppWeb.PeopleLive.Show`, which also keeps its module fan-out within the
sentrux limit).

**Default changed:** "New" forms now open from a button above the list
(they were always shown). Users who chose a setting keep it.

## 5. Framed sections with a colour glow (2026-10-06)

Every top-level `<section>` in the page body is a framed card (border,
radius, background, padding); nested sections and tab panels stay plain,
and a section's own classes still win (zero-specificity rules in a
cascade layer, `assets/css/app.css` "Content sections").

**Glow:** where the mouse is, the section's border lights up in colour and
a faint spotlight shows inside; the hue shifts with the pointer across the
screen, so the light changes colour as it moves. One pointer listener for
the whole app (`assets/js/section_glow.js`, once per animation frame) sets
CSS variables only on sections near the pointer; the drawing is CSS (a
radial gradient masked to the border ring).

**Can be switched off** — Interface → Sections: frame with glow (default),
frame only, off. No glow on touch screens or when the device asks for
reduced motion.

Ideas from two CodePen pens (public pens are MIT-licensed on CodePen):
"glowy hover effect" (inescodes) and "React Glow Cards – Minimal" (jh3y);
the code here is written for this app, without React.

## 6. Forms in a window (2026-10-06)

Where a form opens "in a window", it is a window: a title bar with
coloured buttons (red closes, green zooms to the full screen and back),
frosted glass over the page, and a short opening animation (none with
reduced motion). Inline forms keep their plain title and ×. Escape and a
click outside still close it.

The idea comes from the user's example "Responsive macOS Style Portfolio"
(ecemgo on CodePen); its README asks not to use it in profit-making
projects without permission, so none of its code is used — only the
general window pattern, written anew. Works in current Chrome, Edge,
Firefox and Safari (backdrop blur with the `-webkit-` prefix for Safari).

### 6.1. Window options (2026-10-06)

Interface → **Windows** (one choice for all screens):

| Setting | Choices (first = default) |
|---|---|
| Window buttons | left, form buttons on the right (macOS-like) · right, form buttons on the left (close button outermost, Windows-like) |
| Save and Cancel | at the end of the form · in the title bar |
| Window frame | colourful gradient · contrast with the theme (dark on light themes, light grey on dark) |

The title bar never scrolls away: a window is a column whose body alone
scrolls. Save in the title bar is outside the form and submits it through
the HTML `form` attribute (`form_panel` `form_id`, `submit_label`); the
form's own button row is marked `form-actions` and hidden only where the
form is a window. The frame is a 1.5 px gradient ring drawn inside the
window's edge (a masked pseudo-element), so it works on the frosted,
translucent background.
