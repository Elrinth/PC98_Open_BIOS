# Testing on the MiSTer

The BIOS was developed against the Unicorn model (`tests/`) and has run on
the MiSTer since core B207 (DOS from VHD, floppy games, LIO). This checklist
is the order used for those first hardware runs; use it again after larger
changes.

## Install

1. Build: `python tools/build.py` (free font; or, for a private test,
   `--font-from-bootrom <your boot.rom>`).
2. Back up `/media/fat/games/PC98/boot.rom` and copy `build/boot.rom` there
   (550,912 bytes, same layout as the downloader's file).
3. Load the z486 core (`-RawIde` build for hard disks). A reset in the OSD
   does not reload `boot.rom`; reload the core after replacing it.

## Checklist (in order)

| Step | Expect | If not |
|---|---|---|
| Empty boot ("Start BIOS") | "Open PC-98 BIOS (Zet98-486)" in the top-left corner, then "No bootable disk found" | Blank screen: POST hung before the text GDC START; check GDC init order (RESET clears the 68h flip-flops) |
| Keyboard on that screen | Any key restarts the boot sequence | 8251/IRQ1 path |
| VHD with MS-DOS | DOS banner, `A:\>`; `MEM` shows ~63 MB extended memory; HIMEM/HIMEMX load without Z98MEM | Disk ROM scan / boot dispatch; 0401h/0594h |
| Keyboard typing, `DIR`, `TIME`/`DATE` | correct characters; the clock advances | key tables; uPD4990 bit order |
| Floppy game (e.g. Rusty, D88) with no VHD | boots from drive 0, loads from drive 1 | see "Floppy" below |
| `FORMAT B:` / file copy to a D88 | works; HDM/FDI are read-only in the core (write protect error is correct) | DMA 11h=40h, write TC |
| A BASIC/LIO program or graphics test | LIO drawing appears | GDC figure commands, LIO |
| Game regression list | Rusty, Popful Mail, NightSlave, Doom, Xanadu, Lemmings behave as with the NEC ROM | compare with the owner ROM |

## Floppy notes

The driver waits for the FDC interrupt edge in the slave PIC's IRR with CPU
interrupts off and relies on:
- DMA command register 11h = 40h (DACK active high) - wrong value hijacks the
  I/O bus;
- 94h = 48h (FRY passes real ready, motors on);
- a recalibrate before the first access (drives start at cylinder 127);
- BEh = 03h (2HD) / 01h (2DD through the 1 MB interface) / 00h (640 KB).

If floppy access hangs for ~3 s and returns 90h, the interrupt was not seen:
check that IRQ11 reaches slave IR3 with the line unmasked.

## Comparing with NEC's BIOS

The owner `boot.rom` does not yet POST in `tests/pc98.py` (its self-test
depends on hardware details the model does not emulate, such as the ITF bank
and PIT read-back timing). On the MiSTer, compare behaviour by swapping the
two `boot.rom` files. Never commit anything derived from the owner ROM.

## Zatsugaku Olympics compatibility � 2026-10-06 (release 2026-10-06)

The private NFD was converted to D88 without conversion warnings. The original
image is unchanged. The D88 boots with the current
`PC98_Z486_90_RAM_DWORD_COMPACT.rbf` core and the candidate OpenBIOS, reaching
the opening, Japanese instructions, quiz questions/choices and picture reveal.
This is an early-game compatibility check, not a complete playthrough.

The initial apparent pause at question drawing was BASIC treating `<>` as `>`:
the game paused and cleared text after each character instead of after a line.
The comparison parser now combines both operator bits. No FPGA change was
needed. A temporary BASIC line overlay used to diagnose this was removed.

All eight BIOS test suites passed before the final comparison/CALL refinements;
the complete BASIC suite passed again afterwards, including the new functional
regressions and Hokuto no Ken's menu/prologue.

Final `boot.rom` SHA-256:
`d318ff406d5ab76d306e84c415ab82971b4b83b132758e15cfa6e692dd9021ce`.
The previous MiSTer BIOS was retained as
`/media/fat/games/PC98/boot.rom.before-zatsugaku-20261006`.
