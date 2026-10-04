#!/usr/bin/env python3
"""INT 1Bh floppy services against image contents (read, multi-sector,
multi-track, read ID, sense, write, errors)."""
import sys
from pathlib import Path
from unicorn import UC_HOOK_CODE
from unicorn.x86_const import UC_X86_REG_AX
sys.path.insert(0, str(Path(__file__).parent))
from pc98 import PC98, ROOT
from core_rom import ROMS

IMAGE = ROMS / 'rusty' / 'Rusty (System disk).D88'
BUF = 0x2000                     # segment of the test buffer (20000h)
failures = []


def check(name, cond, detail=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  {detail}' if detail and not cond else ''))
    if not cond:
        failures.append(name)


def machine():
    m = PC98(ROOT / 'build/boot.rom')
    m.run(until=lambda m: 'No bootable' in m.text_screen(), seconds=3)
    m.mount(0, IMAGE)
    return m


def read(m, c, h, r, n, size, ah=0x56, al=0x90):
    m.u.mem_write(BUF * 16, b'\xee' * size)
    out = m.call_int(0x1b, ax=(ah << 8) | al, bx=size, cx=(n << 8) | c, dx=(h << 8) | r,
                     es=BUF, bp=0)
    return out, m.mem(BUF * 16, size)


def main():
    m = machine()
    disk = m.fdc.drives[0]
    track = lambda c, h: b''.join(bytes(s.data) for s in sorted(disk.tracks[(c, h)], key=lambda s: s.r))
    out = m.call_int(0x1b, ax=0x0390)
    check('init', out['ax'] >> 8 == 0 and not out['cf'], out)
    out = m.call_int(0x1b, ax=0x8490)
    check('sense 2HD ready', out['ax'] >> 8 in (0x01, 0x09, 0x11, 0x19) and not out['cf'], hex(out['ax']))
    out = m.call_int(0x1b, ax=0x4a90, cx=0x0005, dx=0x0100)
    check('read ID', not out['cf'] and out['cx'] == 0x0300 and out['dx'] >> 8 == 1 and 1 <= out['dx'] & 0xff <= 8, {k: hex(v) for k, v in out.items()})
    for c, h, r, count in [(0, 0, 1, 1), (0, 0, 1, 8), (5, 1, 3, 4), (12, 1, 4, 3), (40, 0, 7, 2)]:
        out, data = read(m, c, h, r, 3, count * 1024)
        want = track(c, h)[(r - 1) * 1024:(r - 1 + count) * 1024]
        check(f'read C{c} H{h} R{r} x{count}', not out['cf'] and data == want,
              f"ah={out['ax'] >> 8:02x} first diff {next((i for i in range(len(want)) if data[i] != want[i]), None)}")
    # multi-track: 12 sectors from head 0 R1 -> continues on head 1
    out, data = read(m, 3, 0, 1, 3, 12 * 1024, ah=0xd6)
    want = track(3, 0) + track(3, 1)[:4 * 1024]
    check('multi-track read', not out['cf'] and data == want, hex(out['ax']))
    # no MT past the end of the track: error 30h/other, not silent wrap
    out, data = read(m, 3, 0, 7, 3, 3 * 1024, ah=0x56)
    check('read past EOT without MT fails', out['cf'], hex(out['ax']))
    # missing sector
    out, data = read(m, 0, 0, 30, 3, 1024)
    check('missing sector -> C0h/E0h', out['cf'] and out['ax'] >> 8 in (0xc0, 0xe0), hex(out['ax']))
    # DMA boundary
    m.u.mem_write(0x2fc00, bytes(2048))
    out = m.call_int(0x1b, ax=0x5690, bx=2048, cx=0x0300, dx=0x0001, es=0x2fc0, bp=0)
    check('DMA 64K boundary -> 20h', out['cf'] and out['ax'] >> 8 == 0x20, hex(out['ax']))
    # write then read back (copy-on-write image in the model)
    m.u.mem_write(0x30000, bytes(range(256)) * 4)
    out = m.call_int(0x1b, ax=0x5590, bx=1024, cx=0x0302, dx=0x0003, es=0x3000, bp=0)
    check('write sector', not out['cf'], hex(out['ax']))
    out, data = read(m, 2, 0, 3, 3, 1024)
    check('read back written sector', data == bytes(range(256)) * 4)
    # verify 10 sectors across the head boundary (MT)
    m.u.mem_write(BUF * 16, b'\x55' * 16)
    out = m.call_int(0x1b, ax=0xd190, bx=10 * 1024, cx=0x0304, dx=0x0003, es=BUF, bp=0)
    check('verify multi-track', not out['cf'] and out['ax'] >> 8 == 0 and out['bx'] == 10 * 1024
          and m.mem(BUF * 16, 16) == b'\x55' * 16, hex(out['ax']))
    out = m.call_int(0x1b, ax=0x5190, bx=1024, cx=0x0304, dx=0x001e, es=BUF, bp=0)
    check('verify missing sector fails', out['cf'], hex(out['ax']))
    # not ready: drive 1 empty
    out = m.call_int(0x1b, ax=0x5691, bx=1024, cx=0x0300, dx=0x0001, es=BUF, bp=0)
    check('empty drive -> 60h', out['cf'] and out['ax'] >> 8 == 0x60, hex(out['ax']))
    # Exercise the V86 DMA protocol without asking Unicorn's real-mode BIOS
    # harness to run EMM386. Override only SMSW's PE result, then reject the
    # global command writes EMM386 rejects. Hardware covers the full monitor.
    virtual = machine()
    code = virtual.mem(0xf8000, 0x8000)
    smsw = bytes.fromhex('0f01e0')
    check('one DMA mode detector', code.count(smsw) == 1)
    if code.count(smsw) == 1:
        next_pc = 0xf8000 + code.index(smsw) + len(smsw)
        def pe_result(u, address, size, data):
            u.reg_write(UC_X86_REG_AX, u.reg_read(UC_X86_REG_AX) | 1)
        virtual.u.hook_add(UC_HOOK_CODE, pe_result, begin=next_pc, end=next_pc)
        original_write = virtual.dma.write
        pointer_resets = []
        def virtual_dma_write(port, value):
            if port == 0x11:
                raise AssertionError('BIOS changed global DMA command under EMM386')
            if port == 0x19:
                pointer_resets.append(value)
            original_write(port, value)
        virtual.dma.write = virtual_dma_write
        want = bytes(virtual.fdc.drives[0].tracks[(0, 0)][0].data)
        for phase in (False, True):
            virtual.dma.ch[2].flip = phase
            out, data = read(virtual, 0, 0, 1, 3, 1024)
            check(f'virtual DMA read after byte phase {int(phase)}',
                  not out['cf'] and data == want, hex(out['ax']))
        virtual.dma.ch[2].flip = True
        payload = bytes(range(256)) * 4
        virtual.u.mem_write(0x30000, payload)
        out = virtual.call_int(0x1b, ax=0x5590, bx=1024, cx=0x0302,
                               dx=0x0003, es=0x3000, bp=0)
        check('virtual DMA write', not out['cf'], hex(out['ax']))
        virtual.dma.ch[2].flip = True
        out, data = read(virtual, 2, 0, 3, 3, 1024)
        check('virtual DMA write/readback', not out['cf'] and data == payload)
        check('virtual DMA reset before each transfer', len(pointer_resets) == 4)
        check('virtual DMA command preserved', virtual.dma.command == 0x40)
    print('FAILED:' if failures else 'ALL PASS', ', '.join(failures))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
