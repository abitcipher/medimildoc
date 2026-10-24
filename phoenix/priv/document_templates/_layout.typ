// Shared layout of printed documents (docs/design/documents-core.md):
// A4, margins after ДСТУ 4163 (left 30 mm, right 10 mm, top and bottom
// 20 mm), Liberation Serif (Times-compatible). Reads the print payload
// (App.Documents.Print) passed in by each type's template.

#let official(d) = {
  set document(title: d.title)
  set page(paper: "a4", margin: (left: 30mm, right: 10mm, top: 20mm, bottom: 20mm),
    footer: context [
      #set text(size: 8pt, fill: luma(90))
      #grid(columns: (1fr, auto),
        [SHA-256: #d.at("content_sha256", default: "—")],
        [#counter(page).display("1 / 1", both: true)])
    ])
  set text(font: "Liberation Serif", size: 12pt, lang: "uk")
  set par(justify: false, leading: 0.55em)

  grid(columns: (1fr, auto),
    [],
    align(right)[
      #if d.number != none [№ #strong(d.number)] else [Проєкт]
      #if d.date != none [ від #d.date]
    ])

  v(10mm)
  align(center, text(size: 14pt, weight: "bold", upper(d.title)))
  v(6mm)

  // Letters are about no person (docs/design/correspondence.md).
  let person = d.at("person", default: none)
  table(columns: (60mm, 1fr), stroke: none, inset: (x: 0pt, y: 3pt),
    ..if person != none {
      ([*Прізвище, ім'я, по батькові:*], [#person.name],
       [*Ідентифікатор:*], [#person.at("person_id", default: none)])
    },
    ..if person != none and person.at("birth_date", default: none) != none {
      ([*Дата народження:*], [#person.birth_date])
    },
    ..if d.at("basis", default: none) != none {
      ([*Підстава:*], [#d.basis])
    })

  v(4mm)
  line(length: 100%, stroke: 0.5pt)
  v(2mm)

  table(columns: (60mm, 1fr), stroke: (x, y) => (bottom: 0.3pt + luma(200)),
    inset: (x: 2pt, y: 5pt),
    ..d.rows.map(r => ([#text(weight: "bold", r.label)], [#r.value])).flatten())

  // Certificates: the facts frozen at signing, a section each — label and
  // value rows, or a table when the section has a header.
  for s in d.at("sections", default: ()) {
    v(5mm)
    text(weight: "bold", s.title)
    v(1mm)
    let header = s.at("header", default: none)
    if s.rows.len() == 0 {
      text(fill: luma(80), s.at("empty", default: "—"))
    } else if header == none {
      table(columns: (60mm, 1fr), stroke: (x, y) => (bottom: 0.3pt + luma(200)),
        inset: (x: 2pt, y: 4pt),
        ..s.rows.map(r => ([#r.at(0)], [#r.at(1)])).flatten())
    } else {
      table(columns: header.map(_ => 1fr), stroke: 0.3pt + luma(160),
        inset: (x: 3pt, y: 4pt),
        ..header.map(h => text(weight: "bold", size: 10pt, h)),
        ..s.rows.flatten().map(c => text(size: 10pt, c)))
    }
  }

  v(8mm)
  let approvals = d.route.filter(s => s.action == "approved")
  let signatures = d.route.filter(s => s.action == "signed")

  if approvals.len() > 0 [
    *Погоджено:*
    #table(columns: (60mm, 1fr, 40mm), stroke: none, inset: (x: 0pt, y: 3pt),
      ..approvals.map(s => ([#s.label], [#s.name], [#s.at])).flatten())
  ]

  let registration = d.at("registration", default: false)

  if signatures.len() > 0 [
    #v(4mm)
    #if registration [*Зареєстровано:*] else [*Підписано:*]
    #table(columns: (60mm, 1fr, 40mm), stroke: none, inset: (x: 0pt, y: 3pt),
      ..signatures.map(s => ([#s.label], [#s.name], [#s.at])).flatten())
    #v(2mm)
    #text(size: 9pt, fill: luma(80))[#if registration [Документ зареєстровано в інформаційній системі.] else [Документ підписано в інформаційній системі (внутрішній електронний підпис).] Ідентифікатор: #d.document_id]
  ]

  // The file plan case (docs/design/registers-file-plan.md): "до справи №".
  if d.at("case", default: none) != none [
    #v(6mm)
    До справи № #d.case
  ]
}
