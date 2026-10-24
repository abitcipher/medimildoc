// PDF version of posibnyk-google-sheets.md: build with ./build-pdf.sh
#let accent = rgb("#ea580c")
#set document(title: "HR Admin у Google Sheets — посібник користувача")
#set text(font: ("Noto Sans", "DejaVu Sans", "Noto Sans Symbols2", "FreeSerif", "Noto Color Emoji"), size: 10.5pt, lang: "uk")
#set par(justify: true, leading: 0.62em)
#set page(
  paper: "a4",
  margin: (x: 2cm, top: 2cm, bottom: 2.2cm),
  footer: context [
    #set text(size: 8.5pt, fill: luma(110))
    HR Admin у Google Sheets — посібник користувача #h(1fr) #counter(page).display()
  ],
)
#set heading(numbering: "1.1")
#show heading.where(level: 1): it => {
  pagebreak(weak: true)
  block(below: 1em)[
    #set text(size: 20pt, fill: accent, weight: "bold")
    #it
  ]
}
#show heading.where(level: 2): it => block(above: 1.4em, below: 0.7em)[
  #set text(size: 13pt, weight: "bold")
  #it
]
#set image(width: 100%)
#show figure: set block(breakable: false)
#set figure(supplement: "Рис.")
#show figure.caption: set text(size: 9pt, fill: luma(90))
#set table(stroke: 0.5pt + luma(200), inset: 6pt, fill: (_, row) => if row == 0 { luma(235) })
#show table.cell.where(y: 0): set text(weight: "bold")
#show table: set text(size: 9.5pt)
#show table: set par(justify: false)

// Title page
#page(footer: none)[
  #v(5cm)
  #text(size: 30pt, weight: "bold", fill: accent)[HR Admin]
  #v(0.3cm)
  #text(size: 18pt)[Застосунок для Google Sheets]
  #v(0.5cm)
  #text(size: 12pt, fill: luma(90))[Бічна панель: можливості, порядок роботи, поради]
  #v(1fr)
  #text(size: 10pt, fill: luma(110))[Жовтень 2026 · знімки екрана зроблено на тестових (синтетичних) даних]
]

#outline(title: [Зміст], depth: 2, indent: auto)

#include "body-sheets.typ"
