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
        if 'A' <= ch <= 'Z':
            code = PLAIN[ch.lower()]
            m.type_keys([0x70, code, code | 0x80, 0xF0])
        elif ch in SHIFTED:
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


def test_erase():
    m = basic_direct()
    program = [
        '10 dim a%(10),b%(20),c%(5):b%(3)=7:c%(5)=9',
        '20 erase a%:print b%(3);c%(5);',
        '30 dim a%(30):a%(30)=4:print a%(30);b%(3);c%(5);',
        '40 erase b%,c%:dim b%(2):b%(2)=3:print b%(2);a%(30)',
        '50 clear ,&h3000:dim x%(3000):for i=1 to 40:erase x%:dim x%(3000):next:print "freed"',
        'run',
    ]
    for line in program:
        type_text(m, line + '\n')
    m.run(seconds=1)
    screen = m.text_screen()
    check('ERASE keeps the other arrays', ' 7  9  4  7  9  3  4' in screen, screen)
    check('ERASE gives the memory back', 'freed' in screen, screen)


def test_put_kanji():
    m = basic_direct()
    type_text(m, 'cls 3:put @(16,8),kanji(&h3021),pset,0,7\n')
    counts = [sum(bin(b).count('1') for b in p) for p in m.planes()[:3]]
    # white 16x16 box with the glyph in black: the same pattern in every plane
    check('PUT @ KANJI draws a glyph on its background', 0 < counts[0] < 256 and len(set(counts)) == 1,
          counts)


def test_memory_and_calendar():
    import datetime
    m = basic_direct()
    check('BASIC publishes conventional RAM ceiling', word(m, 0x600 + 0x1402) == 0xA000)
    type_text(m, 'def seg=&h60:m=(peek(&h1402)+peek(&h1403)*256)-&h800:clear ,m\n')
    type_text(m, 'print "clear-ok"\n')
    screen = m.text_screen()
    check('CLEAR accepts a calculated unsigned address', 'Overflow' not in screen and
          'clear-ok' in screen and word(m, 0x600 + 0xBF2) == 0x9800, screen)
    m.rtc.base = datetime.datetime(2026, 12, 31, 23, 45, 0)
    m.rtc.offset = -m.now
    type_text(m, 'print date$;" ";left$(time$,5)\n')
    check('DATE$ handles month 12 and TIME$ uses the RTC',
          '26/12/31 23:45' in m.text_screen(), m.text_screen())
    type_text(m, 'print val(mid$(time$,4,2))*60+val(mid$(time$,7,2))\n')
    type_text(m, 'print val(mid$(date$,4,2))*60+val(right$(date$,2))\n')
    check('calendar strings compose inside expressions', ' 751' in m.text_screen(), m.text_screen())


def test_get_graphics():
    m = basic_direct()
    type_text(m, 'screen 0:dim a%(100),b%(1):b%(0)=1234\n')
    type_text(m, 'line (0,0)-(7,7),3,bf:get@(0,0)-(7,7),a%\n')
    type_text(m, 'cls 1:put@(16,16),a%,pset:print point(16,16);point(23,23);b%(0)\n')
    screen = m.text_screen()
    check('GET@ and PUT@ preserve a colour rectangle', ' 3  3  1234' in screen, screen)
    type_text(m, 'get@(0,0)-(7,7),a%(10):put@(32,16),a%(10),pset\n')
    check('GET@ accepts a subscripted destination', 'Illegal function call' not in m.text_screen())
    type_text(m, 'get@(0,0)-(639,399),b%\n')
    screen = m.text_screen()
    check('GET@ rejects a destination array that is too small', 'Illegal function call' in screen, screen)
    type_text(m, 'print b%(0)\n')
    check('rejected GET@ leaves array contents intact', m.text_screen().count('1234') >= 2, m.text_screen())


def test_call_arguments():
    m = basic_direct()
    # Synthetic IRET routine: add LEN(rightmost string)+1 to the left integer.
    # push es; les di,[bx]; mov al,es:[di]; xor ah,ah; inc ax;
    # les di,[bx+4]; add es:[di],ax; pop es; iret.
    m.u.mem_write(0x80000, bytes.fromhex('06 c4 3f 26 8a 05 30 e4 40 c4 7f 04 26 01 05 07 cf'))
    type_text(m, 'def seg=&h8000:r%=0:x%=10:s$="abc":call r%(x%,s$):print x%\n')
    screen = m.text_screen()
    check('CALL passes numeric and string variables by reference', ' 14' in screen, screen)
    type_text(m, 'dim a%(2):a%(0)=42:call r%(a%(0),zz$):print a%(0)\n')
    screen = m.text_screen()
    check('CALL keeps array pointers valid when later arguments create variables', ' 43' in screen, screen)
    m.u.mem_write(0x1240, bytes(4))  # F_SEED: reset the deterministic RND generator
    type_text(m, 'call r%(a%(rnd(1)*0),s$)\n')
    check('CALL evaluates an array subscript only once',
          struct.unpack('<I', m.mem(0x1240, 4))[0] == 2531011)



def test_disk_character_encoding():
    m = basic_direct()
    type_text(m, 'cls:print chr$(&h87);chr$(&h87);\n')
    check('disk BASIC keeps block graphics as single-byte characters',
          bytes(m.mem(0xA0000, 4)) == bytes.fromhex('87 00 87 00'))
    type_text(m, 'cls:print chr$(27);"K";"4A;z";chr$(27);"H";"x";\n')
    check('ESC K/H selects JIS kanji and returns to ANK',
          bytes(m.mem(0xA0000, 10)) == bytes.fromhex('14 41 94 41 1b 7a 9b 7a 78 00'),
          bytes(m.mem(0xA0000, 10)).hex())


def test_compound_comparisons():
    m = basic_direct()
    type_text(m, 'print 1<>59;59<>1;1<>1;1<=2;2<=2;3<=2\n')
    check('compound integer comparisons preserve both operators',
          '-1 -1  0 -1 -1  0' in m.text_screen(), m.text_screen())
    type_text(m, 'print 3>=2;2>=2;1>=2;(3/2)<>2;(3/2)<=2;(5/2)>=2\n')
    check('compound comparisons also handle single precision',
          '-1 -1  0 -1 -1 -1' in m.text_screen(), m.text_screen())
    type_text(m, 'print 1<>59 or len("abc")=60;"a"<>"b";"a"<="a"\n')
    check('not-equal composes with OR and string comparison',
          '-1 -1 -1' in m.text_screen(), m.text_screen())


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


def test_five_gals():
    image = next(ROMS.glob('*/Five Gals Connection.nfd'), ROMS / 'Five Gals Connection.nfd')
    if not image.exists():
        print('SKIP Five Gals Connection (image not available)')
        return
    m = PC98(ROOT / 'build/boot.rom')
    m.mount(0, image)
    m.run(seconds=4)
    title = list(range(1000, 1100)) + list(range(9000, 9300))
    line = word(m, 0x600 + 0x6E4)
    drawn = [sum(1 for b in p if b) for p in m.planes()]
    # CLEAR ,&H3000 and DIM GRA(5000): fits with the disk's one file buffer
    check('Five Gals Connection: title drawn, waiting for a key', line in title and drawn[0] > 5000,
          (line, drawn))
    m.type_keys([0x1C, 0x9C])
    m.run(seconds=6)
    line = word(m, 0x600 + 0x6E4)
    check('Five Gals Connection: the round starts (ERASE)', line not in title and line < 50000, line)
    for _ in range(20):                 # no input: the player loses three lives
        if word(m, 0x600 + 0x6E4) in (2680, 2690):
            break
        m.run(seconds=1)
    right = sum(bin(b).count('1') for row in range(400) for b in m.planes()[0][row * 80 + 40:row * 80 + 80])
    check('Five Gals Connection: GAME OVER drawn with PUT @ KANJI', right > 2000, right)


if __name__ == '__main__':
    test_direct()
    test_erase()
    test_put_kanji()
    test_memory_and_calendar()
    test_get_graphics()
    test_call_arguments()
    test_disk_character_encoding()
    test_compound_comparisons()
    test_hokuto()
    test_five_gals()
    sys.exit(1 if failures else 0)
