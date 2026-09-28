#!/usr/bin/env python3
"""Boot MS-DOS from a raw VHD through the core's disk ROM, to the prompt."""
import argparse
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from pc98 import PC98, ROOT
from core_rom import ROMS

DEFAULT_VHD = ROMS / 'TEST_GAMES/Working_Game_Collection_B142.vhd'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--vhd', type=Path, default=DEFAULT_VHD)
    p.add_argument('--seconds', type=float, default=30)
    p.add_argument('--trace-ints', action='store_true')
    p.add_argument('--full', action='store_true', help='run CONFIG.SYS/AUTOEXEC.BAT (no F5)')
    args = p.parse_args()
    m = PC98(ROOT / 'build/boot.rom', disk_rom=ROOT / 'build/diskrom.bin', vhd=args.vhd)
    m.trace_ints = args.trace_ints
    if not args.full:
        # Hold F5 (key 62h) so MS-DOS 6 skips CONFIG.SYS and AUTOEXEC.BAT.
        m.run(until=lambda m: 'MS-DOS' in m.text_screen(), seconds=5)
        m.type_keys([0x62, 0xe2])
    prompt = lambda m: any(l.rstrip().endswith('>') for l in m.text_screen().splitlines())
    try:
        ok = m.run(seconds=args.seconds, until=prompt)
    finally:
        print(m.text_screen())
        print(f'--- time {m.now:.2f}s, {m.instructions} instructions, halted={m.halted}, '
              f'pc={m.linear_pc():#x}')
        print('unknown ports', sorted(m.unknown_ports))
        if m.trace_ints:
            from collections import Counter
            print(Counter((v, ax >> 8) for v, ax, pc in m.int_log).most_common(40))
    print('PASS' if ok else 'FAIL', 'DOS prompt')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
