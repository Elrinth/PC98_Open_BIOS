; F400:0000 - service dispatcher in the layout NEC MS-DOS 3.30 IO.SYS looks
; for. IO.SYS refuses to run on an unknown BIOS: it compares the 12 bytes at
; F000:0000 or F400:0000 and the 25 bytes from offset 0Dh with this
; dispatcher shape (an AH-indexed table call at CS:0026h) and otherwise
; resets the machine forever (E.V.O. HD and other DOS 3.30 hard disks).
; Nothing vectors here; the table entry returns. Some instructions are
; given as bytes because NASM picks other, equivalent encodings.
dos_sig_dispatch:
    sti
    cld
    push bx
    push cx
    push dx
    push bp
    push si
    push di
    push ds
    push es
    cmp ah, 1                          ; entries in the table below
    jae .done                          ; 73 0E
    mov bx, dos_sig_table - dos_sig_dispatch
    db 33h, 0D2h                       ; xor dx, dx
    db 8Ah, 0D4h                       ; mov dl, ah
    shl dx, 1
    db 03h, 0DAh                       ; add bx, dx
    call word [cs:bx]
.done:
    pop es
    pop ds
    pop di
    pop si
    pop bp
    pop dx
    pop cx
    pop bx
    iret
dos_sig_table:
    dw dos_sig_ret - dos_sig_dispatch
dos_sig_ret:
    ret
