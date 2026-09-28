; PC-98 I/O ports used by the BIOS.

PIC_M0          equ 00h
PIC_M1          equ 02h
PIC_S0          equ 08h
PIC_S1          equ 0Ah
RTC_OUT         equ 20h         ; uPD4990 command/data/clock/strobe
DMA_BANK        equ 21h         ; 21h/23h/25h/27h bank registers
SYS_A           equ 31h         ; 8255 port A: DIP switch 2 (read)
SYS_B           equ 33h         ; port B: RTC data, CRT type, ...
SYS_C           equ 35h         ; port C
SYS_CTRL        equ 37h         ; port C bit set/reset
KB_DATA         equ 41h
KB_CMD          equ 43h
PORT_42         equ 42h         ; printer 8255 port B: bit 5 = 8 MHz lineage
CPU_RESET_WAIT  equ 5Fh         ; 0.6 us I/O wait port
GDC_T_STAT      equ 60h         ; text GDC status / parameter
GDC_T_CMD       equ 62h         ; text GDC command / data read
MODE_FF1        equ 68h
MODE_FF2        equ 6Ah
CRTC_PL         equ 70h
CRTC_BL         equ 72h
CRTC_CL         equ 74h
CRTC_SSL        equ 76h
CRTC_SUR        equ 78h
CRTC_SDR        equ 7Ah
PIT_C0          equ 71h
PIT_C1          equ 73h
PIT_C2          equ 75h
PIT_MODE        equ 77h
GDC_G_STAT      equ 0A0h
GDC_G_CMD       equ 0A2h
GR_DISP_PAGE    equ 0A4h
GR_DRAW_PAGE    equ 0A6h
PAL_A8          equ 0A8h
PAL_AA          equ 0AAh
PAL_AC          equ 0ACh
PAL_AE          equ 0AEh
CG_CODE_HI      equ 0A1h
CG_CODE_LO      equ 0A3h
CG_LINE         equ 0A5h
CG_DATA         equ 0A9h
A20_ON          equ 0F2h
A20_CTRL        equ 0F6h        ; 02h enable, 03h disable
CPU_RESET       equ 0F0h
ITF_BANK        equ 43Dh        ; 10h ITF bank at F8000h, 12h BIOS bank

; uPD7220 status bits
GDC_DATA_READY  equ 01h
GDC_FIFO_FULL   equ 02h
GDC_FIFO_EMPTY  equ 04h
GDC_DRAWING     equ 08h
GDC_VSYNC       equ 20h

; uPD7220 commands
GDC_RESET       equ 00h
GDC_SYNC_OFF    equ 0Eh
GDC_SYNC_ON     equ 0Fh
GDC_STOP        equ 0Ch
GDC_START       equ 0Dh
GDC_ZOOM        equ 46h
GDC_PITCH       equ 47h
GDC_CSRW        equ 49h
GDC_CSRFORM     equ 4Bh
GDC_SCROLL      equ 70h
GDC_MASK        equ 4Ah
GDC_VECTW       equ 4Ch
GDC_VECTE       equ 6Ch
GDC_TEXTE       equ 68h
GDC_WRITE       equ 20h
GDC_TEXTW       equ 78h
