#!/usr/bin/env python3
"""Build the character generator image (NP2 FONT.ROM layout, 288,768 bytes)
from freely licensed BDF bitmap fonts.

  --ank   8x16 half-width font (JIS X 0201 / ISO 8859 encoding 00h-FFh),
          e.g. Shinonome shnm8x16r.bdf (public domain)
  --kanji 16x16 JIS X 0208 font (ENCODING = JIS code 2121h-7E7Eh),
          e.g. Shinonome shnmk16.bdf (public domain)

Layout (see docs/FONT.md):
  0000h  8x8 ANK, 256 x 8 bytes (derived from the 8x16 glyphs)
  0800h  8x16 ANK 00h-7Fh, 1000h 8x16 ANK 80h-FFh
  1800h  kanji rows: row ku (1-5Ch) at 1800h + 0C00h * (ku - 1), glyph
         (ten - 20h) * 32: 16 bytes left half, 16 bytes right half.
PC-98 specifics generated here: ANK 80h-9Fh/E0h-FFh semigraphics and the
half-width JIS rows 09h-0Ah (copies of ANK 20h-7Fh/A0h-DFh) and 0Bh
(half-width box-drawing pieces, quotes and brackets, as on NEC's ROM).
"""
import argparse
import sys
from pathlib import Path

SIZE = 0x46800


def parse_bdf(path):
    """Return {encoding: (width, height, xoff, yoff, rows[int])}, ascent."""
    glyphs = {}
    ascent = None
    enc = None
    bbx = None
    rows = None
    with open(path, encoding='latin-1') as f:
        for line in f:
            parts = line.split()
            if not parts:
                continue
            key = parts[0]
            if key == 'FONT_ASCENT':
                ascent = int(parts[1])
            elif key == 'ENCODING':
                enc = int(parts[1])
            elif key == 'BBX':
                bbx = tuple(int(v) for v in parts[1:5])
            elif key == 'BITMAP':
                rows = []
            elif key == 'ENDCHAR':
                if enc is not None and enc >= 0 and bbx:
                    glyphs[enc] = (bbx, rows)
                enc = bbx = rows = None
            elif rows is not None:
                rows.append((int(parts[0], 16), len(parts[0]) * 4))
    return glyphs, ascent


def render(glyph, width, height, ascent):
    """Place a BDF glyph in a width x height cell; returns list of row ints
    (MSB = leftmost pixel)."""
    (bw, bh, bx, by), rows = glyph
    cell = [0] * height
    top = ascent - (bh + by)
    for i, (bits, nbits) in enumerate(rows):
        y = top + i
        if not 0 <= y < height:
            continue
        # bits are left aligned in nbits; shift into the cell width
        value = bits >> (nbits - bw) if nbits >= bw else bits << (bw - nbits)
        shift = width - bw - bx
        value = value << shift if shift >= 0 else value >> -shift
        cell[y] |= value & ((1 << width) - 1)
    return cell


# ---------------------------------------------------------------- drawing
def blank(w=8, h=16):
    return [[0] * w for _ in range(h)]


def to_rows(px):
    w = len(px[0])
    return [sum(1 << (w - 1 - x) for x in range(w) if row[x]) for row in px]


def from_rows(rows, w):
    return [[(r >> (w - 1 - x)) & 1 for x in range(w)] for r in rows]


def scale(px, w, h):
    """Resample a pixel grid to w x h, OR-ing the covered source pixels."""
    sh, sw = len(px), len(px[0])
    out = blank(w, h)
    for y in range(h):
        y0, y1 = y * sh // h, max(y * sh // h + 1, (y + 1) * sh // h)
        for x in range(w):
            x0, x1 = x * sw // w, max(x * sw // w + 1, (x + 1) * sw // w)
            out[y][x] = int(any(px[yy][xx] for yy in range(y0, y1) for xx in range(x0, x1)))
    return out


def blit(dst, src, x0, y0):
    for y, row in enumerate(src):
        for x, v in enumerate(row):
            if v and 0 <= y0 + y < len(dst) and 0 <= x0 + x < len(dst[0]):
                dst[y0 + y][x0 + x] = 1


def line(px, x0, y0, x1, y1):
    n = max(abs(x1 - x0), abs(y1 - y0), 1)
    for i in range(n + 1):
        x = round(x0 + (x1 - x0) * i / n)
        y = round(y0 + (y1 - y0) * i / n)
        if 0 <= y < len(px) and 0 <= x < len(px[0]):
            px[y][x] = 1


def ellipse(px, cx, cy, rx, ry, fill=False):
    import math
    h, w = len(px), len(px[0])
    for y in range(h):
        for x in range(w):
            d = ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2
            if (d <= 1.0) if fill else (abs(math.sqrt(d) - 1) * min(rx, ry) < 0.6):
                px[y][x] = 1


def rect(px, x0, y0, x1, y1):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            px[y][x] = 1


# ---------------------------------------------------------------- ANK graphics
CX, CY = 3, 7            # centre column/row of box-drawing lines in 8x16


def semigraphics(kanji_px=None):
    """PC-98 ANK graphics 80h-9Fh, E0h-FFh and the control range, drawn
    procedurally after the published PC-98 character set assignment
    (block elements, box drawing, triangles, card suits, date kanji)."""
    g = {}
    for i in range(8):                                   # 80h-87h lower 1/8..8/8
        px = blank()
        rect(px, 0, 16 - (i + 1) * 2, 7, 15)
        g[0x80 + i] = px
    for i in range(7):                                   # 88h-8Eh left 1/8..7/8
        px = blank()
        rect(px, 0, 0, i, 15)
        g[0x88 + i] = px

    def box(up=0, down=0, left=0, right=0, double_h=False):
        px = blank()
        if left:
            rect(px, 0, CY, CX, CY)
        if right:
            rect(px, CX, CY, 7, CY)
        if up:
            rect(px, CX, 0, CX, CY)
        if down:
            rect(px, CX, CY, CX, 15)
        if double_h:
            for x in range(8):
                px[CY][x] = 0
            if left:
                rect(px, 0, CY - 1, CX, CY - 1)
                rect(px, 0, CY + 1, CX, CY + 1)
            if right:
                rect(px, CX, CY - 1, 7, CY - 1)
                rect(px, CX, CY + 1, 7, CY + 1)
        return px

    g[0x8f] = box(1, 1, 1, 1)                            # cross
    g[0x90] = box(up=1, left=1, right=1)                 # bottom tee
    g[0x91] = box(down=1, left=1, right=1)               # top tee
    g[0x92] = box(up=1, down=1, left=1)                  # right tee
    g[0x93] = box(up=1, down=1, right=1)                 # left tee
    px = blank()
    rect(px, 0, 0, 7, 1)
    g[0x94] = px                                         # upper 1/8
    g[0x95] = box(left=1, right=1)                       # horizontal
    g[0x96] = box(up=1, down=1)                          # vertical
    px = blank()
    rect(px, 7, 0, 7, 15)
    g[0x97] = px                                         # right 1/8
    g[0x98] = box(down=1, right=1)                       # top-left corner
    g[0x99] = box(down=1, left=1)                        # top-right corner
    g[0x9a] = box(up=1, right=1)                         # bottom-left corner
    g[0x9b] = box(up=1, left=1)                          # bottom-right corner
    for code, (dx, dy) in zip(range(0x9c, 0xa0), ((1, 1), (-1, 1), (1, -1), (-1, -1))):
        px = blank()                                     # rounded corners
        rect(px, CX + (1 if dx > 0 else -3), CY, CX + (3 if dx > 0 else -1), CY)
        if dx < 0:
            rect(px, 0, CY, CX - 2, CY)
        else:
            rect(px, CX + 2, CY, 7, CY)
        if dy > 0:
            rect(px, CX, CY + 2, CX, 15)
        else:
            rect(px, CX, 0, CX, CY - 2)
        px[CY + dy][CX] = 1
        px[CY][CX + dx] = 1
        px[CY][CX] = 0
        px[CY + dy][CX + dx] = 0
        g[code] = px

    g[0xe0] = box(left=1, right=1, double_h=True)        # double horizontal
    px = box(up=1, down=1, right=1, double_h=True)
    g[0xe1] = px
    px = box(up=1, down=1, left=1, right=1, double_h=True)
    g[0xe2] = px
    g[0xe3] = box(up=1, down=1, left=1, double_h=True)
    tri = {0xe4: lambda x, y: x >= 7 - y * 8 // 16,      # lower-right triangle
           0xe5: lambda x, y: x <= y * 8 // 16,          # lower-left
           0xe6: lambda x, y: x >= y * 8 // 16,          # upper-right
           0xe7: lambda x, y: x <= 7 - y * 8 // 16}      # upper-left
    for code, f in tri.items():
        g[code] = [[int(f(x, y)) for x in range(8)] for y in range(16)]
    shapes = {
        0xe8: ['...X....', '..XXX...', '.XXXXX..', 'XXXXXXX.', 'XXXXXXX.', 'XX.X.XX.', '...X....', '..XXX...'],
        0xe9: ['.XX.XX..', 'XXXXXXX.', 'XXXXXXX.', 'XXXXXXX.', '.XXXXX..', '..XXX...', '...X....', '........'],
        0xea: ['...X....', '..XXX...', '.XXXXX..', 'XXXXXXX.', '.XXXXX..', '..XXX...', '...X....', '........'],
        0xeb: ['..XXX...', '..XXX...', 'XX.X.XX.', 'XXXXXXX.', 'XX.X.XX.', '...X....', '..XXX...', '........'],
    }
    for code, rows in shapes.items():
        px = blank()
        for y, r in enumerate(rows):
            for x, c in enumerate(r):
                px[y + 4][x] = int(c == 'X')
        g[code] = px
    px = blank()
    ellipse(px, 3.5, 7.5, 3.4, 3.4, fill=True)
    g[0xec] = px
    px = blank()
    ellipse(px, 3.5, 7.5, 3.4, 3.4)
    g[0xed] = px
    for code, pts in ((0xee, (7, 0, 0, 15)), (0xef, (0, 0, 7, 15))):
        px = blank()
        line(px, *pts)
        g[code] = px
    px = blank()
    line(px, 7, 0, 0, 15)
    line(px, 0, 0, 7, 15)
    g[0xf0] = px
    # F1h-F7h: half-width date/time kanji, from the 16x16 kanji
    for code, jis in zip(range(0xf1, 0xf8), (0x315f, 0x472f, 0x376e, 0x467c, 0x3b7e, 0x4a2c, 0x4943)):
        if kanji_px and jis in kanji_px:
            g[code] = scale(kanji_px[jis], 8, 16)
    px = blank()
    line(px, 0, 2, 7, 13)
    g[0xfc] = px                                         # backslash
    # arrows in the control range: 1Ch right, 1Dh left, 1Eh up, 1Fh down
    arrows = {0x1c: ((0, 7, 7, 7), (4, 4, 7, 7), (4, 10, 7, 7)),
              0x1d: ((0, 7, 7, 7), (3, 4, 0, 7), (3, 10, 0, 7)),
              0x1e: ((3, 2, 3, 13), (0, 5, 3, 2), (6, 5, 3, 2)),
              0x1f: ((3, 2, 3, 13), (0, 10, 3, 13), (6, 10, 3, 13))}
    for code, segs in arrows.items():
        px = blank()
        for sgm in segs:
            line(px, *sgm)
        g[code] = px
    return {k: to_rows(v) for k, v in g.items()}


# ---------------------------------------------------------- half-width row 0Bh
def halfwidth_row11(kanji_px):
    """JIS row 0Bh (2B21h-2B7Eh) in NEC's code assignment, drawn from
    descriptions: 2B21h is blank (games use it as a space), then marks, solid,
    dashed and dotted lines, corners, T-pieces and crosses in each thin/thick
    combination, quotes and brackets (cropped from the full-width glyphs)."""
    out = {}
    cols = {1: (4,), 2: (3, 4)}          # vertical arm columns, thin / thick
    rows = {1: (7,), 2: (7, 8)}          # horizontal arm rows

    def box(u=0, d=0, l=0, r=0):
        px = blank()
        vcols = [c for w in (u, d) if w for c in cols[w]]
        x_first = min(vcols) if vcols else 4
        for w, ys in ((u, range(0, 8)), (d, range(7, 16))):
            for y in ys if w else ():
                for x in cols[w]:
                    px[y][x] = 1
        for w, xs in ((l, range(0, 5)), (r, range(x_first, 8))):
            for x in xs if w else ():
                for y in rows[w]:
                    px[y][x] = 1
        return px

    def pattern(horizontal, weight, on):
        px = blank()
        for i in range(16 if not horizontal else 8):
            if i in on:
                for t in (rows if horizontal else cols)[weight]:
                    if horizontal:
                        px[t][i] = 1
                    else:
                        px[i][t] = 1
        return px

    def ticks(y):
        px = blank()
        for x in (2, 5):
            line(px, x, y, x - 1, y + 2)
            px[y + 1][x] = 1
        return px

    out[0x21] = blank()
    out[0x22] = ticks(0)
    out[0x23] = ticks(13)
    out[0x24], out[0x25] = box(l=1, r=1), box(l=2, r=2)
    out[0x26], out[0x27] = box(u=1, d=1), box(u=2, d=2)
    dash_h, dash_v = (1, 2, 3, 5, 6, 7), (0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14)
    dot_h, dot_v = (1, 2, 5, 6), (1, 2, 5, 6, 9, 10, 13, 14)
    for ten, (hz, on) in zip(range(0x28, 0x30, 2), ((1, dash_h), (0, dash_v), (1, dot_h), (0, dot_v))):
        out[ten], out[ten + 1] = pattern(hz, 1, on), pattern(hz, 2, on)
    # corners: horizontal weight varies fastest, then the vertical one
    for base, (h, v) in zip(range(0x30, 0x40, 4), (('r', 'd'), ('l', 'd'), ('r', 'u'), ('l', 'u'))):
        for i, (hw, vw) in enumerate(((1, 1), (2, 1), (1, 2), (2, 2))):
            out[base + i] = box(**{h: hw, v: vw})
    # T-pieces: the thick arms of each variant, in NEC's order
    tee = ((), ('s',), ('a',), ('b',), ('a', 'b'), ('a', 's'), ('b', 's'), ('a', 'b', 's'))
    for base, (a, b, s) in ((0x40, ('u', 'd', 'r')), (0x48, ('u', 'd', 'l')),
                           (0x50, ('l', 'r', 'd')), (0x58, ('l', 'r', 'u'))):
        names = {'a': a, 'b': b, 's': s}
        order = tee if base < 0x50 else ((), ('a',), ('b',), ('a', 'b'), ('s',), ('a', 's'), ('b', 's'), ('a', 'b', 's'))
        for i, thick in enumerate(order):
            out[base + i] = box(**{n: 2 if k in thick else 1 for k, n in names.items()})
    cross = ('', 'l', 'r', 'lr', 'u', 'd', 'ud', 'ul', 'ur', 'dl', 'dr', 'ulr', 'dlr', 'udl', 'udr', 'udlr')
    for i, thick in enumerate(cross):
        out[0x60 + i] = box(**{n: 2 if n in thick else 1 for n in 'udlr'})

    def crop(jis):
        src = kanji_px.get(jis) if kanji_px else None
        if not src:
            return blank()
        xs = [x for x in range(16) if any(row[x] for row in src)]
        if not xs:
            return blank()
        x0, x1 = xs[0], xs[-1]
        if x1 - x0 + 1 > 8:
            return scale([row[x0:x1 + 1] for row in src], 8, 16)
        start = max(0, min(16 - 8, (x0 + x1 + 1) // 2 - 4))
        return [row[start:start + 8] for row in src]

    for ten, jis in zip(range(0x70, 0x7f), (0x2147, 0x2149, 0x2146, 0x2148, 0x214a, 0x214b, 0x2152,
                                             0x2153, 0x2154, 0x2155, 0x214e, 0x214f, 0x215a, 0x215b, 0x213d)):
        out[ten] = crop(jis)
    return {k: to_rows(v) for k, v in out.items()}


# ---------------------------------------------------------------- NEC row 0Dh
def nec_row13(ank_px, kanji_px):
    """JIS row 0Dh (2D21h-2D7Ch), NEC special characters, composed from the
    base fonts: circled numbers, Roman numerals, squared unit words, eras,
    circled/parenthesised kanji and mathematical symbols."""
    out = {}

    def text(s, w=16, h=16, rows=1):
        codes = list(s.encode('shift_jis')) if isinstance(s, str) else list(s)
        per_row = (len(codes) + rows - 1) // rows
        px = blank(w, h)
        cw, ch = w // per_row, h // rows
        for i, c in enumerate(codes):
            gl = ank_px.get(c)
            if gl:
                blit(px, scale(gl, cw, ch), (i % per_row) * cw, (i // per_row) * ch)
        return px

    for n in range(1, 21):                               # 2D21h-2D34h circled
        px = blank(16, 16)
        ellipse(px, 7.5, 7.5, 7.4, 7.4)
        digits = text(str(n), 10 if n > 9 else 6, 10)
        blit(px, digits, 3 if n > 9 else 5, 3)
        out[0x2d20 + n] = px
    def numeral(r):                                      # stroke-drawn I, V, X
        widths = {'I': 1, 'V': 5, 'X': 5}
        total = sum(widths[c] for c in r) + len(r) - 1
        px = blank(16, 16)
        x = (16 - total) // 2
        top, bot = 2, 13
        for c in r:
            w = widths[c]
            if c == 'I':
                line(px, x, top, x, bot)
            elif c == 'V':
                line(px, x, top, x + 2, bot)
                line(px, x + 4, top, x + 2, bot)
            else:
                line(px, x, top, x + 4, bot)
                line(px, x + 4, top, x, bot)
            x += w + 1
        rect(px, (16 - total) // 2, top - 1, (16 - total) // 2 + total - 1, top - 1)
        rect(px, (16 - total) // 2, bot + 1, (16 - total) // 2 + total - 1, bot + 1)
        return px
    roman = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X']
    for i, r in enumerate(roman):                        # 2D35h-2D3Eh
        out[0x2d35 + i] = numeral(r)
    units = ['ﾐﾘ', 'ｷﾛ', 'ｾﾝﾁ', 'ﾒｰﾄﾙ', 'ｸﾞﾗﾑ', 'ﾄﾝ', 'ｱｰﾙ', 'ﾍｸﾀｰﾙ', 'ﾘｯﾄﾙ', 'ﾜｯﾄ',
             'ｶﾛﾘｰ', 'ﾄﾞﾙ', 'ｾﾝﾄ', 'ﾊﾟｰｾﾝﾄ', 'ﾐﾘﾊﾞｰﾙ', 'ﾍﾟｰｼﾞ']
    for i, u in enumerate(units):                        # 2D40h-2D4Fh
        out[0x2d40 + i] = text(u, rows=2 if len(u) > 2 else 1)
    for i, u in enumerate(['mm', 'cm', 'km', 'mg', 'kg', 'cc', 'm2']):   # 2D50h-2D56h
        out[0x2d50 + i] = text(u)

    def kanji2(a, b):                                    # two kanji side by side
        px = blank(16, 16)
        for i, j in enumerate((a, b)):
            if j in kanji_px:
                blit(px, scale(kanji_px[j], 8, 16), i * 8, 0)
        return px
    out[0x2d5f] = kanji2(0x4a3f, 0x402e)                 # heisei
    for q, pts in ((0x2d60, ((3, 2, 5, 6), (7, 2, 9, 6))), (0x2d61, ((7, 9, 9, 13), (11, 9, 13, 13)))):
        px = blank(16, 16)
        for sgm in pts:
            line(px, *sgm)
        out[q] = px
    out[0x2d62] = text('No')
    out[0x2d63] = text('KK')
    out[0x2d64] = text('TEL')
    for i, j in enumerate((0x3e65, 0x4366, 0x323c, 0x3a38, 0x312b)):   # circled
        px = blank(16, 16)
        ellipse(px, 7.5, 7.5, 7.4, 7.4)
        if j in kanji_px:
            blit(px, scale(kanji_px[j], 10, 10), 3, 3)
        out[0x2d65 + i] = px
    for i, j in enumerate((0x3374, 0x4d2d, 0x4265)):     # parenthesised
        px = blank(16, 16)
        line(px, 2, 1, 0, 7)
        line(px, 0, 8, 2, 14)
        line(px, 13, 1, 15, 7)
        line(px, 15, 8, 13, 14)
        if j in kanji_px:
            blit(px, scale(kanji_px[j], 11, 12), 2, 2)
        out[0x2d6a + i] = px
    out[0x2d6d] = kanji2(0x4c40, 0x3c23)                 # meiji
    out[0x2d6e] = kanji2(0x4267, 0x4035)                 # taisho
    out[0x2d6f] = kanji2(0x3e3c, 0x4f42)                 # showa
    # mathematical symbols: reuse JIS X 0208 glyphs where they exist
    for code, jis in ((0x2d70, 0x2262), (0x2d71, 0x2261), (0x2d72, 0x2269), (0x2d74, 0x2632),
                      (0x2d75, 0x2265), (0x2d76, 0x225d), (0x2d77, 0x225c), (0x2d7a, 0x2268),
                      (0x2d7b, 0x2241), (0x2d7c, 0x2240)):
        if jis in kanji_px:
            out[code] = [row[:] for row in kanji_px[jis]]
    if 0x2d72 in out:                                    # contour integral
        px = [row[:] for row in out[0x2d72]]
        ellipse(px, 7.5, 8, 2.2, 2.2)
        out[0x2d73] = px
    px = blank(16, 16)                                   # right angle
    rect(px, 3, 2, 3, 13)
    rect(px, 3, 13, 13, 13)
    out[0x2d78] = px
    px = blank(16, 16)                                   # right triangle
    line(px, 13, 2, 13, 13)
    line(px, 2, 13, 13, 13)
    line(px, 2, 13, 13, 2)
    out[0x2d79] = px
    return out


def build(ank_bdf, kanji_bdf):
    rom = bytearray(SIZE)
    ank = {}
    if ank_bdf:
        glyphs, ascent = parse_bdf(ank_bdf)
        for code in range(256):
            if code in glyphs:
                ank[code] = render(glyphs[code], 8, 16, ascent if ascent is not None else 14)
    kanji = {}
    if kanji_bdf:
        glyphs, ascent = parse_bdf(kanji_bdf)
        for code, glyph in glyphs.items():
            hi, lo = code >> 8, code & 0xff
            if 0x21 <= hi <= 0x7e and 0x21 <= lo <= 0x7e:
                kanji[code] = render(glyph, 16, 16, ascent if ascent is not None else 14)
    kanji_px = {k: from_rows(v, 16) for k, v in kanji.items()}
    # PC-98 graphics replace whatever the base font has in these ranges
    for code, rows in semigraphics(kanji_px).items():
        ank[code] = rows
    for code in range(0x80, 0xa0):
        ank.setdefault(code, [0] * 16)
    for code in range(0xe0, 0x100):
        ank.setdefault(code, [0] * 16)
    for code, rows in ank.items():
        rom[0x800 + code * 16:0x800 + code * 16 + 16] = bytes(r & 0xff for r in rows)
        rom[code * 8:code * 8 + 8] = bytes((rows[2 * i] | rows[2 * i + 1]) & 0xff for i in range(8))

    def put(ku, ten, rows16):
        if not (1 <= ku <= 0x5c and 0x21 <= ten <= 0x7e):
            return
        base = 0x1800 + 0xc00 * (ku - 1) + (ten - 0x20) * 32
        rom[base:base + 16] = bytes((r >> 8) & 0xff for r in rows16)
        rom[base + 16:base + 32] = bytes(r & 0xff for r in rows16)

    for code, rows in kanji.items():
        put((code >> 8) - 0x20, code & 0xff, rows)
    ank_px = {k: from_rows(v, 8) for k, v in ank.items()}
    extra = nec_row13(ank_px, kanji_px)
    for code, px in extra.items():
        put((code >> 8) - 0x20, code & 0xff, to_rows(px))
    # half-width rows 09h-0Bh (left halves): 9 = ANK 20h-7Fh, 10 = A0h-DFh,
    # 11 = NEC's half-width box pieces, quotes and brackets
    row11 = halfwidth_row11(kanji_px)
    for ten in range(0x21, 0x7f):
        def half(code):
            return [r << 8 for r in rom[0x800 + code * 16:0x800 + code * 16 + 16]]
        put(0x09, ten, half(ten))
        if 0xa0 + ten - 0x20 < 0xe0:
            put(0x0a, ten, half(0xa0 + ten - 0x20))
        put(0x0b, ten, [r << 8 for r in row11.get(ten, [0] * 16)])
    return bytes(rom), len(ank), len(kanji) + len(extra)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--ank', type=Path, help='8x16 BDF (encodings 00h-FFh)')
    p.add_argument('--kanji', type=Path, help='16x16 JIS X 0208 BDF')
    p.add_argument('-o', '--output', type=Path, default=Path(__file__).resolve().parent.parent / 'build/font.rom')
    args = p.parse_args()
    rom, nank, nkanji = build(args.ank, args.kanji)
    args.output.parent.mkdir(exist_ok=True)
    args.output.write_bytes(rom)
    print(f'{args.output}: {len(rom)} bytes, {nank} ANK glyphs, {nkanji} kanji')


if __name__ == '__main__':
    sys.exit(main())
