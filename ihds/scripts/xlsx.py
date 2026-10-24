"""Minimal .xlsx reader (stdlib only): rows of the first sheet as lists of
strings. Enough for flat official tables such as the KATOTTH codifier."""
import re
import zipfile
import xml.etree.ElementTree as ET

NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}


def _column(ref):
    letters = re.match(r"[A-Z]+", ref).group(0)
    n = 0
    for ch in letters:
        n = n * 26 + ord(ch) - 64
    return n - 1


def rows(path):
    with zipfile.ZipFile(path) as z:
        shared = []
        if "xl/sharedStrings.xml" in z.namelist():
            root = ET.fromstring(z.read("xl/sharedStrings.xml"))
            for si in root.findall("m:si", NS):
                shared.append("".join(t.text or "" for t in si.iter(f"{{{NS['m']}}}t")))
        sheet = ET.fromstring(z.read("xl/worksheets/sheet1.xml"))
        for row in sheet.iter(f"{{{NS['m']}}}row"):
            out = []
            for c in row.findall("m:c", NS):
                i = _column(c.get("r"))
                while len(out) < i:
                    out.append("")
                v = c.find("m:v", NS)
                if c.get("t") == "s" and v is not None:
                    out.append(shared[int(v.text)])
                elif c.get("t") == "inlineStr":
                    out.append("".join(t.text or "" for t in c.iter(f"{{{NS['m']}}}t")))
                else:
                    out.append(v.text if v is not None else "")
            yield [x.strip() for x in out]
