# Open PC-98 BIOS for the Zet98-486 MiSTer core

A from-scratch, freely licensed system BIOS for the
[Zet98-486 MiSTer core](https://github.com/Elrinth/Zet98_486_MiSTer) (puu's Zet/98 with the
z486 CPU, 64 MB RAM, GRCG/PEGC). It replaces NEC's copyrighted `boot.rom`
code and knows about the core's 486 and extended memory from the start: no
V30 flag, 0401h/0594h filled in by POST, PC-9821 identification.

**Status (2026-09-29): runs on the MiSTer with core B218.** It boots MS-DOS
6.20 from VHD; games tested with it include Rusty, Flame Zapper Kotsujin,
E.V.O. (LIO), Black Thorne, Nightslave and Lemmings. See the core's
[game setup notes](https://github.com/Elrinth/Zet98_486_MiSTer#game-setup-notes).

## Using it on the MiSTer

1. Download the zip from this repository's
   [Releases](https://github.com/Elrinth/PC98_Open_BIOS/releases) and unzip
   `boot.rom` (or build it, below). It includes the free font.
2. Copy it to `/media/fat/games/PC98/boot.rom` (back up any existing file).
3. Load the core. An OSD reset does not reload `boot.rom`; reload the core
   after replacing it.

## What it does

| Area | Implementation |
|---|---|
| POST | CPU-reset/shutdown resume (0404h), ITF bank off, PIC/PIT/DMA/GDC/palette init, VRAM clear, extended-RAM count (14 MB + 48 MB on the 64 MB core), work area, memory switches, extension-ROM scan (the core's disk ROM at D0000h) |
| Boot | extension ROMs first (hard disk), then floppy drives 0/1 (2HD, then 2DD; MFM, then FM), IPL to 1FC0:0000 / 1FE0:0000, `FD80:091E` restart entry used by MS-DOS, "no system" screen instead of N88-BASIC |
| INT 09h/18h keyboard | 8251 IRQ handler, key tables (normal/shift/CAPS/kana/GRPH/CTRL), buffer, AH=00h-05h |
| INT 18h text | modes (20/25 lines, 40/80 columns), display on/off, single/multiple areas, cursor form/on/off/position, font read (8x8, 8x16, 16x16 via the CG ports), text VRAM fill, beep, user characters, KCG mode |
| INT 18h graphics | 40h-43h, 4Ah display/area/palette/draw mode; **45h-49h figure drawing through the graphics uPD7220** (lines, rectangles, circles/arcs, graphic characters, dot patterns); **30h/31h 31 kHz modes incl. 640x480** (20/25/30 text lines, 256-colour PEGC page) when the core supports it, 4Dh 256-colour switch |
| INT 1Bh floppy | uPD765 + 8237 driver written against the core's FDC: read/write/verify/deleted data/read diagnostic/read ID/format/seek/recalibrate/sense/mode set, 2HD/2DD/2D, multi-track, DMA 64 KiB boundary check, NEC status codes and result area; hard disk via the core's disk ROM |
| INT 1Ch | uPD4990 calendar read/write, 10 ms interval timer (IRQ0 + INT 07h user routine) |
| INT 19h/1Ah | RS-232C control-block API, printer (NEC layout, including MS-DOS's vector+19h shortcut) |
| INT 1Fh | 90h extended-memory block move, 91h switch to protected mode |
| INT A0h-AFh | **LIO graphics BIOS**: GINIT, GSCREEN, GVIEW, GCOLOR1/2, GCLS, GPSET, GLINE (styles, boxes, tiles), GCIRCLE (ellipses, arcs, fills), GPAINT1/2, GGET, GPUT1/2, GROLL, GPOINT2 |
| Fixed addresses | FD80:0000 reset, FD80:091E restart, FD80:0E00 key tables, F8E8:0000 PC-9821 feature table, FFFF0h reset vector ([details](docs/FIXED_ADDRESSES.md)) |

Character generator: a free font built from the public-domain Shinonome
fonts plus generated PC-98 graphics and NEC special characters
([docs/FONT.md](docs/FONT.md)); `tools/build.py` uses it by default.

640x480 needs a small core change (text GDC SYNC active lines -> 480 visible
lines, port 09A8h): `docs/core-480line.patch`, branch `open-bios-480line` in
the core repository (see its `rtl/LINES480.md`). Without it the BIOS refuses
INT 18h AH=30h, as on a machine without 31 kHz support.

Not included: N88-BASIC, a sound-board BIOS (INT D2h), mouse BIOS, SCSI.

## Layout

| Path | Contents |
|---|---|
| `src/bios.asm` | top level: the E800/F000/F800 banks and fixed addresses |
| `src/post.asm`, `src/boot.asm` | POST and boot (F000h bank) |
| `src/runtime.asm`, `int18*.asm`, `gdc_draw.asm`, `int1b.asm`, `int1c.asm`, `misc_int.asm` | resident services (F800h bank) |
| `src/lio.asm`, `src/basic_stub.asm` | LIO and the no-system screen (E800h bank) |
| `tools/build.py` | assembles `build/bios.bin` (96 KiB) and packs `build/boot.rom` |
| `tools/mkfont.py` | builds the character generator from BDF fonts |
| `tests/pc98.py` (+ `fdd.py`, `gdc_draw.py`) | Unicorn-based PC-98 model of the core's hardware |
| `tests/test_*.py`, `tests/run_all.py` | behavioural tests |
| `docs/CORE_HARDWARE.md` | what the core's hardware really does (ports, FDC, DMA, PIC quirks) |

## Building and testing

```sh
python tools/build.py                              # free font from font/pc98font.rom
python tools/build.py --font other_font.rom        # another FONT.ROM-layout font (docs/FONT.md)
python tests/run_all.py --font-from-bootrom ../zet98_roms_for_dev/boot.rom
```

NASM comes from `PATH` or the core's `zet98-dos-tools` Docker image. Tests need
Python 3 with `unicorn`, `capstone`, `numpy` and `Pillow`; the DOS/floppy tests
use the private disk images in `../zet98_roms_for_dev`. `--font-from-bootrom`
borrows the NEC font from an owner `boot.rom` for local testing only - never
distribute such a build.

The suites cover: POST and shutdown resume; keyboard, timer, calendar,
printer, RS-232C, INT 1Fh 90h/91h; every floppy service against image
contents; floppy boot (Rusty, Misty Blue, Metal Force disks); INT 18h figure
drawing; all LIO functions; MS-DOS 6.20 boot from VHD to `A:\>`.

## License

0BSD (see `LICENSE`): use it for anything. The keyboard table derived from
NP2kai keeps its BSD-3-Clause notice (`LICENSES/NP2kai.txt`), which must
accompany binary releases.

## Clean-room rules

- NEC ROM code is never copied, disassembled into the tree or paraphrased; the
  owner `boot.rom` may only be *executed* in local comparisons.
- NP2kai (BSD-3-Clause) is the behavioural reference for service semantics;
  files that adapt its tables or algorithms say so.
- The shipped character generator must come from freely licensed bitmap fonts.
