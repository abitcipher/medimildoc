# Helpers for the guide screenshots (source me).
D=/tmp/claude-1000/-home-claude-sheets-app/b9f4bdc5-1919-4b50-83a2-a247b327827d/scratchpad
W=id:$(cat $D/guidewin.txt)
H=id:$(cat $D/guideside.txt)
cdp() { node $D/cdp.mjs "$@"; }
side() { node $D/cdp.mjs $H eval "$1"; }
cell() { cdp $W click '#t-name-box' >/dev/null; cdp $W type "$1" >/dev/null; cdp $W key Enter >/dev/null; }
tab() { cdp $W click ".docs-sheet-tab|$1" >/dev/null; sleep 2; }
pick() { side "(() => { const s=document.getElementById('dataset-select'); s.value='$1'; s.dispatchEvent(new Event('change',{bubbles:true})); return 'ok' })()" >/dev/null; sleep 3; }
tool() { side "(() => { document.getElementById('tool-data.$1').click(); return 'ok' })()" >/dev/null; }
snap() { $D/snap.sh $D/guide/sheets/$1 $2; }
