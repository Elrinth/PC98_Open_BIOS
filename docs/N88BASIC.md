# N88-BASIC(86) runtime

The open BIOS contains its own N88-BASIC(86)-compatible runtime (`src/basic/`)
so that disk BASIC software runs without NEC's BASIC ROM. It is written from
observed behaviour: programs, disk BASIC modules and games were run on the
reference machine (NP2kai with an owner-supplied ROM) and on the core, and
their memory, interrupt and I/O use was recorded. No NEC code is copied; the
reference ROM was used only to learn interfaces (entry points, work-area
fields, the program-text format, token values) and behaviour.

Status: enough to run disk BASIC programs that mainly use BASIC for program
flow and machine code for graphics, such as Hokuto no Ken (Enix, 1986).
Numbers are 16-bit integers; floating point, arrays, file I/O, graphics
statements beyond SCREEN/COLOR/CLS, sound (`CMD`) and program listing are
not there yet (they stop with "Feature not available" and the line number).

## Start-up

| Address | Use |
|---|---|
| E800:0000 | INT 1Eh / no system disk: the open BIOS "no bootable disk" screen |
| E800:0002 | disk BASIC: the system disk's IPL loads the disk BASIC module to 1000:0000, sets 0000:0500h bit 6 and 0060:0505h = 1, then jumps here |
| E800:000A | INT 1Eh while BASIC runs: back to direct mode |

The disk BASIC module consists of 8 KiB blocks at 1000h, 1200h, 1400h, ...
Each block starts with a vector directory, the same format as the LIO
directory at F990:0000: `dw count, dw flags, {db INT, db 0, dw offset} * count`.
BASIC installs those vectors with the block's segment (for the module on
Hokuto no Ken: B0h, B4h at 1000h; C6h, C7h at 1200h; D0h at 1400h) and then
calls the module, with the registers NEC's BASIC uses:

1. INT C6h, DI = 2Dh (AX = 0, BX = 1): drive initialisation.
2. INT B4h, BP = text start (1D00h): module start-up; returns BP = new text
   start (the module keeps its buffers below it), stored at 0060:06A4h.
3. INT C6h, DI = 34h, when the word at 1200:0002 is FFFFh.
4. INT C6h, DI = 2Eh: the module writes the autostart command (ASCII) to the
   line buffer at [0060:1406h] (= 0202h) and returns its length in CX.

BASIC tokenises and runs the command in direct mode (line number FFFFh). For
Hokuto no Ken it is `cls 1:console 0,25,0,1:def seg=&h1200:sub=&h5000:call sub`;
the machine code loads the program text to [0060:06A4h], sets the end at
[0060:06A6h] and asks BASIC to run it with INT C4h, DI = 1Bh.

## Memory

| Segment:offset | Contents |
|---|---|
| 0060:0202h | line buffer (ASCII), its offset at 0060:1406h |
| 0060:0500h-050Fh, 1596h-159Bh | disk module variables |
| 0060:0620h-0637h, 0A08h | LIO work area (BASIC calls LIO with DS = 0060h) |
| 0060:06A4h / 06A6h | program text start / end |
| 0060:06E4h | current line number (FFFFh in direct mode) |
| 0060:1410h | segment of variables and strings (VSEG) |
| 0060:1D00h-[06A4h] | disk module buffers |
| 0060:[06A4h] | program text |
| VSEG:0100h | variables |
| VSEG:top | strings grow down from the top set by `CLEAR ,top` |

VSEG follows the module: the paragraph after its last 8 KiB block (1600h for
a 24 KiB module). Programs depend on it - Hokuto no Ken's machine code reads
BASIC strings at 1600h:pointer.

## Program text

Lines are `dw length, dw line number, tokens, db 0`; the program ends with a
zero length. The length is relative (the next line follows directly).

| Bytes | Meaning |
|---|---|
| 01h-0Ah | 1-10 blanks |
| 0Bh nnnn / 0Ch nnnn | &O / &H constant |
| 0Eh nnnn | line number (after GOTO, GOSUB, THEN, ELSE, ...) |
| 0Fh nn | integer 10-255 |
| 10h-19h | integers 0-9 |
| 1Ch nnnn | integer |
| 1Dh, 4 bytes / 1Fh, 8 bytes | single / double precision (Microsoft binary format) |
| 80h-FEh | statement and operator tokens |
| FFh, n\|80h | function n |
| letter, count, rest[, type] | variable name (`SUB` = 53h 02h 55h 42h) |
| 00h, text | `'` comment: the rest of the line is not executed |

Strings and DATA are stored as text. Token values are listed in
`docs/n88_keywords.txt`, from which `tools/gen_basic_tables.py` generates
`src/basic/tokens.inc` and `src/basic/kwtable.inc`.

## Variables

A string variable's value is a descriptor `db length, db 0, dw pointer`
(pointer into VSEG); `VARPTR(v)` returns the VSEG offset of the value and
`VARPTR(v,1)` the segment. Literals and DATA are copied into VSEG on
assignment.

## Machine code

| | |
|---|---|
| `CALL v` | INT C3h with the vector set to DEF SEG:v |
| `USRn(x)` | INT C3h with the vector set to the address from `DEF USRn` |
| registers | DS = ES = 0060h, BX -> argument (FAC), AL = its type, CX = 0060h, DX = VSEG; the routine ends with IRET |

## Services

| INT | Function |
|---|---|
| C4h, DI = 1Bh | run the program from [0060:06A4h] (end [0060:06A6h]) |
| 9Eh | clear the keyboard buffer |

Unused vectors keep the BIOS's IRET.

## Measuring a new program

The NP2kai build used for the measurements has hooks (environment
variables) that log RAM/ROM transitions into E8000h-F7FFFh, interrupt entries,
work-area reads and writes by non-ROM code, and memory snapshots at given
CS:IP. For a new disk BASIC game, record which work-area fields, interrupts
and statements it uses and compare the open BIOS run with the reference.
