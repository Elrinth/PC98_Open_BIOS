#!/usr/bin/env python3
"""LIO (INT A0h-AFh) graphics BIOS against pixels in the model's VRAM."""
import math
import struct
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from pc98 import PC98, ROOT

WSEG = 0x2000                     # caller work segment (LIO state at 0620h)
PARAM = 0x1000                    # parameter block offset
BUF = 0x3000                      # GET/PUT buffer segment
failures = []


def check(name, cond, detail=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  {detail}' if detail and not cond else ''))
    if not cond:
        failures.append(name)


class Lio:
    def __init__(self, m):
        self.m = m

    def call(self, fn, block=b'', ah=0):
        self.m.u.mem_write(WSEG * 16 + PARAM, bytes(block).ljust(32, b'\0'))
        out = self.m.call_int(0xa0 + fn, ax=ah << 8, ds=WSEG, bx=PARAM, max_instructions=60_000_000)
        return out['ax'] >> 8, out['ax'] & 0xff

    def work(self):
        return self.m.mem(WSEG * 16 + 0x620, 24)


def w(*vals):
    return struct.pack('<' + 'H' * len(vals), *[v & 0xffff for v in vals])


def colour_at(m, x, y, planes=3, upper=0):
    off = upper + y * 80 + (x >> 3)
    bit = 0x80 >> (x & 7)
    c = 0
    for i, base in enumerate((0xa8000, 0xb0000, 0xb8000, 0xe0000)[:planes]):
        if m.byte(base + off) & bit:
            c |= 1 << i
    return c


def snapshot(m, planes=3):
    import numpy as np
    arr = [np.unpackbits(np.frombuffer(m.mem(b, 32000), dtype=np.uint8)).reshape(400, 640)
           for b in (0xa8000, 0xb0000, 0xb8000, 0xe0000)[:planes]]
    img = arr[0].astype(int)
    for i in range(1, planes):
        img |= arr[i].astype(int) << i
    return img


def main():
    m = PC98(ROOT / 'build/boot.rom')
    m.run(until=lambda m: 'No bootable' in m.text_screen(), seconds=3)
    lio = Lio(m)
    st, _ = lio.call(0)
    wk = lio.work()
    check('GINIT', st == 0 and wk[2] == 1 and wk[3] == 7 and struct.unpack_from('<4h', wk, 14) == (0, 0, 639, 399),
          (st, wk.hex()))
    check('GINIT starts graphics', m.gdc[1].started)
    # 640x400 colour: mode 3, display on, active 0, display 1
    st, _ = lio.call(1, bytes([3, 0, 0, 1]))
    check('GSCREEN mode 3', st == 0 and lio.work()[0] == 3, st)
    st, _ = lio.call(1, bytes([7, 0, 0, 0]))
    check('GSCREEN rejects mode 7', st == 5, st)
    st, _ = lio.call(5)
    img = snapshot(m)
    check('GCLS clears', st == 0 and not img.any())

    st, _ = lio.call(6, w(100, 100) + bytes([5]))
    check('GPSET', st == 0 and colour_at(m, 100, 100) == 5 and colour_at(m, 101, 100) == 0)
    st, al = lio.call(15, w(100, 100))
    check('GPOINT2', st == 0 and al == 5, (st, al))
    st, al = lio.call(15, w(700, 100))
    check('GPOINT2 outside window', al == 0xff, al)
    st, _ = lio.call(6, w(102, 100) + bytes([0xff]), ah=1)
    check('GPSET foreground (AH=1)', colour_at(m, 102, 100) == 7)

    # solid line
    lio.call(5)
    st, _ = lio.call(7, w(10, 10, 110, 60) + bytes([2, 0, 0]))
    img = snapshot(m)
    pts = list(zip(*img.nonzero()))
    ok = st == 0 and img[10, 10] == 2 and img[60, 110] == 2 and len(pts) == 101 and \
        all(abs(y - (10 + (x - 10) / 2)) <= 1 for y, x in pts)
    check('GLINE line', ok, (st, len(pts)))
    # styled line: pattern 0xF0F0 -> 4 on, 4 off
    lio.call(5)
    st, _ = lio.call(7, w(0, 5, 31, 5) + bytes([4, 0, 1, 0xf0, 0xf0]))
    row = [snapshot(m)[5, x] for x in range(32)]
    check('GLINE styled', row == ([4] * 4 + [0] * 4) * 4, row)
    # box outline and filled box
    lio.call(5)
    lio.call(7, w(50, 60, 150, 120) + bytes([6, 1, 0]))
    img = snapshot(m)
    per = {(x, 60) for x in range(50, 151)} | {(x, 120) for x in range(50, 151)} | \
          {(50, y) for y in range(60, 121)} | {(150, y) for y in range(60, 121)}
    got = {(int(x), int(y)) for y, x in zip(*img.nonzero())}
    check('GLINE box', got == per and img[60, 50] == 6, len(got ^ per))
    lio.call(5)
    lio.call(7, w(20, 30, 29, 34) + bytes([3, 2, 0]))
    img = snapshot(m)
    check('GLINE filled box', (img[30:35, 20:30] == 3).all() and img.sum() == 3 * 50)
    # filled box with colour 1 inside and a colour 7 frame
    lio.call(5)
    lio.call(7, w(20, 30, 29, 34) + bytes([7, 2, 1, 1, 0]))
    img = snapshot(m)
    check('GLINE fill + frame', img[32, 25] == 1 and img[30, 20] == 7 and img[34, 29] == 7)

    # clipping by the view
    lio.call(5)
    lio.call(2, w(100, 100, 199, 199) + bytes([0xff, 0xff]))
    lio.call(7, w(0, 0, 399, 399) + bytes([7, 0, 0]))
    img = snapshot(m)
    ys, xs = img.nonzero()
    check('GVIEW clips lines', len(xs) == 100 and xs.min() == 100 and xs.max() == 199, len(xs))
    lio.call(2, w(0, 0, 639, 399) + bytes([0, 0xff]))   # reset view, clear to 0

    # circle
    lio.call(5)
    r = 60
    st, _ = lio.call(8, w(320, 200, r, r) + bytes([7, 0]))
    img = snapshot(m)
    ys, xs = img.nonzero()
    d = [math.hypot(x - 320, y - 200) for x, y in zip(xs, ys)]
    check('GCIRCLE outline', st == 0 and len(d) > 300 and all(abs(v - r) < 1.5 for v in d),
          (st, len(d), min(d, default=0), max(d, default=0)))
    # connectivity: every outline pixel has a neighbour
    pts = set(zip(xs.tolist(), ys.tolist()))
    lonely = [p for p in pts if not any((p[0] + dx, p[1] + dy) in pts
                                         for dx in (-1, 0, 1) for dy in (-1, 0, 1) if dx or dy)]
    check('GCIRCLE outline connected', not lonely, lonely[:5])
    # ellipse filled
    lio.call(5)
    st, _ = lio.call(8, w(200, 150, 80, 40) + bytes([2, 0x20]) + bytes(8) + bytes([5]))
    img = snapshot(m)
    area = int((img == 5).sum()) + int((img == 2).sum())
    check('GCIRCLE filled ellipse', st == 0 and abs(area - math.pi * 80 * 40) < 0.05 * math.pi * 80 * 40
          and img[150, 200] == 5, (st, area))
    # quarter arc from +x axis (start) to +y (up) = end point (cx, cy - r)
    lio.call(5)
    st, _ = lio.call(8, w(320, 200, 50, 50) + bytes([4, 0x05]) + w(370, 200, 320, 150))
    img = snapshot(m)
    ys, xs = img.nonzero()
    check('GCIRCLE arc quadrant', st == 0 and len(xs) > 20 and xs.min() >= 319 and ys.max() <= 201,
          (st, len(xs), xs.min() if len(xs) else None, ys.max() if len(ys) else None))

    # paint: box outline colour 2, fill inside with 4
    lio.call(5)
    lio.call(7, w(100, 100, 200, 150) + bytes([2, 1, 0]))
    st, _ = lio.call(9, w(150, 120) + bytes([4, 2]) + w(0x9000, 0x4000))
    img = snapshot(m)
    check('GPAINT1 fills inside', st == 0 and (img[101:150, 101:200] == 4).all()
          and img[100, 150] == 2 and img[99, 150] == 0 and img[160, 150] == 0, st)

    # GET / PUT round trip
    lio.call(5)
    lio.call(8, w(40, 40, 20, 20) + bytes([6, 0x20]) + bytes(8) + bytes([3]))
    before = snapshot(m)[15:66, 15:66].copy()
    st, _ = lio.call(11, w(15, 15, 65, 65) + w(0, BUF, 0x8000))
    lio.call(5)
    st2, _ = lio.call(12, w(115, 215) + w(0, BUF, 0x8000) + bytes([0, 0, 0, 0]))
    after = snapshot(m)[215:266, 115:166]
    check('GGET/GPUT1 round trip', st == 0 and st2 == 0 and (before == after).all(), (st, st2))
    # XOR put twice restores the background
    lio.call(12, w(115, 215) + w(0, BUF, 0x8000) + bytes([4, 0, 0, 0]))
    check('GPUT1 XOR', not snapshot(m)[215:266, 115:166].any())

    # GPUT2 character
    lio.call(5)
    st, _ = lio.call(13, w(8, 16) + w(0x41) + bytes([0, 1, 7, 0]))
    img = snapshot(m)[16:32, 8:16]
    check('GPUT2 ANK glyph', st == 0 and img.any(), st)

    # GROLL: scroll up 10 lines (content at y moves to y-10)
    lio.call(5)
    lio.call(6, w(300, 100) + bytes([7]))
    st, _ = lio.call(14, w(10, 0) + bytes([0]))
    check('GROLL', st == 0 and colour_at(m, 300, 90) == 7 and colour_at(m, 300, 100) == 0, st)

    # GCOLOR2: digital palette 1 -> colour 4
    st, _ = lio.call(4, bytes([1, 4, 0]))
    check('GCOLOR2 digital', st == 0 and (m.digital_pal[1] >> 4) & 7 == 4, [hex(v) for v in m.digital_pal])

    print('FAILED:' if failures else 'ALL PASS', ', '.join(failures))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
