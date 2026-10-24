// A person's own data (docs/design/events-and-person-login.md).
// Payload from AppWeb.MyData: title, generated, lang, rows — each
// [kind, label, value], kind one of title, subtitle, section, record,
// field, blank (the rows of AppWeb.SheetCard).
#let d = json("data.json")
#set document(title: d.title)
#set page(paper: "a4",
  margin: (x: 20mm, top: 18mm, bottom: 18mm),
  footer: context [
    #set text(size: 8pt, fill: luma(90))
    #d.title · #d.generated #h(1fr) #counter(page).display("1 / 1", both: true)
  ])
#set text(font: "Liberation Serif", size: 10.5pt, lang: d.lang)

#for row in d.rows {
  let (kind, label, value) = row
  if kind == "title" {
    text(size: 16pt, weight: "bold", label)
    linebreak()
  } else if kind == "subtitle" {
    text(fill: luma(70), [#label — #value])
    v(3mm)
  } else if kind == "section" {
    v(3mm)
    block(width: 100%, fill: luma(235), inset: (x: 4pt, y: 3pt),
      text(weight: "bold", label))
  } else if kind == "record" {
    v(1.5mm)
    text(size: 9.5pt, weight: "bold", fill: luma(60), label)
    linebreak()
  } else if kind == "field" {
    grid(columns: (45mm, 1fr), column-gutter: 4mm,
      text(fill: luma(70), label), value)
    v(0.5mm)
  }
}
