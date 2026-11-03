#!/usr/bin/env python3
"""A bootable floppy wins over a bootable hard disk, as on NEC machines: games
installed to a hard disk ship their own boot disk ("boot disk in drive A, then
reset"). With the floppy drives empty the hard disk still boots."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from pc98 import PC98, ROOT
from test_dos_boot import DEFAULT_VHD
from test_floppy_boot import DEFAULT as DEFAULT_FD


def boot(floppy):
    m = PC98(ROOT / 'build/boot.rom', disk_rom=ROOT / 'build/diskrom.bin', vhd=DEFAULT_VHD)
    if floppy:
        m.mount(0, DEFAULT_FD)
    m.run(seconds=5, until=lambda m: 0x1fc00 <= m.linear_pc() < 0x20000 or m.byte(0x584) in (0x80, 0x81))
    return m.byte(0x584)


def main():
    with_fd = boot(True)
    without = boot(False)
    print(f'DA/UA with a floppy {with_fd:02x}, without {without:02x}')
    ok = with_fd in (0x90, 0x70) and without == 0x80
    print('PASS' if ok else 'FAIL', 'boot order')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
