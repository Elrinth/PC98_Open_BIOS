#!/usr/bin/env python3
"""Keyboard (INT 09h/18h), timer (INT 1Ch), printer (INT 1Ah), RS-232C
(INT 19h) and extended-memory move (INT 1Fh) services."""
import struct
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from pc98 import PC98, ROOT
from unicorn.x86_const import UC_X86_REG_CR0

failures = []


def check(name, cond, detail=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  {detail}' if detail and not cond else ''))
    if not cond:
        failures.append(name)


def main():
    m = PC98(ROOT / 'build/boot.rom')
    m.run(until=lambda m: 'No bootable' in m.text_screen(), seconds=3)

    # ---- keyboard
    m.call_int(0x18, ax=0x0300)                       # keyboard init (empties buffer)
    m.type_keys([0x1d, 0x9d])                          # A make/break
    m.run(seconds=0.02)
    out = m.call_int(0x18, ax=0x0100)
    check('INT 18h 01h sense', out['bx'] >> 8 == 1 and out['ax'] == 0x1d61, hex(out['ax']))
    out = m.call_int(0x18, ax=0x0000)
    check('INT 18h 00h read a', out['ax'] == 0x1d61, hex(out['ax']))
    m.type_keys([0x70, 0x1d, 0x9d, 0xf0])             # shift + A
    m.run(seconds=0.03)
    out = m.call_int(0x18, ax=0x0000)
    check('shifted A', out['ax'] == 0x1d41, hex(out['ax']))
    out = m.call_int(0x18, ax=0x0200)
    check('shift released', out['ax'] & 0xff == 0, hex(out['ax']))
    m.type_keys([0x3a])                                # cursor up held
    m.run(seconds=0.01)
    out = m.call_int(0x18, ax=0x0407)                  # group 7: keys 38h-3Fh
    check('INT 18h 04h key group', out['ax'] >> 8 == 0x04, hex(out['ax']))
    out = m.call_int(0x18, ax=0x0000)
    check('cursor up code', out['ax'] == 0x3a00, hex(out['ax']))
    m.type_keys([0xba])
    out = m.call_int(0x18, ax=0x0500)
    check('INT 18h 05h empty', out['bx'] >> 8 == 0, hex(out['bx']))

    # ---- interval timer: 3 x 10 ms then the callback at 0000:7100
    m.u.mem_write(0x7100, bytes.fromhex('c606ff7001 cf'))   # mov byte [70FFh],1; iret
    m.u.mem_write(0x70ff, b'\0')
    t0 = m.now
    m.call_int(0x1c, ax=0x0200, cx=3, es=0, bx=0x7100)
    m.run(until=lambda m: m.byte(0x70ff) == 1, seconds=0.2)
    elapsed = m.now - t0
    check('INT 1Ch 02h interval', m.byte(0x70ff) == 1 and 0.015 < elapsed < 0.045, f'{elapsed:.4f}s')   # first tick may be early (latched edge)

    # ---- calendar round trip
    m.call_int(0x1c, ax=0x0000, es=0, bx=0x600)
    cal = m.mem(0x600, 6)
    check('INT 1Ch 00h calendar', cal[0] == 0x26 and cal[1] >> 4 == 9 and cal[2] == 0x26, cal.hex())

    # ---- printer (core: port 42h bit 2 = 1, ready)
    out = m.call_int(0x1a, ax=0x1000)
    check('INT 1Ah 10h init', out['ax'] >> 8 == 1, hex(out['ax']))
    out = m.call_int(0x1a, ax=0x1141)
    check('INT 1Ah 11h print', out['ax'] >> 8 == 1 and (0x40, 0x41) in m.ports_out[-3:], hex(out['ax']))

    # ---- RS-232C
    out = m.call_int(0x19, ax=0x0004, cx=0x4e37, bx=0, dx=64, es=0x5000, di=0)
    blk = m.mem(0x50000, 0x14)
    check('INT 19h init', out['ax'] >> 8 == 0 and blk[2] & 0x80 and m.word(0x556) == 0 and m.word(0x558) == 0x5000,
          blk.hex())
    out = m.call_int(0x19, ax=0x0200)
    check('INT 19h 02h count', out['ax'] >> 8 == 0 and out['cx'] == 0)
    out = m.call_int(0x19, ax=0x0400)
    check('INT 19h 04h no data', out['ax'] >> 8 == 3, hex(out['ax']))

    # ---- INT 1Fh 90h: move 16 bytes from 20000h to 1200000h (18 MB)
    m.u.mem_write(0x20000, bytes(range(16)))
    gdt = bytearray(48)
    struct.pack_into('<HI', gdt, 0x10, 0xffff, 0x020000)
    struct.pack_into('<HI', gdt, 0x18, 0xffff, 0x200000)   # 24-bit base: 2 MB
    m.u.mem_write(0x21000, bytes(gdt))
    out = m.call_int(0x1f, ax=0x9000, es=0x2100, bx=0, cx=16, si=0, di=0x100)
    check('INT 1Fh 90h block move', not out['cf'] and m.mem(0x200100, 16) == bytes(range(16)))

    # ---- INT 1Fh 91h: enter protected mode with the caller's descriptors
    gdt = bytearray(0x40)
    def desc(off, base, limit, access):
        struct.pack_into('<HHBBBB', gdt, off, limit & 0xffff, base & 0xffff, (base >> 16) & 0xff,
                         access, (limit >> 16) & 0x0f, (base >> 24) & 0xff)
    struct.pack_into('<HI', gdt, 0x08, 0x3f, 0x22000)            # GDT pseudo-descriptor
    struct.pack_into('<HI', gdt, 0x10, 0x7ff, 0x23000)           # IDT
    desc(0x18, 0x40000, 0xffff, 0x93)
    desc(0x20, 0x50000, 0xffff, 0x93)
    desc(0x28, 0x00000, 0xffff, 0x93)
    desc(0x30, 0x00000, 0xffff, 0x9b)
    m.u.mem_write(0x22000, bytes(gdt))
    out = m.call_int(0x1f, ax=0x9100, es=0x2200, bx=0, dx=0x2028)
    cr0 = m.u.reg_read(UC_X86_REG_CR0)
    check('INT 1Fh 91h protected mode', cr0 & 1 and m.reg('cs') == 0x30 and m.reg('ds') == 0x18
          and m.reg('ss') == 0x28 and m.pic[0].base == 0x20 and m.pic[1].base == 0x28,
          (hex(cr0), m.regs('cs', 'ds', 'ss')))

    print('FAILED:' if failures else 'ALL PASS', ', '.join(failures))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
