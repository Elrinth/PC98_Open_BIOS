#!/usr/bin/env python3
"""Measure PC-98 character dimensions from text-mode screenshots.

fontspec/observations.json names each screenshot (by SHA-256) and the text
on it (row, column, string). For every labelled character cell this records
only the inked bounding box and the ink pixel count, keeping the most common
value over all occurrences. No glyph bitmaps are written.

  python tools/measure_metrics.py SCREENSHOT_DIR -o fontspec/observed_metrics.json
"""
import argparse
import collections
import hashlib
import json
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent


def hcode(ch):
    o = ord(ch)
    return o - 0xff61 + 0xa1 if 0xff61 <= o <= 0xff9f else o


def jis(ch):
    b = ch.encode("euc_jp")
    return ((b[0] & 0x7f) << 8) | (b[1] & 0x7f)


def box(im, x0, y0, w):
    ink = [(y, x) for y in range(16) for x in range(w) if im.getpixel((x0 + x, y0 + y)) > 128]
    if not ink:
        return None
    ys = [p[0] for p in ink]
    xs = [p[1] for p in ink]
    return min(ys), max(ys), min(xs), max(xs), len(ink)


def summarize(d, fmt):
    out = {}
    for k, v in sorted(d.items()):
        m = collections.Counter(v).most_common(1)[0][0]
        out[fmt % k] = {"top": m[0], "bottom": m[1], "left": m[2], "right": m[3], "ink": m[4], "samples": len(v)}
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("shots", type=Path, help="directory holding the screenshots (any names)")
    p.add_argument("-o", "--output", type=Path, default=ROOT / "fontspec" / "observed_metrics.json")
    args = p.parse_args()
    obs = json.loads((ROOT / "fontspec" / "observations.json").read_text(encoding="utf-8"))
    by_hash = {hashlib.sha256(f.read_bytes()).hexdigest(): f for f in args.shots.iterdir() if f.is_file()}
    ank, kan = collections.defaultdict(list), collections.defaultdict(list)
    for shot in obs["screenshots"]:
        path = by_hash.get(shot["sha256"])
        if path is None:
            raise SystemExit(f"screenshot {shot['id']} ({shot['sha256'][:12]}...) not found in {args.shots}")
        im = Image.open(path).convert("L")
        for r, c0, text in shot.get("half", []):
            for i, ch in enumerate(text):
                b = box(im, (c0 + i) * 8, r * 16, 8)
                if ch == " ":
                    if b:
                        raise SystemExit(f"{shot['id']}: ink in a space at row {r} column {c0 + i}")
                elif b is None:
                    raise SystemExit(f"{shot['id']}: blank cell for {ch!r} at row {r} column {c0 + i}")
                else:
                    ank[hcode(ch)].append(b)
        for r, c0, text in shot.get("full", []):
            for i, ch in enumerate(text):
                b = box(im, (c0 + 2 * i) * 8, r * 16, 16)
                if b is None:
                    raise SystemExit(f"{shot['id']}: blank cell for {ch!r} at row {r} column {c0 + 2 * i}")
                kan[jis(ch)].append(b)
    spec = {"method": "Measured from 640x400 text-mode screenshots of real PC-98 software output "
                      "(fontspec/observations.json). Per character: inked bounding box rows/columns "
                      "and ink pixel count. No glyph bitmaps are recorded.",
            "ank8x16": summarize(ank, "%02X"), "kanji16": summarize(kan, "%04X")}
    args.output.write_text(json.dumps(spec, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"{args.output}: {len(spec['ank8x16'])} half-width, {len(spec['kanji16'])} full-width characters")
    return 0


if __name__ == "__main__":
    sys.exit(main())
