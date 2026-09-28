#!/usr/bin/env python3
"""POST with no boot media: work area, memory count and the no-system screen."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from pc98 import PC98, ROOT
from unicorn.x86_const import UC_X86_REG_CS, UC_X86_REG_EIP


def main():
    m = PC98(ROOT / 'build/boot.rom', total_mb=64)
    ok = m.run(seconds=3, until=lambda m: b'N\x00o\x00 \x00b' in m.mem(0xa0000 + 160*10 + 28, 8))
    print(m.text_screen())
    print(f'time {m.now:.3f}s  instructions {m.instructions}')
    print('unknown ports', sorted(m.unknown_ports))
    checks = {
        'reached no-system screen': ok,
        '0401h = 112 (14 MB)': m.byte(0x401) == 112,
        '0594h = 48 MB': m.word(0x594) == 48,
        '0501h V30 bit clear': not m.byte(0x501) & 0x40,
        '0480h = 386+': m.byte(0x480) & 0x0f == 3,
        'INT 18h vector in F800': m.word(0x18*4+2) == 0xf800,
        'keyboard buffer head': m.word(0x524) == 0x502,
        'memory switch 1': m.byte(0xa3fe2) == 0x48,
    }
    # Shutdown resume: SHUT0 = 0, SS:SP at 0404h, CPU reset through F0h.
    # The BIOS must far-return through that stack without touching the PICs.
    m.u.mem_write(0x7100, bytes.fromhex('b86655eb fe'))       # mov ax,5566h; jmp $
    m.u.mem_write(0x6f00, (0x7100).to_bytes(2, 'little') + (0).to_bytes(2, 'little'))
    m.u.mem_write(0x404, (0x6f00).to_bytes(2, 'little') + (0).to_bytes(2, 'little'))
    m.u.mem_write(0x7000, bytes.fromhex('fa b00e e637 b000 e6f0 ebfe'))
    imr = m.pic[0].imr
    m.pic[0].imr = 0x5a                     # a program's own mask
    m.u.reg_write(UC_X86_REG_CS, 0)
    m.u.reg_write(UC_X86_REG_EIP, 0x7000)
    m.halted = False
    m.run(until=lambda m: m.linear_pc() == 0x7103, max_instructions=200000)
    checks['shutdown resume returns via 0404h'] = m.linear_pc() == 0x7103 and m.reg('ax') == 0x5566
    checks['shutdown resume keeps PIC masks'] = m.pic[0].imr == 0x5a and m.cpu_resets == 1
    for k, v in checks.items():
        print(('PASS ' if v else 'FAIL ') + k)
    return 0 if all(checks.values()) else 1


if __name__ == '__main__':
    sys.exit(main())
