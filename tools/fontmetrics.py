#!/usr/bin/env python3
"""Fit the free font's 8x16 ANK glyphs to observed PC-98 character metrics.

fontspec/observed_metrics.json records, per character, only the inked
bounding box (rows and columns) measured on screenshots of real PC-98 text
output; see fontspec/README.md. No glyph bitmaps are taken from anywhere but
the free font itself. Each glyph keeps its own shape: it is fitted into the
observed box by merging (or, when growing, repeating) its most similar
adjacent rows and columns, then placed there. Characters without a
measurement use the box mapping learned from the measured ones.

Only the 8x16 ANK set (and the 8x8 set derived from it) changes. The
2-byte half-width rows 09h/0Ah keep their full-height glyphs.

  python tools/fontmetrics.py font/pc98font.rom -o build/font_fitted.rom
"""
import argparse
import collections
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = ROOT / "fontspec" / "observed_metrics.json"
CODES = tuple(range(0x21, 0x7f)) + tuple(range(0xa1, 0xe0))
# Style conventions noted while observing PC-98 output, drawn here into the
# fitted free glyphs (row, column pixels to add): the slashed zero.
STYLE = {
    0x30: [(5, 5), (6, 5), (7, 4), (8, 4), (9, 3), (10, 3)],
}


def bbox(rows):
    ink = [(y, x) for y, r in enumerate(rows) for x in range(8) if r >> (7 - x) & 1]
    if not ink:
        return None
    ys = [p[0] for p in ink]
    xs = [p[1] for p in ink]
    return min(ys), max(ys), min(xs), max(xs)


def resize_lines(lines, n):
    """Shrink or grow a list of equal-length 0/1 lines to n lines, merging or
    repeating the most similar neighbours (keeps 1-pixel strokes)."""
    lines = [list(l) for l in lines]
    while len(lines) > n:
        best = min(range(len(lines) - 1),
                   key=lambda i: (sum(a != b for a, b in zip(lines[i], lines[i + 1])),
                                  abs(i - (len(lines) - 2) / 2)))
        lines[best:best + 2] = [[a | b for a, b in zip(lines[best], lines[best + 1])]]
    while len(lines) < n:
        best = min(range(len(lines) - 1),
                   key=lambda i: (sum(a != b for a, b in zip(lines[i], lines[i + 1])),
                                  abs(i - (len(lines) - 2) / 2))) if len(lines) > 1 else 0
        lines.insert(best, list(lines[best]))
    return lines


def fit(rows, src, dst):
    top, bottom, left, right = src
    grid = [[rows[y] >> (7 - x) & 1 for x in range(left, right + 1)] for y in range(top, bottom + 1)]
    t, b, l, r = dst
    grid = resize_lines(grid, b - t + 1)
    cols = resize_lines([list(c) for c in zip(*grid)], r - l + 1)
    grid = [list(row) for row in zip(*cols)]
    out = [0] * 16
    for y, row in enumerate(grid):
        for x, v in enumerate(row):
            if v:
                out[t + y] |= 0x80 >> (l + x)
    return out


def targets(rom, spec):
    """Observed box per code; unmeasured codes map their free box through the
    most common observed box among measured glyphs with the same free box
    edges (row and column edges learned separately)."""
    obs = {int(k, 16): (v["top"], v["bottom"], v["left"], v["right"]) for k, v in spec["ank8x16"].items()}
    free = {c: bbox(list(rom[0x800 + c * 16:0x800 + c * 16 + 16])) for c in CODES}
    maps = [collections.defaultdict(collections.Counter) for _ in range(4)]
    for c, o in obs.items():
        if free.get(c):
            for i in range(4):
                maps[i][free[c][i]][o[i]] += 1
    out = {}
    for c in CODES:
        f = free[c]
        if f is None:
            continue
        if c in obs:
            out[c] = obs[c]
            continue
        box = []
        for i in range(4):
            m = maps[i].get(f[i])
            box.append(m.most_common(1)[0][0] if m else f[i])
        if box[1] < box[0]:
            box[1] = box[0]
        if box[3] < box[2]:
            box[3] = box[2]
        out[c] = tuple(box)
    return out


def apply(rom, spec):
    rom = bytearray(rom)
    for c, dst in targets(rom, spec).items():
        o = 0x800 + c * 16
        rows = list(rom[o:o + 16])
        src = bbox(rows)
        new = fit(rows, src, dst) if src != dst else rows
        for y, x in STYLE.get(c, ()):
            new[y] |= 0x80 >> x
        rom[o:o + 16] = bytes(new)
        rom[c * 8:c * 8 + 8] = bytes((new[2 * i] | new[2 * i + 1]) & 0xff for i in range(8))
    return bytes(rom)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("font", type=Path)
    p.add_argument("-o", "--output", type=Path, required=True)
    p.add_argument("--spec", type=Path, default=SPEC)
    args = p.parse_args()
    spec = json.loads(args.spec.read_text(encoding="utf-8"))
    out = apply(args.font.read_bytes(), spec)
    args.output.parent.mkdir(exist_ok=True)
    args.output.write_bytes(out)
    print(f"{args.output}: 8x16 ANK fitted to {len(spec['ank8x16'])} observed character boxes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
