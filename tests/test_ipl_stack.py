#!/usr/bin/env python3
"""A floppy IPL starts on NEC's boot stack, SS:SP = 0030:00FA, just below the
BIOS work area (NEC's BIOS enters 1FC0:0000 so, measured in NP2kai). A boot
stack under 7C00h lies where IPLs load their programs: Dinosaur reads its first
file to 0000:1000 and up, and its INT 1Bh call returned to 0000:0000."""
import sys
import tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from pc98 import PC98, ROOT

# The IPL stores SS, SP and CS at CS:03F0 before touching the stack, then spins.
IPL = bytes([0x8C, 0xD0, 0x2E, 0xA3, 0xF0, 0x03,     # mov ax,ss / mov [cs:3F0h],ax
             0x89, 0xE0, 0x2E, 0xA3, 0xF2, 0x03,     # mov ax,sp / mov [cs:3F2h],ax
             0x8C, 0xC8, 0x2E, 0xA3, 0xF4, 0x03,     # mov ax,cs / mov [cs:3F4h],ax
             0xEB, 0xFE])                            # jmp $


def main():
    image = bytearray(77 * 2 * 8 * 1024)             # 2HD, 8 sectors of 1024 bytes (HDM)
    image[:len(IPL)] = IPL
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / 'ipl.hdm'
        path.write_bytes(image)
        m = PC98(ROOT / 'build/boot.rom')
        m.mount(0, path)
        m.run(seconds=5, until=lambda m: m.word(0x1fff4) == 0x1fc0)
    ss, sp, cs = (m.word(0x1fff0 + 2 * i) for i in range(3))
    print(f'IPL entry: CS={cs:04x} SS={ss:04x} SP={sp:04x}')
    ok = cs == 0x1fc0 and ss == 0x0030 and sp == 0x00fa
    print('PASS' if ok else 'FAIL', 'IPL stack')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
