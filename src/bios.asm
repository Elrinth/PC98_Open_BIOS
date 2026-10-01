; SPDX-License-Identifier: 0BSD
; Open PC-98 system BIOS for the Zet98-486 MiSTer core.
;
; The 96 KiB image is mapped at E8000h-FFFFFh as three 32 KiB banks. Each
; bank is its own NASM section whose labels are offsets in that segment:
;
;   bank_e800  E8000h-EFFFFh  segment E800h  N88-BASIC stub (INT 1Eh), spare
;   bank_f000  F0000h-F7FFFh  segment F000h  POST and boot (run once)
;   bank_f800  F8000h-FFFFFh  segment F800h  resident services, reset vector
;
; bank_f800 is also packed as the ITF bank, so switching the ITF off at
; F8000h changes nothing. Fixed addresses that PC-98 software relies on are
; listed in docs/FIXED_ADDRESSES.md and asserted below.

bits 16
cpu 486

%include "workarea.inc"
%include "hw.inc"

SEG_E800        equ 0E800h
SEG_F000        equ 0F000h
SEG_F800        equ 0F800h
SEG_FD80        equ 0FD80h
FD80            equ 5800h          ; FD80:0000 as an F800h offset

section bank_e800 start=0 vstart=0
section bank_f000 start=08000h vstart=0
section bank_f800 start=10000h vstart=0

; ---------------------------------------------------------------- E800 bank
section bank_e800
e800_start:
%include "basic_stub.asm"
%include "lio.asm"
    times 8000h-($-$$) db 0FFh

; ---------------------------------------------------------------- F000 bank
section bank_f000
f000_start:
%include "post.asm"
%include "boot.asm"
    times 4000h-($-$$) db 0FFh         ; F400:0000
%include "dos_sig.asm"
    times 8000h-($-$$) db 0FFh

; ---------------------------------------------------------------- F800 bank
section bank_f800
f800_start:
%include "tables.asm"

    times 0E80h-($-$$) db 0FFh
; F8E8:0000-003F PC-9821 feature/identification table.
feature_table:
%include "feature_table.inc"
    times 0EC0h-($-$$) db 0

%include "runtime.asm"
%include "int18.asm"
%include "int18_gfx.asm"
    times 1900h-($-$$) db 0FFh
; F990:0000 (F800:1900) - LIO directory in the N88-BASIC ROM layout: a count,
; then {interrupt, 0, entry offset} per LIO interrupt. MS-DOS finds the LIO
; through it: without it INT A0h-AFh end in IO.SYS's "invalid interrupt"
; message (E.V.O. Theory of Evolution). Layout as NP2kai's lio.res.
lio_directory:
    dw 0011h, 0
%assign lio_n 0
%rep 16
    db 0A0h + lio_n, 0
    dw 50h + lio_n * 8
%assign lio_n lio_n + 1
%endrep
    db 0CEh, 0
    dw 50h + 16 * 8
    times 1900h + 50h - ($-$$) db 0
%assign lio_n 0
%rep 16
    sti
    jmp SEG_E800:lio_vec_ %+ lio_n
    nop
    nop
%assign lio_n lio_n + 1
%endrep
    iret
%include "gdc_draw.asm"
%include "int1c.asm"
%include "int1b.asm"
%include "misc_int.asm"
    times FD80-($-$$) db 0FFh

; FD80:0000 - traditional BIOS entry segment. Reset/shutdown resume path.
fd80_base:
    jmp near fd80_reset
    ; FD80:091E - MS-DOS IO.SYS jumps here to restart the boot sequence.
    times FD80+091Eh-($-$$) db 0FFh
fd80_restart:
    jmp SEG_F000:boot_restart
    times FD80+0E00h-($-$$) db 0FFh
; FD80:0E00 - key code tables (8 x 60h), also published at 05C6h.
keytable:
%include "keytable.inc"
fd80_reset:
    jmp SEG_F000:post_entry

    times 7FF0h-($-$$) db 0FFh
; FFFF0h reset vector (F800:7FF0 = F000:FFF0 = FFFF:0000)
reset_vector:
    jmp SEG_F000:post_entry
    db 'OPEN98',0
    times 8000h-2-($-$$) db 0FFh
    dw 0                                ; checksum slot (see tools/build.py)
