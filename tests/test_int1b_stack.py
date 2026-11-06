#!/usr/bin/env python3
"""Interrupts that arrive while INT 1Bh waits for the FDC run on the caller's
stack, as under NEC's BIOS, which never leaves it: Laplace no Ma's timer
handler reads its jump targets through SS and jumped into data when it
interrupted a read on the BIOS's private stack. The request itself still keeps
the caller's stack free below its IRET frame: Metal Orange's PRECO-IPL keeps
its sector table 58 bytes below SP."""
import struct
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from pc98 import PC98, ROOT
from core_rom import ROMS

IMAGE = ROMS / 'rusty' / 'Rusty (System disk).D88'
BUF = 0x2000                     # segment of the read buffer (20000h)
CALLER_SS, CALLER_SP = 0x0600, 0x0800
FREE = 48                        # bytes below SP a request may use, with an interrupt
failures = []


def check(name, cond, detail=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  {detail}' if detail and not cond else ''))
    if not cond:
        failures.append(name)


def probe(m, vector, org):
    """Chain tests/irq_stack_probe.asm in front of `vector`; returns a reader
    for (entries on another SS, lowest SP, entries)."""
    sys.path.insert(0, str(ROOT / 'tools'))
    from build import nasm
    out_bin = ROOT / 'build' / f'irq_stack_probe_{org:x}.bin'
    nasm(ROOT / 'tests' / 'irq_stack_probe.asm', out_bin, defines=[f'ORG={org:#x}'])
    m.u.mem_write(org, out_bin.read_bytes())
    m.u.mem_write(org + 0x40, m.mem(vector * 4, 4))
    m.u.mem_write(org + 0x44, struct.pack('<H', CALLER_SS))
    m.u.mem_write(vector * 4, struct.pack('<HH', org, 0))
    return lambda: struct.unpack_from('<3H', m.mem(org + 0x46, 6))


def main():
    m = PC98(ROOT / 'build/boot.rom')
    m.run(until=lambda m: 'No bootable' in m.text_screen(), seconds=3)
    m.mount(0, IMAGE)
    disk = m.fdc.drives[0]
    track = lambda c, h: b''.join(bytes(s.data) for s in sorted(disk.tracks[(c, h)], key=lambda s: s.r))
    fdc = probe(m, 0x13, 0x7400)
    vsync = probe(m, 0x0a, 0x7500)
    m.pic[0].imr &= ~0x04                      # IR2 (VSYNC)
    top = CALLER_SS * 16 + CALLER_SP
    m.u.mem_write(top - 512, b'\xa5' * (512 - FREE))
    out = m.call_int(0x1b, ax=0x0790, ss=CALLER_SS, sp=CALLER_SP)
    check('recalibrate', not out['cf'], hex(out['ax']))
    for c, h, r, count in [(0, 0, 1, 1), (5, 1, 3, 4), (40, 0, 7, 2), (12, 1, 4, 3), (0, 0, 1, 8)]:
        m.u.mem_write(BUF * 16, b'\xee' * (count * 1024))
        out = m.call_int(0x1b, ax=0x5690, bx=count * 1024, cx=0x0300 | c, dx=(h << 8) | r,
                         es=BUF, bp=0, ss=CALLER_SS, sp=CALLER_SP)
        want = track(c, h)[(r - 1) * 1024:(r - 1 + count) * 1024]
        check(f'read C{c} H{h} R{r} x{count}', not out['cf'] and m.mem(BUF * 16, count * 1024) == want,
              hex(out['ax']))
    other, low, count = fdc()
    check('FDC interrupts during the requests', count > 0, count)
    check("FDC interrupts on the caller's stack", count > 0 and other == 0, f'{other} of {count} on another SS')
    check("FDC interrupts within 24 bytes of the caller's SP", CALLER_SP - low <= 24, f'lowest SP {low:#06x}')
    other, low, count = vsync()
    check("VSYNC interrupts on the caller's stack", other == 0, f'{other} of {count} on another SS')
    check(f"caller's stack untouched {FREE} bytes below SP", m.mem(top - 512, 512 - FREE) == b'\xa5' * (512 - FREE))
    print('FAILED:' if failures else 'ALL PASS', ', '.join(failures))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
