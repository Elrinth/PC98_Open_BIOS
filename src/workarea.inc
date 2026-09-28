; PC-98 BIOS work area (segment 0000h) and memory-switch addresses.
; Names follow the PC-98 technical references; the offsets are the same ones
; used by DOS, drivers and games, cross-checked against NP2kai bios/biosmem.h.

; ---- 0400h-04FFh
EXPMMSZ         equ 0401h   ; extended RAM below 16 MB, 128 KiB units
SHUT_SP         equ 0404h   ; CPU-reset resume SS:SP (with port 35h/37h shutdown)
SHUT_SS         equ 0406h
BIOS_FLAG5      equ 0458h
DISK_EQUIP_EXT  equ 045Ch   ; bit 6: PC-9821 extended modes
SYS_TYPE        equ 0480h   ; 0 V30, 1 286, 3 386+, bit 7: IDE
BIOS_FLAG3      equ 0481h
DISK_EQUIPS     equ 0482h
F2HD_MODE       equ 0493h
EXTROM_ENTRY    equ 04ACh   ; far pointer used by the extension-ROM scan
EXTROM_SEG      equ 04AEh
DISK_XROM       equ 04B0h   ; 16 bytes: extension-ROM owner table
EXTROM_TABLE    equ 04D0h   ; 16 bytes: extension-ROM claim table

; ---- 0500h-05FFh
BIOS_FLAG0      equ 0500h
BIOS_FLAG1      equ 0501h   ; bit 7: 8 MHz clock lineage, bit 6: V30
KB_BUF          equ 0502h   ; 16 words
KB_BUF_END      equ 0522h
KB_SHIFT_TBL    equ 0522h   ; offset of the current key table (segment KB_CODE_SEG)
KB_BUF_HEAD     equ 0524h
KB_BUF_TAIL     equ 0526h
KB_COUNT        equ 0528h
KB_RETRY        equ 0529h
KB_KY_STS       equ 052Ah   ; 16 bytes: key-down bitmap
SHIFT_STS       equ 053Ah
CRT_RASTER      equ 053Bh
CRT_STS_FLAG    equ 053Ch
CRT_CNT         equ 053Dh
CRT_MULTI_OFF   equ 053Eh
CRT_MULTI_SEG   equ 0540h
CRT_MULTI_NUM   equ 0547h
CRT_W_VRAMADR   equ 0548h
CRT_W_RASTER    equ 054Ah
PRXCRT          equ 054Ch
PRXDUPD         equ 054Dh
PRXGLS          equ 054Eh
RS_CH0_OFST     equ 0556h
RS_CH0_SEG      equ 0558h
RS_S_FLAG       equ 055Bh
DISK_EQUIP      equ 055Ch
DISK_INTL       equ 055Eh
DISK_INTH       equ 055Fh
DISK_RESULT     equ 0564h
DISK_BOOT       equ 0584h
CA_TIM_CNT      equ 058Ah
EXPMMSZ16       equ 0594h   ; MB of RAM above 16 MB
CRT_BIOS        equ 0597h
F144_SUP        equ 05AEh
RS_D_FLAG       equ 05C1h
KB_CODE_OFF     equ 05C6h
KB_CODE_SEG     equ 05C8h
F2DD_MODE       equ 05CAh
F2DD_POINTER    equ 05CCh
F2HD_POINTER    equ 05F8h

; ---- memory switches in text-VRAM attribute space (every 4th byte)
MSW_SEG         equ 0A000h
MSW1            equ 3FE2h
MSW2            equ 3FE6h
MSW3            equ 3FEAh
MSW4            equ 3FEEh
MSW5            equ 3FF2h
MSW6            equ 3FF6h
MSW7            equ 3FFAh
MSW8            equ 3FFEh
