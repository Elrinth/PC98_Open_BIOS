; SPDX-License-Identifier: GPL-3.0-or-later
; Interrupt probe for test_int1b_stack.py: counts its entries, how many found
; an SS other than want_ss, and the lowest SP it was entered with, then chains
; to the handler that was installed before it. Laplace no Ma's timer handler
; reads its jump targets through SS, so it needs the interrupted program's
; stack. Assembled with -DORG=7400h (INT 13h, FDC) and -DORG=7500h (INT 0Ah,
; VSYNC); the data block starts at ORG + 40h.
bits 16
org ORG
probe:
    push ax
    mov ax, ss
    cmp ax, [cs:want_ss]
    je .same
    inc word [cs:other]
.same:
    pop ax
    cmp sp, [cs:low_sp]
    jae .chain
    mov [cs:low_sp], sp
.chain:
    inc word [cs:count]
    jmp far [cs:next]
    times 40h-($-$$) db 90h
next:       dd 0                ; +40h previous handler
want_ss:    dw 0                ; +44h
other:      dw 0                ; +46h entries on another SS
low_sp:     dw 0FFFFh           ; +48h
count:      dw 0                ; +4Ah
