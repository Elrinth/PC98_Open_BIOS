#!/usr/bin/env python3
"""Render a FONT.ROM-layout image as a PNG sheet for review:
ANK 8x16 (16x16 grid), ANK 8x8, and chosen kanji rows."""
import argparse
from pathlib import Path
from PIL import Image


def glyph16(rom, code):
    return rom[0x800 + code * 16:0x800 + code * 16 + 16]


def kanji(rom, ku, ten):
    b = 0x1800 + 0xc00 * (ku - 1) + (ten - 0x20) * 32
    return rom[b:b + 16], rom[b + 16:b + 32]


def draw(img, x0, y0, rows, width=8, scale=2):
    for y, r in enumerate(rows):
        for x in range(width):
            if r & (1 << (width - 1 - x)):
                for dy in range(scale):
                    for dx in range(scale):
                        img.putpixel((x0 + x * scale + dx, y0 + y * scale + dy), 0)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('font', type=Path)
    p.add_argument('-o', type=Path, default=Path('build/fontsheet.png'))
    p.add_argument('--rows', default='1,2,3,4,8,9,10,11,13,16,17,48')
    a = p.parse_args()
    rom = a.font.read_bytes()
    rows = [int(r, 0) for r in a.rows.split(',')]
    s = 2
    w = 16 * 20 * s + 8 * 12 * s + 40
    h = max(16 * 36 * s, len(rows) * 36 * s) + 40
    img = Image.new('L', (94 * 17 * s + 40, 16 * 36 * s + 20 + len(rows) * 36 * s), 255)
    for code in range(256):
        draw(img, 10 + (code % 16) * 20 * s, 10 + (code // 16) * 36 * s, glyph16(rom, code), 8, s)
        draw(img, 10 + (code % 16) * 20 * s + 10 * s, 10 + (code // 16) * 36 * s + 18 * s,
             rom[code * 8:code * 8 + 8], 8, s)
    y0 = 16 * 36 * s + 20
    for i, ku in enumerate(rows):
        for ten in range(0x21, 0x7f):
            l, r = kanji(rom, ku, ten)
            draw(img, 10 + (ten - 0x21) * 17 * s, y0 + i * 36 * s,
                 [(l[k] << 8) | r[k] for k in range(16)], 16, s)
    img.save(a.o)
    print(a.o)


if __name__ == '__main__':
    main()
