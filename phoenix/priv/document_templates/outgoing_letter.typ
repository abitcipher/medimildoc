// An outgoing letter on letterhead (docs/design/correspondence.md):
// the sending unit, number and date, the addressee on the right, the
// subject, the text, the signature; margins after ДСТУ 4163 like the
// shared layout. Payload from App.Documents.Print (`letter`).
#let d = json("data.json")
#let l = d.letter
#set document(title: d.title)
#set page(paper: "a4", margin: (left: 30mm, right: 10mm, top: 20mm, bottom: 20mm),
  footer: context [
    #set text(size: 8pt, fill: luma(90))
    #grid(columns: (1fr, auto),
      [SHA-256: #d.at("content_sha256", default: "—")],
      [#counter(page).display("1 / 1", both: true)])
  ])
#set text(font: "Liberation Serif", size: 14pt, lang: "uk")
#set par(justify: true, leading: 0.6em)

#grid(columns: (1fr, 1fr), gutter: 10mm,
  [
    #let unit = l.at("unit", default: none)
    #if unit != none [#text(weight: "bold", upper(unit))]
    #v(3mm)
    #text(size: 12pt)[
      #if d.number != none [№ #d.number] else [Проєкт]
      #if d.date != none [ від #d.date]
    ]
  ],
  [
    #text(weight: "bold", l.at("addressee", default: ""))
    #if l.at("address", default: none) != none [ \ #text(size: 12pt, l.address)]
  ])

#v(10mm)
#if l.at("subject", default: none) != none [
  #text(style: "italic")[Щодо: #l.subject]
  #v(4mm)
]

#for p in l.text.split("\n").filter(p => p.trim() != "") [
  #par(first-line-indent: (amount: 12.5mm, all: true), p)
]

#v(12mm)
#let signatures = d.route.filter(s => s.action == "signed")
#for s in signatures [
  #grid(columns: (1fr, auto), [#s.label], [#s.name])
]

#if d.at("case", default: none) != none [
  #v(6mm)
  #text(size: 10pt)[До справи № #d.case]
]
#v(4mm)
#text(size: 8pt, fill: luma(80))[Документ підписано в інформаційній системі (внутрішній електронний підпис). Ідентифікатор: #d.document_id]
