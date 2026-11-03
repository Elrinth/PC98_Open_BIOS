; SPDX-License-Identifier: GPL-3.0-or-later
; A NEC-style FDC interrupt handler for the 1 MB interface (INT 13h), the
; kind games install as their own (Sorcerian's INT 12h is the 640 KB twin):
; it takes the FDC's interrupt status itself, so INT 1Bh must find it in the
; work area. With the FDC busy (CB) it reads the result phase into
; 0564h + 8 * unit; otherwise it issues SENSE INTERRUPT STATUS and keeps
; ST0 and PCN there. Then it sets the unit's flag in 055Eh.
; test_fdd_bios.py assembles this (nasm -f bin) and loads it at 0000:7400.
bits 16
org 7400h
handler:
    push ax
    push bx
    push cx
    push ds
    xor ax, ax
    mov ds, ax
    mov al, 20h
    out 08h, al                 ; EOI slave
    mov al, 0Bh
    out 08h, al
    in al, 08h                  ; slave ISR
    test al, al
    jnz .eoi_done
    mov al, 20h
    out 00h, al                 ; EOI master
.eoi_done:
    in al, 90h
    test al, 10h                ; CB: a data command's result phase
    jnz .results
    call wait_rqm_out
    mov al, 08h                 ; SENSE INTERRUPT STATUS
    out 92h, al
    call wait_result
    jnz .done
    in al, 92h                  ; ST0
    cmp al, 80h                 ; nothing pending
    je .done
    mov bl, al
    and bx, 3
    shl bx, 3
    mov [0564h+bx], al
    call wait_result
    jnz .flag
    in al, 92h                  ; PCN
    mov [0565h+bx], al
    jmp .flag
.results:
    call wait_result
    jnz .done
    in al, 92h                  ; ST0
    mov bl, al
    and bx, 3
    shl bx, 3
    mov cx, bx
    add bx, 0564h
.next:
    mov [bx], al
    inc bx
    call wait_result
    jnz .flag_cx
    in al, 92h
    jmp .next
.flag_cx:
    mov bx, cx
.flag:
    shr bx, 3
    mov cl, bl
    mov al, 1
    shl al, cl
    or [055Eh], al
.done:
    pop ds
    pop cx
    pop bx
    pop ax
    iret

; ZF=1 when the FDC offers a result byte (RQM, DIO), ZF=0 when it is idle
wait_result:
    push cx
    mov cx, 1000h
.w: in al, 90h
    and al, 0D0h
    cmp al, 0D0h
    je .yes
    test al, 80h
    jz .again
    cmp al, 80h                 ; RQM without DIO: no more results
    je .no
.again:
    loop .w
.no:
    or al, 1                    ; ZF=0
    pop cx
    ret
.yes:
    xor al, al                  ; ZF=1
    pop cx
    ret

wait_rqm_out:
    push cx
    mov cx, 1000h
.w: in al, 90h
    and al, 0C0h
    cmp al, 80h
    loopne .w
    pop cx
    ret
