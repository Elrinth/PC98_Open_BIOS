#!/usr/bin/env python3
"""Boot a floppy image (D88/HDM/FDI) through the BIOS floppy driver."""
import argparse
import sys
from collections import Counter
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from pc98 import PC98, ROOT
from core_rom import ROMS

DEFAULT = ROMS / 'rusty' / 'Rusty (Opening disk).D88'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('image', type=Path, nargs='?', default=DEFAULT)
    p.add_argument('--b', type=Path, help='image for drive 1')
    p.add_argument('--seconds', type=float, default=5)
    args = p.parse_args()
    m = PC98(ROOT / 'build/boot.rom')
    m.mount(0, args.image)
    if args.b:
        m.mount(1, args.b)
    m.trace_ints = True
    booted = lambda m: any(pc < 0xe8000 and v == 0x1b for v, ax, pc in m.int_log[-50:]) and \
        m.byte(0x584) in (0x90, 0x91, 0x70, 0x71) and m.linear_pc() < 0xd0000
    m.run(seconds=args.seconds)
    print(m.text_screen())
    print(f'--- {m.now:.2f}s {m.instructions} instr, DA/UA {m.byte(0x584):02x}, pc {m.linear_pc():#x}')
    fd = Counter((ax >> 8) for v, ax, pc in m.int_log if v == 0x1b)
    print('INT 1Bh calls by AH:', {f'{k:02x}': n for k, n in fd.items()})
    print('FDC commands:', [c.hex() for c in m.fdc.log[:12]], '...', len(m.fdc.log))
    ipl = any(pc >= 0x1fc00 and pc < 0x20000 for v, ax, pc in m.int_log) or m.fdc.log
    ok = 'No bootable disk' not in m.text_screen() and m.byte(0x584) in (0x90, 0x91, 0x70, 0x71) and any(v == 0x1b and pc < 0xd0000 for v, ax, pc in m.int_log)
    print('PASS' if ok else 'FAIL', 'floppy boot')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
