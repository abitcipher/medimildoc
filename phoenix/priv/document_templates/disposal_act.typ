// The act of selecting cases for disposal (акт про вилучення для знищення
// документів, docs/design/registers-file-plan.md §Closing): the closed cases
// whose retention period has ended. Payload from App.Records.DisposalAct.
#let d = json("data.json")
#set document(title: d.title)
#set page(paper: "a4",
  margin: (left: 30mm, right: 10mm, top: 20mm, bottom: 20mm),
  footer: context [
    #set text(size: 8pt, fill: luma(90))
    #align(right, counter(page).display("1 / 1", both: true))
  ])
#set text(font: "Liberation Serif", size: 12pt, lang: "uk")

#align(center)[
  #text(size: 13pt, weight: "bold", upper[Акт])
  #v(1mm)
  про вилучення для знищення документів, не внесених до Національного архівного фонду
  #v(1mm)
  від #d.generated
]
#v(4mm)
На підставі номенклатури справ відібрано до знищення як такі, що не мають
культурної цінності та втратили практичне значення, документи:
#v(3mm)

#table(
  columns: (10mm, 20mm, 1fr, 16mm, 24mm, 30mm),
  stroke: 0.4pt + luma(120),
  inset: (x: 3pt, y: 4pt),
  align: (center, center, left, center, center, center),
  table.header(
    [*№ з/п*], [*Індекс справи*], [*Заголовок справи*], [*Рік*],
    [*Кількість документів*], [*Строк зберігання*],
  ),
  ..d.rows.map(r => ([#r.n], [#r.index], [#r.title], [#r.year], [#r.documents], [#r.retention])).flatten(),
)

#v(4mm)
Разом #d.total справ.
#v(12mm)
#grid(columns: (1fr, 1fr), gutter: 10mm,
  [Відповідальний за діловодство \ #v(8mm) #line(length: 70%, stroke: 0.4pt)],
  [Погоджено експертною комісією \ #v(8mm) #line(length: 70%, stroke: 0.4pt)])
