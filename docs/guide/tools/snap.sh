#!/usr/bin/env bash
# snap.sh <out.png> <preset: side|full|grid> — screenshot of the spreadsheet window, cropped.
set -e
d=$(dirname "$0")
node "$d/cdp.mjs" "id:$(cat $d/guidewin.txt)" shot "$d/raw.png" >/dev/null
python3 - "$d/raw.png" "$1" "$2" <<'PY'
import sys
from PIL import Image
raw, out, preset = sys.argv[1:]
im = Image.open(raw)
s = 2  # device pixel ratio
boxes = {
  "side": (1480, 112, 1792, 932),   # the sidebar panel
  "full": (0, 106, 1792, 961),      # grid + sidebar, below Google's menus
  "grid": (0, 106, 1458, 961),      # the grid only
}
x1, y1, x2, y2 = boxes[preset]
im.crop((x1*s, y1*s, x2*s, y2*s)).save(out, optimize=True)
print("saved", out, im.size)
PY
