#!/usr/bin/env python3
"""N88-BASIC runtime: direct mode, a small program, the tokeniser, and a
disk BASIC game (Hokuto no Ken) when its image is available."""
import struct
import sys
import tempfile
import zipfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from pc98 import PC98, ROOT
from core_rom import ROMS
from unicorn.x86_const import UC_X86_REG_CS, UC_X86_REG_EIP

failures = []


def check(name, cond, detail=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  {detail}' if detail and not cond else ''))
    if not cond:
        failures.append(name)


# PC-98 key codes: unshifted characters, and characters typed with SHIFT
PLAIN = {c: i + 1 for i, c in enumerate('123456789')}
PLAIN.update({'0': 0x0A, '-': 0x0B, '^': 0x0C, '\\': 0x0D, '@': 0x1A, '[': 0x1B, ';': 0x26,
              ':': 0x27, ']': 0x28, ',': 0x30, '.': 0x31, '/': 0x32, ' ': 0x34, '\n': 0x1C})
for row, start in (('qwertyuiop', 0x10), ('asdfghjkl', 0x1D), ('zxcvbnm', 0x29)):
    PLAIN.update({c: start + i for i, c in enumerate(row)})
SHIFTED = {'!': 0x01, '"': 0x02, '#': 0x03, '$': 0x04, '%': 0x05, '&': 0x06, "'": 0x07,
           '(': 0x08, ')': 0x09, '=': 0x0B, '+': 0x26, '*': 0x27, '<': 0x30, '>': 0x31, '?': 0x32}


def type_text(m, text):
    for ch in text:
        if ch in SHIFTED:
            code = SHIFTED[ch]
            m.type_keys([0x70, code, code | 0x80, 0xF0])
        else:
            code = PLAIN[ch]
            m.type_keys([code, code | 0x80])
        m.run(seconds=0.03)
    m.run(seconds=0.5)


def word(m, seg_off):
    return struct.unpack('<H', bytes(m.mem(seg_off, 2)))[0]


def basic_direct():
    """Start BASIC without a disk module (E800:0002 with 0060:0505 = 0)."""
    m = PC98(ROOT / 'build/boot.rom')
    m.run(seconds=1.5)
    m.u.reg_write(UC_X86_REG_CS, 0xE800)
    m.u.reg_write(UC_X86_REG_EIP, 0x0002)
    m.halted = False                    # the no-disk screen waits in HLT
    m.run(seconds=1.5)
    return m


def test_direct():
    m = basic_direct()
    check('direct mode prompt', 'Ok' in m.text_screen())
    type_text(m, 'print 1+2*3;7\\2;-5 mod 3;&h10\n')
    screen = m.text_screen()
    check('PRINT arithmetic', ' 7  3 -2  16' in screen, screen)

    program = [
        '10 a$="ab":b$=a$+"cd"',
        '20 for i=1 to 3:print i;:next',
        '30 gosub 100:print b$;len(b$)',
        '40 if i=4 then print "four" else print "other"',
        '50 read x,y$:print x;y$:end',
        '60 data 42,"dt"',
        '100 print "sub":return',
        'run',
    ]
    for line in program:
        type_text(m, line + '\n')
    m.run(seconds=1)
    screen = m.text_screen()
    check('FOR/NEXT and GOSUB', ' 1  2  3 sub' in screen, screen)
    check('strings and LEN', 'abcd 4' in screen, screen)
    lines = [l.strip() for l in screen.splitlines()]
    check('IF/THEN/ELSE', 'four' in lines and 'other' not in lines, screen)
    check('READ/DATA', ' 42 dt' in screen, screen)

    # tokeniser: the autostart line of an N88-BASIC(86) disk, as NEC stores it
    type_text(m, '65000 cls 1:console 0,25,0,1:def seg=&h1200:sub=&h5000:call sub\n')
    txt = word(m, 0x600 + 0x6A4)
    p = 0x600 + txt
    while word(m, p) and word(m, p + 2) != 65000:
        p += word(m, p)
    length = word(m, p)
    body = bytes(m.mem(p + 4, length - 4))
    nec = bytes.fromhex('01 8f 01 11 3a 84 01 10 2c 0f 19 2c 10 2c 11 3a 98 01 e4 f1 0c 00 12'
                        ' 3a 53 02 55 42 f1 0c 00 50 3a 89 01 53 02 55 42 00')
    check('tokeniser matches NEC', body == nec, body.hex(' '))


def test_hokuto():
    archive = ROMS / 'Hokuto no Ken [FD hdb].zip'
    if not archive.exists():
        print('SKIP Hokuto no Ken (image not available)')
        return
    with tempfile.TemporaryDirectory() as tmp:
        image = Path(tmp) / 'hokuto.d88'
        image.write_bytes(zipfile.ZipFile(archive).read('Hokuto no Ken.d88'))
        m = PC98(ROOT / 'build/boot.rom')
        m.mount(0, image)
        m.run(seconds=10)
        drawn = [sum(1 for b in p if b) for p in m.planes()]
        check('Hokuto no Ken: menu drawn by the game through USR', drawn[:3] == [459, 87, 459], drawn)
        check('Hokuto no Ken: waiting for a key at line 1130', word(m, 0x600 + 0x6E4) == 1130)
        m.type_keys([0x01, 0x81])                       # 1: start from the prologue
        m.run(seconds=8)
        line = word(m, 0x600 + 0x6E4)
        check('Hokuto no Ken: prologue runs', line not in (1125, 1130, 0xFFFF), line)


if __name__ == '__main__':
    test_direct()
    test_hokuto()
    sys.exit(1 if failures else 0)
