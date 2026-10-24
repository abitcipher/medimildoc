// The inventory of cases (опис справ) of a year and retention class
// (docs/design/registers-file-plan.md §Closing). Payload from
// App.Records.Inventory: title, year, kind, rows, total.
#let d = json("data.json")
#set document(title: d.title)
#set page(paper: "a4", flipped: true,
  margin: (left: 25mm, right: 10mm, top: 15mm, bottom: 15mm),
  footer: context [
    #set text(size: 8pt, fill: luma(90))
    #align(right, counter(page).display("1 / 1", both: true))
  ])
#set text(font: "Liberation Serif", size: 11pt, lang: "uk")

#align(center)[
  #text(size: 13pt, weight: "bold", upper[Опис справ #d.kind])
  #v(1mm)
  за #d.year рік
]
#v(4mm)

#table(
  columns: (12mm, 22mm, 1fr, 26mm, 26mm, 22mm, 30mm, 40mm),
  stroke: 0.4pt + luma(120),
  inset: (x: 3pt, y: 4pt),
  align: (center, center, left, center, center, center, center, left),
  table.header(
    [*№ з/п*], [*Індекс справи*], [*Заголовок справи*], [*Дата першого документа*],
    [*Дата останнього документа*], [*Кількість документів*], [*Строк зберігання*],
    [*Примітки*],
  ),
  ..d.rows.map(r => (
    [#r.n], [#r.index], [#r.title], [#r.first], [#r.last], [#r.documents],
    [#r.retention], [#r.note],
  )).flatten(),
)

#v(6mm)
У цей опис внесено #d.total справ.
#v(10mm)
#grid(columns: (1fr, 1fr), gutter: 10mm,
  [Укладач опису \ #v(8mm) #line(length: 70%, stroke: 0.4pt)],
  [Сформовано #d.generated])
