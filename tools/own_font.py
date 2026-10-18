#!/usr/bin/env python3
"""Put your own PC-98 character generator into an Open BIOS boot.rom.

The released boot.rom carries a free font (font/pc98font.rom). If you own a
PC-98 and dumped its font, this writes a boot.rom with the Open BIOS code and
your font, for your own use:

  python tools/own_font.py boot.rom MY_FONT -o boot_myfont.rom

MY_FONT is a 288,768-byte NP2 FONT.ROM-layout file, or a 550,912-byte core
boot.rom that already holds a font at 40000h (for example an NEC BIOS set
built with the core's BIOS setup guide). The result contains that font:
do not redistribute it.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build import FONT_OFFSET, FONT_SIZE  # noqa: E402

ROM_SIZE = FONT_OFFSET + FONT_SIZE


def load_font(path):
    data = path.read_bytes()
    if len(data) == FONT_SIZE:
        return data
    if len(data) == ROM_SIZE:
        return data[FONT_OFFSET:]
    raise SystemExit(f"{path}: {len(data)} bytes; expected a {FONT_SIZE}-byte FONT.ROM "
                     f"or a {ROM_SIZE}-byte core boot.rom")


def check_font(font):
    # the 8x16 ANK letters A-Z and the first JIS kanji row must not be blank
    ank = font[0x800 + 0x41 * 16:0x800 + 0x5b * 16]
    kanji = font[0x1800 + 0xc00 * 15:0x1800 + 0xc00 * 16]
    if not any(ank) or not any(kanji):
        raise SystemExit("the font looks blank (no ANK letters or kanji); check the source file")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("bootrom", type=Path, help="Open BIOS boot.rom (from a release zip)")
    p.add_argument("font", type=Path, help="your FONT.ROM, or a core boot.rom holding your font")
    p.add_argument("-o", "--output", type=Path, required=True)
    args = p.parse_args()
    rom = bytearray(args.bootrom.read_bytes())
    if len(rom) != ROM_SIZE:
        raise SystemExit(f"{args.bootrom}: {len(rom)} bytes; expected an Open BIOS boot.rom of {ROM_SIZE} bytes")
    font = load_font(args.font)
    check_font(font)
    rom[FONT_OFFSET:] = font
    args.output.write_bytes(rom)
    print(f"{args.output}: Open BIOS code from {args.bootrom.name}, font from {args.font.name} "
          "(your own copy: do not redistribute)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
