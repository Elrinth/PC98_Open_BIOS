# Zet98-486 core hardware as seen by the BIOS

Survey of `L:\dev\Zet98_Improved_Core\PC98_MiSTer` (2026-09-26). ZM =
`Zet98/Zet98MiSTer.vhd`, ZS = `Zet98/MiSTer/Zet98.sv`, AO =
`rtl/cpu/pc98_ao486.sv`. Re-verify line numbers before relying on them.

## Bus

- Every I/O cycle is acknowledged; undecoded byte lanes read **FFh**.
- Most devices reset with `srstn`; **both PICs use raw `rstn`**.
- An F0h write or triple fault resets **only the CPU** (A20 is cleared);
  PICs, PIT, 8255 SHUT bits, ITF state, RAM and DDR survive.

## I/O ports (BIOS-relevant)

| Port | Device | Notes |
|---|---|---|
| 00h/02h, 08h/0Ah | 8259 master/slave | Master/slave chosen by **ICW4 bit 2** (master 1Dh + ICW3 80h, slave 09h + ICW3 07h). IMR resets to 00h. No nesting: INT only when ISR = 0. Non-specific EOI clears the whole ISR. No poll mode. |
| 01h-1Fh odd | 8237 DMA | Only ch2 (1 MB FDC) and ch3 (640 KB FDC) have requests. **19h/1Bh unimplemented**; per-channel byte flip-flop held at LSB while 11h bit 2 = 1 (write 04h then 00h to resync). Mask resets to 00h. No auto-mask on TC. |
| 21h/23h/25h/27h | DMA bank (ch1/ch2/ch3/ch0) | 4 bits: DMA reaches 1 MB only. 29h: bank mode. |
| 20h | uPD4990 | bit 5 DI, 4 CLK, 3 STB, 2-0 C2-C0. Data out at 33h bit 0. |
| 31h | DIP switch 2 | bit 7 = GDC 2.5 MHz (default 1), others 0. |
| 33h | system port B | `0000 0 1 0 CDAT`. |
| 35h/37h | system port C | Reads back last written; reset FFh (so SHUT0 = 1 on power-on). PC3 = 0 speaker on. **A mode word to 37h clears PC to 00h** (speaker on) - only use bit set/reset. |
| 41h/43h | keyboard 8251 | 43h status `DSR0 BRK0 FE0 OE PE0 TXE1 RXRDY TXRDY1`. Writes are parsed but do nothing; nothing is sent to the keyboard. IRQ1 = RXRDY level. |
| 42h | printer 8255 B | `1 0 0 DIP1-3 DIP1-8 1 0 0`; **bit 5 = 0** (2.4576 MHz timer family). |
| 5Ch-5Fh | timestamp | 24-bit counter, 3.26 us units. 5Fh writes are a harmless wait. |
| 60h/62h | text GDC | see below. |
| 68h/6Ah | mode flip-flops | 68h: 00/01 attribute mode, 02/03 GRMONO, 04/05 40 col, 06/07 font, 08/09 200-line, 0A/0B KAC (no effect), **0C/0D memory-switch write**, 0E/0F display enable (PEGC only). **GDC RESET clears all of them.** |
| 70h-7Ah | CRTC | **not decoded** (text rows come from GDC CSRFORM). |
| 71h/73h/75h/77h | 8253 | Fixed **2.4576 MHz**. **Reads return a latched copy only** (latch with a control word before every read). RW=11 flip-flop is not reset by a control word. Mode 0 stops at 1. Modes 1/5 never trigger. Aliases 3FD9h-3FDFh. |
| 7Ch/7Eh | GRCG | mode / tile. |
| 90h/92h/94h | uPD765, 1 MB interface | active only with BEh bit 0 = 1. DMA ch2, IRQ11. |
| C8h/CAh/CCh | uPD765, 640 KB interface | **reset default** (BEh bit 0 = 0). DMA ch3, IRQ10. |
| 94h/CCh write | FDC control | bit 7 reset, **bit 6 FRY (READY forced low when 0)**, bit 3 motor, bit 2 timer IRQ enable, bit 0 100 ms one-shot IRQ. Status bit 4 unreliable. |
| BEh | FDC interface | bit 0 interface (1 = 1 MB), bit 1 HD. Reads 08h after reset. |
| A0h/A2h | graphics GDC | status bit 7 always 1. MASK (4Ah) not decoded. SYNC ignored. |
| A1h/A3h/A5h/A9h | CG window | A1h = JIS 2nd byte, A3h = 1st byte - 20h (ANK: A1h = 0, A3h = code); A5h bits 3-0 line, bit 5 = 1 left half. A9h read/write (writes reach any glyph). **No CG memory window at A4000h.** |
| A4h/A6h | display / draw page | |
| A8h-AEh | palette | digital: A8h 7/3, AAh 5/1, ACh 6/2, AEh 4/0 (identity at reset). Analog (6Ah = 01h): A8h index, AAh G, ACh R, AEh B; **analog entries reset to black**. |
| 430h/432h, 640h-64Eh, 74Ch/74Eh | ATA (`-RawIde`) | IRQ9 (slave IR1). |
| 439h | misc | stored bits drive nothing. 43Bh reads 04h. |
| **43Dh** | ITF bank | 10h ITF on (reset state), 12h off. (Notes said 43Ch; RTL decodes the odd byte 43Dh.) |
| 43Fh | EMS window control | 20h/22h. |
| 461h/463h | 128 KiB bank windows | 80000h-9FFFFh (reset 08h), A0000h-BFFFFh (reset 0Ah). |
| 53Dh | ROM/RAM select | bit 7 sound ROM at CC000h, bit 1 BIOS area -> RAM. |
| F0h | read EBh; write = CPU reset | |
| F2h / F6h | A20 | F2h any write enables, read FEh enabled / FFh disabled. F6h 02h enable, 03h disable. |
| 188h-18Eh, A460h | OPNA / sound ID | |
| 7FD9h-7FDFh, BFDBh | mouse | |

No 7FF0h debug port exists.

### IRQs

Master: IR0 PIT0, IR1 keyboard, IR2 VRTC (latched every frame), IR4
RS-232C, IR6 MPU, IR7 cascade. Slave: IR1 IDE, IR2 640 KB FDC, IR3 1 MB FDC,
IR4 OPNA/PCM86, IR5 mouse.

## Memory

- boot.rom is loaded once per core load into SDRAM and is **writable** by
  the CPU. Font bytes 80000h-867FFh of the file also land in graphics VRAM:
  POST must clear VRAM.
- 00000h-9FFFFh RAM (80000h-9FFFFh via 461h window).
- A0000h-A1FFFh text codes; A2000h-A3FDFh attributes (**low byte only**,
  odd bytes read FFh); A3FE0h-A3FFFh memory switches (index = A4..A2, low
  lane, write only with 68h = 0Dh). Core-load defaults: 4Ch 68h 04h 00h 01h
  08h, MSW7/MSW8 uninitialised; not reset by OSD reset, not saved.
- A4000h-A7FFFh plain RAM. Graphics planes A8000h/B0000h/B8000h/E0000h.
- C0000h-CBFFFh: three "EMS" windows alias one 16 KiB.
- D0000h-D1FFFh disk ROM (`-RawIde`), D2000h-DFFFFh RAM (disk ROM uses
  D8000h-DFFFFh).
- E8000h-F7FFFh BIOS. F8000h-FFFFFh: ITF bank (boot.rom 18000h) while ITF
  is on (reset), else boot.rom 10000h.
- Extended RAM (DDR): 100000h to 16/64 MB, **F00000h-FFFFFFh reads FFFFh**
  (14 MB + 48 MB on the 64 MB map). z486 caches only <80000h and extended
  RAM; ROM code runs uncached.

## Reset

z486 and ao486 start in real mode at F000:FFF0 with CS base FFFF0000h;
FFFFFFF0h aliases FFFF0h (ITF bank). **Until the first far jump only
F0000h-FFFFFh is aliased high.** A20 resets disabled.

## Display

- Timing is hard-wired 640x400, ~31.25 kHz / **59.5 Hz** (not NEC's
  24.8 kHz / 56.4 Hz); SYNC parameters are ignored.
- Text layer needs from the BIOS: START (0Dh/6Bh), CSRFORM LR (0Fh for 25
  rows, 13h for 20 rows), PITCH (80), SCROLL SAD0, 68h C40. Only SAD0 is
  displayed (no split areas). CSRR (E0h) DATA READY bit is unreliable.
- Graphics needs START, PITCH, SCROLL, CSRFORM P0.

## Keyboard

PS/2 set 2 converted by hardware tables to PC-98 codes (make = code, break =
code | 80h). CAPS/KANA behave as locks. Held-key repeat is sent as break +
make.

## Floppy (uPD765 + 8237), survey of 2026-09-26

The FDC is a bit-level uPD765 fed by a drive emulator (rotation, index
pulses and stepping are emulated). Rules the BIOS follows:

- **DMA command 11h must keep bit 6 set (40h).** It selects DACK polarity;
  with 00h the FDC sees a permanent DACK and hijacks the I/O bus. Reset the
  per-channel byte flip-flops with `11h <- 44h` then `11h <- 40h` (19h/1Bh
  are not implemented).
- **FRY (94h/CCh bit 6) is inverted versus NP2**: 0 (reset) forces READY,
  1 passes the drive's real ready (image loaded and motor on, bit 3).
  Use 48h.
- The FDC **cannot be reset by software** (bit 7 only resets a timing tick)
  and there are no reset/ready-change interrupts: SENSE INTERRUPT after
  power-up returns the single byte 80h.
- Drives start at an unknown cylinder (127): **recalibrate first**. Only
  units 0 and 1 exist; commands on units 2/3 can wedge the FDC until a
  MiSTer reset.
- BEh resets to 00h (640 KB interface). BEh bit 0 = interface (ports,
  DMA channel 2/3, IRQ11/10), bit 1 = data rate (500/250 kbps). 2DD media
  work through the 1 MB interface with BEh = 01h. 2D media are stored at
  physical cylinder 2c (the BIOS double-steps).
- MSR polling is unreliable during DMA (RQM/DIO rise while a byte is
  pending). End of command = FDC interrupt edge. The core's 8259 latches
  the edge but shows it in IRR only while the line is unmasked.
- A SEEK/RECALIBRATE end interrupt is lost if another command is being
  processed at that moment: send nothing while the head steps.
- READ ends on TC (IC=00) or at EOT without MT (IC=01, EN). WRITE needs
  TC. TC mid-sector does not stop the sector: the DMA count reloads and the
  channel is not masked, so the BIOS masks the channel when it sees TC.
- Every command end also sets the SENSE INTERRUPT status (ST0 + PCN).
- DMA mode register: 46h/47h read to memory, 4Ah/4Bh write from memory;
  verify (00b) and block mode do not work, 11b hangs the bus. Bank ports
  23h (ch2) / 25h (ch3); addresses wrap within 64 KiB unless 29h bit 2.
- Step clock (16 - SRT) x 0.5 ms; with SRT = Fh about 1.5-2.5 ms per step
  plus 15 ms settle. Sector not found after about 4 revolutions.
- Write protect = D88 header flag; HDM/FDI/NFD are always protected.
  Hot swap works but there is no disk-change signal.
