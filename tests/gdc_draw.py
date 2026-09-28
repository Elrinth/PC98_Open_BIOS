"""uPD7220 figure drawing for the test machine's graphics GDC.

Algorithms follow NP2kai io/gdc_sub.c (BSD-3-Clause, NP2 developer team):
line (L), rectangle (R), circle/arc (C) and graphic character (TEXTE).
"""
import math

VECTDIR = [(0, 1, 1, 0), (1, 1, 1, -1), (1, 0, 0, -1), (1, -1, -1, -1),
           (0, -1, -1, 0), (-1, -1, -1, 1), (-1, 0, 0, 1), (-1, 1, 1, 1),
           (0, 1, 1, 1), (1, 1, 1, 0), (1, 0, 1, -1), (1, -1, 0, -1),
           (0, -1, -1, -1), (-1, -1, -1, 0), (-1, 0, -1, 1), (-1, 1, 0, 1)]
class Painter:
    def __init__(self, write_pixel, csrw, dot, pattern, mode):
        self.write_pixel = write_pixel
        self.plane = (csrw >> 14) & 3
        a = csrw & 0x3fff
        self.x0 = (a % 40) * 16 + dot
        self.y0 = a // 40
        self.pattern = pattern & 0xffff
        self.mode = mode & 3
        self.dots = 0

    def pset(self, x, y):
        bit = self.pattern & 1
        self.pattern = (self.pattern >> 1) | (bit << 15)
        self.dots += 1
        x &= 0xffff
        y &= 0xffff
        if y >= 400 or x >= 640:
            return
        self.write_pixel(self.plane, x, y, bit, self.mode)


def word(v, i):
    return v[i] | (v[i + 1] << 8)


def draw_vect(painter, v):
    ope = v[0]
    kind = ope & 0x78
    d = ope & 7
    dc = word(v, 1) & 0x3fff
    x, y = painter.x0, painter.y0
    p = painter.pset
    if kind == 0x08:                                  # line
        d1 = word(v, 7)
        if dc == 0:
            p(x, y)
            return
        for i in range(dc + 1):
            step = (((d1 * i) // dc) + 1) >> 1
            if d == 0: p(x + step, y + i)
            elif d == 1: p(x + i, y + step)
            elif d == 2: p(x + i, y - step)
            elif d == 3: p(x + step, y - i)
            elif d == 4: p(x - step, y - i)
            elif d == 5: p(x - i, y - step)
            elif d == 6: p(x - i, y + step)
            else: p(x - step, y + i)
    elif kind == 0x40:                                # rectangle
        dd = word(v, 3) & 0x3fff
        d2 = word(v, 5) & 0x3fff
        dx, dy, dx2, dy2 = VECTDIR[d]
        for count, sx, sy in ((dd, dx, dy), (d2, dx2, dy2), (dd, -dx, -dy), (d2, -dx2, -dy2)):
            for _ in range(count):
                p(x, y)
                x += sx
                y += sy
    elif kind == 0x20:                                # circle / arc
        r = word(v, 3) & 0x3fff
        m = (r * 10000 + 14141) // 14142
        if not m:
            p(x, y)
            return
        i = word(v, 9) & 0x3fff
        t = min(dc, m)
        while i <= t:
            s = int(round(math.sqrt(max(0, r * r - i * i))))
            if d == 0: p(x + s, y + i)
            elif d == 1: p(x + i, y + s)
            elif d == 2: p(x + i, y - s)
            elif d == 3: p(x + s, y - i)
            elif d == 4: p(x - s, y - i)
            elif d == 5: p(x - i, y - s)
            elif d == 6: p(x - i, y + s)
            else: p(x - s, y + i)
            i += 1
    else:                                             # single dot
        p(x, y)


def draw_text(painter, v, pattern8, zoom=1):
    ope = v[0]
    sy = (word(v, 1) & 0x3fff) + 1
    sx = ((word(v, 3) - 1) & 0x3fff) + 1
    sx, sy = min(sx, 768), min(sy, 768)
    dx, dy, dx2, dy2 = VECTDIR[((ope & 0x80) >> 4) + (ope & 7)]
    painter.pattern = 0xffff
    patnum = 0
    px, py = painter.x0, painter.y0
    for _ in range(sy):
        patnum -= 1
        for _ in range(zoom):
            cx, cy = px, py
            bits = pattern8[patnum & 7]
            for _ in range(sx):
                on = bits & 1
                bits = (bits >> 1) | (0x80 if on else 0)
                for _ in range(zoom):
                    if on:
                        painter.pset(cx, cy)
                    cx += dx
                    cy += dy
            px += dx2
            py += dy2
