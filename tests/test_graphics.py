#!/usr/bin/env python3
"""INT 18h graphics: display control, palette and GDC figure drawing
(47h line/rectangle/circle, 49h graphic character, 45h dot pattern)."""
import math
import struct
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from pc98 import PC98, ROOT

failures = []
UCW = 0x0800                      # UCW at 0000:0800
PAT = 0x0900                      # pattern bytes for 45h


def check(name, cond, detail=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  {detail}' if detail and not cond else ''))
    if not cond:
        failures.append(name)


def ucw(m, **f):
    b = bytearray(64)
    layout = dict(on_ptn=(0, 'B'), dotu=(2, 'B'), dsp=(3, 'B'), sx1=(8, 'H'), sy1=(10, 'H'),
                  lng1=(12, 'H'), wdpa=(14, 'H'), sx2=(22, 'H'), sy2=(24, 'H'), mdot=(26, 'H'),
                  cir=(28, 'H'), lng2=(30, 'H'), dtyp=(40, 'B'))
    for k, v in f.items():
        if k == 'mdoti':
            b[32:32 + len(v)] = v
        else:
            off, fmt = layout[k]
            struct.pack_into('<' + fmt, b, off, v & (0xff if fmt == 'B' else 0xffff))
    m.u.mem_write(UCW, bytes(b))


def pixels(m, plane=0):
    data = m.planes(0)[plane]
    return {(x, y) for y in range(400) for xb in range(80) if data[y * 80 + xb]
            for x in [xb * 8 + i for i in range(8) if data[y * 80 + xb] & (0x80 >> i)]}


def clear(m):
    for base in (0xa8000, 0xb0000, 0xb8000, 0xe0000):
        m.u.mem_write(base, bytes(0x8000))


def main():
    m = PC98(ROOT / 'build/boot.rom')
    m.run(until=lambda m: 'No bootable' in m.text_screen(), seconds=3)
    m.call_int(0x18, ax=0x4000)
    check('graphics started', m.gdc[1].started)
    m.call_int(0x18, ax=0x4200, cx=0xc000)
    check('42h 640x400 start address 0', m.gdc[1].pram[0:2] == b'\0\0')
    # palette 43h: colours 0..7 -> 7..0
    m.u.mem_write(UCW, bytes(4) + bytes([0x01, 0x23, 0x45, 0x67]))
    m.call_int(0x18, ax=0x4300, ds=0, bx=UCW)
    check('43h palette', m.digital_pal == [0x51, 0x73, 0x40, 0x62], [hex(v) for v in m.digital_pal])

    # line (10,20)-(110,70), blue plane only (CH=00h), replace mode, solid
    clear(m)
    ucw(m, dotu=0, sx1=10, sy1=20, sx2=110, sy2=70, dtyp=1, mdoti=b'\xff\xff')
    m.call_int(0x18, ax=0x4700, ds=0, bx=UCW, cx=0x0000)
    px = pixels(m, 0)
    ok = (10, 20) in px and (110, 70) in px and len(px) == 101 and \
        all(abs(y - (20 + (x - 10) / 2)) <= 1 for x, y in px)
    check('47h line', ok, f'{len(px)} px, ends {(10, 20) in px} {(110, 70) in px}')
    check('line only on blue plane', not any(m.planes(0)[1]) and not any(m.planes(0)[2]))

    # steep line upwards-left (tests the other octants)
    clear(m)
    ucw(m, dotu=0, sx1=300, sy1=300, sx2=280, sy2=100, dtyp=1, mdoti=b'\xff\xff')
    m.call_int(0x18, ax=0x4700, ds=0, bx=UCW, cx=0x0000)
    px = pixels(m, 0)
    check('47h steep line', (300, 300) in px and (280, 100) in px and len(px) == 201, len(px))

    # rectangle (50,60)-(150,120), all colours white (CH=30h, ON_PTN=7)
    clear(m)
    ucw(m, on_ptn=7, sx1=50, sy1=60, sx2=150, sy2=120, dtyp=2, dsp=0, mdoti=b'\xff\xff')
    m.call_int(0x18, ax=0x4700, ds=0, bx=UCW, cx=0x3000)
    per = {(x, 60) for x in range(50, 151)} | {(x, 120) for x in range(50, 151)} | \
          {(50, y) for y in range(60, 121)} | {(150, y) for y in range(60, 121)}
    got = [pixels(m, p) for p in range(3)]
    check('47h rectangle on B/R/G', all(g == per for g in got), [len(g ^ per) for g in got])

    # circle centre (320,200) r=50: 8 octant arcs with DSP 0..7
    clear(m)
    r = 50
    for d in range(8):
        ucw(m, dotu=0, sx1=320, sy1=200, dtyp=3, dsp=d, cir=r + 1,
            lng1=int(r / math.sqrt(2)) + 1, mdot=0, mdoti=b'\xff\xff')
    # full circle: NEC software issues each octant; draw octant 0..7
    for d in range(8):
        ucw(m, dotu=0, sx1=320, sy1=200, dtyp=3, dsp=d, cir=r + 1,
            lng1=int(r / math.sqrt(2)) + 1, mdoti=b'\xff\xff')
        m.call_int(0x18, ax=0x4800, ds=0, bx=UCW, cx=0x0000)
    px = pixels(m, 0)
    dist = [math.hypot(x - 320, y - 200) for x, y in px]
    check('48h circle radius', px and all(abs(d - r) <= 1.5 for d in dist) and len(px) > 250,
          f'{len(px)} px, radius {min(dist, default=0):.1f}-{max(dist, default=0):.1f}')

    # graphic character: 8x8 pattern at (200,100)
    clear(m)
    glyph = bytes([0x18, 0x3c, 0x66, 0x7e, 0x66, 0x66, 0x66, 0x00])
    # direction 2 from the bottom-left corner, as NEC software draws text
    ucw(m, dotu=0, sx1=200, sy1=107, dsp=2, mdoti=glyph)
    m.call_int(0x18, ax=0x4900, ds=0, bx=UCW, cx=0x0000)
    px = pixels(m, 0)
    want = {(200 + x, 100 + y) for y in range(8) for x in range(8) if glyph[y] & (0x80 >> x)}
    check('49h graphic character', px == want, f'{len(px)} vs {len(want)}; sample {sorted(px)[:4]}')

    # 45h: 12-dot pattern 10110011 1111
    clear(m)
    m.u.mem_write(PAT, bytes([0xb3, 0xf0]))
    ucw(m, dotu=0, sx1=16, sy1=5, lng1=12, wdpa=PAT)
    m.call_int(0x18, ax=0x4500, ds=0, bx=UCW, cx=0x0000)
    px = pixels(m, 0)
    bits = '101100111111'
    want = {(16 + i, 5) for i, c in enumerate(bits) if c == '1'}
    check('45h dot pattern', px == want, sorted(px))

    m.call_int(0x18, ax=0x4100)
    check('graphics stopped', not m.gdc[1].started)

    # 31 kHz / 480-line: refused without the core extension
    out = m.call_int(0x18, ax=0x300c, bx=0x3200)
    check('30h refused without 09A8h', out['ax'] >> 8 == 0 and m.byte(0x597) & 0x80 == 0)
    m2 = PC98(ROOT / 'build/boot.rom', has_31k=True)
    m2.run(until=lambda m: 'No bootable' in m.text_screen(), seconds=3)
    check('POST advertises 31 kHz', m2.byte(0x597) & 0x80)
    out = m2.call_int(0x18, ax=0x300c, bx=0x3200)
    sync = [p for c, p in m2.gdc[0].log if c == 0x0e][-1]
    lines = sync[6] | (sync[7] & 3) << 8
    check('30h 640x480 30 lines', out['ax'] >> 8 == 5 and lines == 480 and m2.port_9a8 == 1
          and m2.byte(0x53b) == 0x0f and m2.byte(0x53c) & 0x11 == 0x11 and m2.byte(0x54d) & 0x80,
          (hex(out['ax']), lines, hex(m2.byte(0x53c))))
    out = m2.call_int(0x18, ax=0x3100)
    check('31h sense', out['ax'] & 0xff == 0x0c and out['bx'] >> 8 == 0x32, (hex(out['ax']), hex(out['bx'])))
    out = m2.call_int(0x18, ax=0x300c, bx=0x2100)
    sync = [p for c, p in m2.gdc[0].log if c == 0x0e][-1]
    check('30h back to 640x400 25 lines', out['ax'] >> 8 == 5 and (sync[6] | (sync[7] & 3) << 8) == 400
          and not m2.byte(0x54d) & 0x80)
    out = m2.call_int(0x18, ax=0x300c, bx=0x2200)
    check('30h refuses 30 lines at 400', out['ax'] >> 8 == 0)
    print('FAILED:' if failures else 'ALL PASS', ', '.join(failures))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
