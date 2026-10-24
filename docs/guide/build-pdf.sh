#!/usr/bin/env bash
# Builds the PDF guides from their Markdown (pandoc 3.1+ and typst;
# fonts: Noto Sans, with DejaVu / Noto Symbols / Noto Color Emoji for symbols):
#   posibnyk-korystuvacha.md  → posibnyk-korystuvacha.pdf  (pdf-src/style.typ)
#   posibnyk-google-sheets.md → posibnyk-google-sheets.pdf (pdf-src/style-sheets.typ)
set -euo pipefail
cd "$(dirname "$0")"

build() {
  local md=$1 body=$2 style=$3 pdf=$4
  pandoc "$md" -t typst -o "pdf-src/$body"
  # Pandoc gives tables auto column widths; give text columns room.
  sed -i -e 's/columns: 2,/columns: (30%, 70%),/' -e 's/columns: 3,/columns: (22%, 46%, 32%),/' "pdf-src/$body"
  # Pandoc's quote blocks need a definition (an included file has its own scope).
  sed -i '1i #let blockquote(body) = block(width: 100%, fill: luma(242), stroke: (left: 3pt + rgb("#ea580c")), inset: (x: 10pt, y: 8pt), body)' "pdf-src/$body"
  # Pandoc centres tables with align(center), which centres the cell text
  # too; a plain block keeps it left-aligned.
  sed -i 's/^#align(center)\[#table(/#block[#table(/' "pdf-src/$body"
  # Image paths are relative to the Markdown file.
  sed -i 's#image("img/#image("../img/#' "pdf-src/$body"
  typst compile --root . "pdf-src/$style" "$pdf"
}

build posibnyk-korystuvacha.md body.typ style.typ posibnyk-korystuvacha.pdf
build posibnyk-google-sheets.md body-sheets.typ style-sheets.typ posibnyk-google-sheets.pdf
