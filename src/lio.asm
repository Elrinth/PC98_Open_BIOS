; LIO - the PC-98 graphics BIOS (INT A0h-AFh), in the E800h bank where NEC
; machines keep it (inside the N88-BASIC ROM area).
;
; Callers pass DS = their work segment (LIO keeps its state at DS:0620h and
; the palette mode at DS:0A08h) and DS:BX -> a parameter block. Returns
; AH = 0 (success), 5 (illegal function) or 7 (out of memory).
; Function semantics follow NP2kai lio/*.c (BSD-3-Clause, NP2 developer
; team); the drawing code here is an independent implementation.
;
;   A0 GINIT   A1 GSCREEN A2 GVIEW  A3 GCOLOR1 A4 GCOLOR2 A5 GCLS
;   A6 GPSET   A7 GLINE   A8 GCIRCLE A9 GPAINT1 AA GPAINT2 AB GGET
;   AC GPUT1   AD GPUT2   AE GROLL  AF GPOINT2

LIO_OK          equ 0
LIO_ILLEGAL     equ 5
LIO_NOMEM       equ 7

; work area (caller DS)
LW              equ 0620h
LW_SCRNMODE     equ LW+0
LW_POS          equ LW+1
LW_PLANE        equ LW+2
LW_FG           equ LW+3
LW_BG           equ LW+4
LW_COLOR        equ LW+6        ; 8 bytes
LW_VX1          equ LW+14
LW_VY1          equ LW+16
LW_VX2          equ LW+18
LW_VY2          equ LW+20
LW_DISP         equ LW+22
LW_ACCESS       equ LW+23
LW_SIZE         equ 24
LIO_PALMODE     equ 0A08h

; frame: [bp+2] function, [bp+4] IP, [bp+6] CS, [bp+8] FLAGS
L_DS            equ -2
L_ES            equ -4
L_BX            equ -6
L_CX            equ -8
L_DX            equ -10
L_SI            equ -12
L_DI            equ -14
L_AX            equ -16
L_AL            equ -16
L_AH            equ -15
; drawing state (lio_update)
DV_X1           equ -18
DV_Y1           equ -20
DV_X2           equ -22
DV_Y2           equ -24
DV_UPPER        equ -26         ; 16000 when drawing the upper 200 lines
DV_MONO         equ -27         ; 1: single plane
DV_PLANE        equ -28         ; plane index when mono
DV_PLANES       equ -29         ; 3 or 4 planes when colour
DV_PALMAX       equ -30         ; 2, 8 or 16
; scratch
T0              equ -32
T1              equ -34
T2              equ -36
T3              equ -38
T4              equ -40
T5              equ -42
T6              equ -44
T7              equ -46
T8              equ -48
T9              equ -50
T10             equ -52
T11             equ -54
TB              equ -90         ; 36-byte buffer (font pattern)
L_LOCALS        equ 90

lio_planeseg: dw 0A800h, 0B000h, 0B800h, 0E000h

%macro LIO_VECTOR 1
lio_vec_%1:
    push word %1
    jmp lio_common
%endmacro
LIO_VECTOR 0
LIO_VECTOR 1
LIO_VECTOR 2
LIO_VECTOR 3
LIO_VECTOR 4
LIO_VECTOR 5
LIO_VECTOR 6
LIO_VECTOR 7
LIO_VECTOR 8
LIO_VECTOR 9
LIO_VECTOR 10
LIO_VECTOR 11
LIO_VECTOR 12
LIO_VECTOR 13
LIO_VECTOR 14
LIO_VECTOR 15

lio_vectors:
    dw lio_vec_0, lio_vec_1, lio_vec_2, lio_vec_3
    dw lio_vec_4, lio_vec_5, lio_vec_6, lio_vec_7
    dw lio_vec_8, lio_vec_9, lio_vec_10, lio_vec_11
    dw lio_vec_12, lio_vec_13, lio_vec_14, lio_vec_15

lio_table:
    dw lio_ginit, lio_gscreen, lio_gview, lio_gcolor1
    dw lio_gcolor2, lio_gcls, lio_gpset, lio_gline
    dw lio_gcircle, lio_gpaint1, lio_gpaint2, lio_gget
    dw lio_gput1, lio_gput2, lio_groll, lio_gpoint2

lio_common:
    push bp
    mov bp, sp
    push ds
    push es
    push bx
    push cx
    push dx
    push si
    push di
    push ax
    sub sp, L_LOCALS - 16
    cld
    mov bx, [bp+2]
    add bx, bx
    call lio_update
    call [cs:lio_table+bx]
    mov [bp+L_AH], al              ; status
    mov sp, bp
    sub sp, 16
    pop ax
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop es
    pop ds
    pop bp
    add sp, 2
    iret

; ---------------------------------------------------------------- state
; Derive the drawing window, plane selection and palette size from the
; work area.
lio_update:
    push ax
    push cx
    mov cl, 3
    cmp byte [LIO_PALMODE], 2
    jne .bits
    mov cl, 4
.bits:
    mov [bp+DV_PLANES], cl
    mov al, 1
    shl al, cl
    mov [bp+DV_PALMAX], al
    mov byte [bp+DV_MONO], 0
    mov byte [bp+DV_PLANE], 0
    mov word [bp+DV_UPPER], 0
    mov word [bp+T0], 399          ; last line
    mov al, [LW_SCRNMODE]
    cmp al, 0
    je .m0
    cmp al, 3
    je .clip
    ; modes 1 and 2: one plane, pos % colorbit
    mov byte [bp+DV_MONO], 1
    movzx ax, byte [LW_POS]
    div cl                         ; AL = pos / colorbit, AH = pos % colorbit
    mov [bp+DV_PLANE], ah
    cmp byte [LW_SCRNMODE], 2
    je .clip
    mov word [bp+T0], 199
    test al, al
    jz .clip
    mov word [bp+DV_UPPER], 16000
    jmp .clip
.m0:
    mov word [bp+T0], 199
    test byte [LW_POS], 1
    jz .clip
    mov word [bp+DV_UPPER], 16000
.clip:
    mov ax, [LW_VX1]
    test ax, ax
    jns .x1
    xor ax, ax
.x1:
    mov [bp+DV_X1], ax
    mov ax, [LW_VY1]
    test ax, ax
    jns .y1
    xor ax, ax
.y1:
    mov [bp+DV_Y1], ax
    mov ax, [LW_VX2]
    cmp ax, 639
    jle .x2
    mov ax, 639
.x2:
    mov [bp+DV_X2], ax
    mov ax, [LW_VY2]
    cmp ax, [bp+T0]
    jle .y2
    mov ax, [bp+T0]
.y2:
    mov [bp+DV_Y2], ax
    pop cx
    pop ax
    ret

; CF=1 if (CX, DX) lies outside the drawing window.
lio_outside:
    cmp cx, [bp+DV_X1]
    jl .out
    cmp cx, [bp+DV_X2]
    jg .out
    cmp dx, [bp+DV_Y1]
    jl .out
    cmp dx, [bp+DV_Y2]
    jg .out
    clc
    ret
.out:
    stc
    ret

; DI = byte offset of (CX, DX) in a plane, AH = bit mask.
lio_addr:
    push cx
    mov di, dx
    imul di, di, 80
    push cx
    shr cx, 3
    add di, cx
    pop cx
    add di, [bp+DV_UPPER]
    and cl, 7
    mov ah, 80h
    shr ah, cl
    pop cx
    ret

; Plot colour AL at (CX, DX), clipped to the window.
lio_pset:
    call lio_outside
    jc .done
    push ax
    push bx
    push di
    push es
    push ax
    call lio_addr
    pop bx                         ; BL = colour
    cmp byte [bp+DV_MONO], 0
    je .colour
    movzx di, byte [bp+DV_PLANE]
    add di, di
    mov es, [cs:lio_planeseg+di]
    call lio_addr
    test bl, bl
    jz .clear1
    or [es:di], ah
    jmp .end
.clear1:
    not ah
    and [es:di], ah
    jmp .end
.colour:
    push si
    push cx
    movzx cx, byte [bp+DV_PLANES]
    xor si, si
.plane:
    mov es, [cs:lio_planeseg+si]
    shr bl, 1
    jnc .clear
    or [es:di], ah
    jmp .next
.clear:
    not ah
    and [es:di], ah
    not ah
.next:
    add si, 2
    loop .plane
    pop cx
    pop si
.end:
    pop es
    pop di
    pop bx
    pop ax
.done:
    ret

; AL = colour at (CX, DX), FFh outside the window.
lio_point:
    call lio_outside
    jnc .inside
    mov al, 0FFh
    ret
.inside:
    push bx
    push cx
    push si
    push di
    push es
    call lio_addr
    xor bl, bl
    cmp byte [bp+DV_MONO], 0
    je .colour
    movzx si, byte [bp+DV_PLANE]
    add si, si
    mov es, [cs:lio_planeseg+si]
    test [es:di], ah
    jz .got
    mov bl, 1
    jmp .got
.colour:
    movzx cx, byte [bp+DV_PLANES]
    mov si, cx
    dec si
    add si, si
.plane:                            ; highest plane first
    shl bl, 1
    mov es, [cs:lio_planeseg+si]
    test [es:di], ah
    jz .zero
    or bl, 1
.zero:
    sub si, 2
    loop .plane
.got:
    mov al, bl
    pop es
    pop di
    pop si
    pop cx
    pop bx
    ret

; Horizontal span CX..SI on line DX in colour AL, clipped.
lio_hline:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    cmp dx, [bp+DV_Y1]
    jl .done
    cmp dx, [bp+DV_Y2]
    jg .done
    cmp cx, si
    jle .ordered
    xchg cx, si
.ordered:
    cmp cx, [bp+DV_X1]
    jge .left
    mov cx, [bp+DV_X1]
.left:
    cmp si, [bp+DV_X2]
    jle .right
    mov si, [bp+DV_X2]
.right:
    cmp cx, si
    jg .done
    mov bl, al                     ; colour
    mov [bp+T8], cx                ; x1
    mov [bp+T9], si                ; x2
    ; one plane at a time
    cmp byte [bp+DV_MONO], 0
    je .colour
    movzx di, byte [bp+DV_PLANE]
    xor al, al
    test bl, bl
    jz .mono
    mov al, 0FFh
.mono:
    add di, di
    mov es, [cs:lio_planeseg+di]
    call lio_span_plane
    jmp .done
.colour:
    xor di, di
    movzx cx, byte [bp+DV_PLANES]
.plane:
    push cx
    mov es, [cs:lio_planeseg+di]
    xor al, al
    shr bl, 1
    jnc .fill
    mov al, 0FFh
.fill:
    call lio_span_plane
    add di, 2
    pop cx
    loop .plane
.done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Fill the span [T8, T9] of line DX in plane ES with AL (00h or FFh).
lio_span_plane:
    push ax
    push bx
    push cx
    push si
    push di
    mov ah, al                     ; fill byte
    mov di, dx
    imul di, di, 80
    add di, [bp+DV_UPPER]          ; line start
    mov bx, [bp+T8]
    shr bx, 3
    add bx, di                     ; first byte
    mov si, [bp+T9]
    shr si, 3
    add si, di                     ; last byte
    mov cl, [bp+T8]
    and cl, 7
    mov ch, 0FFh
    shr ch, cl                     ; left mask
    mov cl, [bp+T9]
    and cl, 7
    mov al, 80h
    sar al, cl                     ; right mask
    cmp bx, si
    jne .multi
    and ch, al
    call .apply
    jmp .done
.multi:
    call .apply
    inc bx
.middle:
    cmp bx, si
    jae .last
    mov [es:bx], ah
    inc bx
    jmp .middle
.last:
    mov ch, al
    call .apply
.done:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret
; [ES:BX] = ([ES:BX] & ~CH) | (AH & CH)
.apply:
    push ax
    push cx
    mov al, [es:bx]
    and ah, ch
    not ch
    and al, ch
    or al, ah
    mov [es:bx], al
    pop cx
    pop ax
    ret

; Line (T0,T1)-(T2,T3) in colour AL with style pattern T4 (bit 0 first).
lio_line:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bl, al
    mov cx, [bp+T0]
    mov dx, [bp+T1]
    mov si, [bp+T2]
    sub si, cx
    mov [bp+T5], word 1            ; sx
    jns .dx
    neg si
    mov [bp+T5], word -1
.dx:
    mov di, [bp+T3]
    sub di, dx
    mov [bp+T6], word 1            ; sy
    jns .dy
    neg di
    mov [bp+T6], word -1
.dy:                               ; SI = |dx|, DI = |dy|
    mov ax, si
    sub ax, di
    mov [bp+T7], ax                ; err = dx - dy
.plot:
    test word [bp+T4], 1
    jz .skip
    mov al, bl
    call lio_pset
.skip:
    ror word [bp+T4], 1
    cmp cx, [bp+T2]
    jne .step
    cmp dx, [bp+T3]
    je .end
.step:
    mov ax, [bp+T7]
    add ax, ax                     ; e2
    push ax
    push di
    neg di
    cmp ax, di                     ; e2 > -dy ?
    pop di                         ; (POP keeps the flags)
    jle .noy
    sub [bp+T7], di
    add cx, [bp+T5]
.noy:
    pop ax
    cmp ax, si                     ; e2 < dx ?
    jge .plot
    add [bp+T7], si
    add dx, [bp+T6]
    jmp .plot
.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Filled box (T0,T1)-(T2,T3) in colour AL (or tile, see lio_tile_box).
lio_box:
    push cx
    push dx
    push si
    mov dx, [bp+T1]
    mov si, [bp+T3]
    cmp dx, si
    jle .rows
    xchg dx, si
.rows:
    cmp dx, si
    jg .done
    mov cx, [bp+T0]
    push si
    mov si, [bp+T2]
    call lio_hline
    pop si
    inc dx
    jmp .rows
.done:
    pop si
    pop dx
    pop cx
    ret

; Box outline (T0,T1)-(T2,T3) in colour AL with style T4.
lio_frame:
    push word [bp+T0]
    push word [bp+T1]
    push word [bp+T2]
    push word [bp+T3]
    push word [bp+T4]
    ; top
    push word [bp+T3]
    mov cx, [bp+T1]
    mov [bp+T3], cx
    call lio_line
    pop word [bp+T3]
    ; bottom
    push word [bp+T1]
    mov cx, [bp+T3]
    mov [bp+T1], cx
    call lio_line
    pop word [bp+T1]
    ; left
    push word [bp+T2]
    mov cx, [bp+T0]
    mov [bp+T2], cx
    call lio_line
    pop word [bp+T2]
    ; right
    push word [bp+T0]
    mov cx, [bp+T2]
    mov [bp+T0], cx
    call lio_line
    pop word [bp+T0]
    pop word [bp+T4]
    pop word [bp+T3]
    pop word [bp+T2]
    pop word [bp+T1]
    pop word [bp+T0]
    ret

; AL = AL with bits reversed.
lio_reverse:
    push cx
    push dx
    mov dl, al
    mov cx, 8
.next:
    shr dl, 1
    rcl al, 1
    loop .next
    pop dx
    pop cx
    ret

; Tile box (T0,T1)-(T2,T3): tile bytes at T10:T11 (seg:off), T9 = length
; in bytes (planes bytes per row). Pixel colours come from the tile.
lio_tile_box:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov dx, [bp+T1]
    mov si, [bp+T3]
    cmp dx, si
    jle .rows
    xchg dx, si
    mov [bp+T1], dx
    mov [bp+T3], si
.rows:
    mov ax, [bp+T0]
    mov cx, [bp+T2]
    cmp ax, cx
    jle .cols
    mov [bp+T0], cx
    mov [bp+T2], ax
.cols:
    mov dx, [bp+T1]
.y:
    cmp dx, [bp+T3]
    jg .done
    mov cx, [bp+T0]
.x:
    cmp cx, [bp+T2]
    jg .ynext
    call lio_tile_colour
    call lio_pset
    inc cx
    jmp .x
.ynext:
    inc dx
    jmp .y
.done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; AL = tile colour at (CX, DX). Tile rows are (planes) bytes each; the
; pattern is aligned to the window's top-left corner.
lio_tile_colour:
    push bx
    push cx
    push dx
    push si
    push es
    movzx si, byte [bp+DV_PLANES]
    cmp byte [bp+DV_MONO], 0
    je .planes
    mov si, 1
.planes:                           ; SI = planes
    mov ax, dx
    sub ax, [bp+DV_Y1]
    mul si                         ; AX = row * planes
    xor dx, dx
    mov bx, [bp+T9]
    div bx
    mov bx, dx                     ; BX = start byte of the row (mod length)
    mov ax, cx
    sub ax, [bp+DV_X1]
    and al, 7
    mov cl, al
    mov ch, 80h
    shr ch, cl                     ; bit
    mov es, [bp+T10]
    xor al, al
    xor cl, cl                     ; plane index
.plane:
    mov dx, bx
    add dl, cl
    adc dh, 0
    cmp dx, [bp+T9]
    jb .idx
    sub dx, [bp+T9]
.idx:
    push bx
    mov bx, [bp+T11]
    add bx, dx
    test [es:bx], ch
    pop bx
    jz .zero
    mov ah, 1
    shl ah, cl
    or al, ah
.zero:
    inc cl
    movzx dx, cl
    cmp dx, si
    jb .plane
    pop es
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ---------------------------------------------------------------- A0-A5
lio_ginit:
    mov ah, 42h
    mov ch, 80h                    ; lower 200 lines, colour
    int 18h
    mov ah, 40h
    int 18h
    xor al, al
    out MODE_FF2, al               ; digital palette
    mov al, 37h
    out PAL_A8, al
    mov al, 15h
    out PAL_AA, al
    mov al, 26h
    out PAL_AC, al
    mov al, 04h
    out PAL_AE, al
    push ds
    pop es
    mov di, LW
    mov cx, LW_SIZE
    xor al, al
    rep stosb
    mov byte [LW_PLANE], 1
    mov byte [LW_FG], 7
    xor bx, bx
.colour:
    mov [LW_COLOR+bx], bl
    inc bx
    cmp bx, 8
    jb .colour
    mov word [LW_VX2], 639
    mov word [LW_VY2], 399
    mov byte [LIO_PALMODE], 0
    xor al, al
    xor dx, dx
    out GR_DRAW_PAGE, al
    ret

; A1 GSCREEN: DS:BX -> mode, sw, act, disp (FFh = unchanged).
lio_gscreen:
    mov si, [bp+L_BX]
    mov cl, [bp+DV_PLANES]         ; colorbit
    mov al, [si]
    cmp al, 0FFh
    jne .mode
    mov al, [LW_SCRNMODE]
.mode:
    cmp al, 4
    jae .bad
    mov [bp+T0], al                ; scrnmode
    cmp byte [si], 0FFh
    je .sw
    cmp al, 2
    jb .sw
    push es
    xor dx, dx
    mov es, dx
    test byte [es:PRXCRT], 40h      ; 400-line modes need a 24 kHz display
    pop es
    jz .bad
.sw:
    mov ah, [si+1]
    cmp ah, 0FFh
    je .changed
    cmp ah, 4
    jae .bad
.changed:
    mov ah, [bp+T0]
    cmp ah, [LW_SCRNMODE]
    setne byte [bp+T0+1]           ; mode changed
    ; ---- active screen (pos, access)
    mov al, [si+2]
    cmp al, 0FFh
    jne .act
    xor ax, ax
    cmp byte [bp+T0+1], 0
    jne .act_set
    mov al, [LW_POS]
    mov ah, [LW_ACCESS]
    jmp .act_set
.act:
    xor ah, ah
    mov dl, [bp+T0]
    cmp dl, 0
    jne .act1
    mov ah, al
    and al, 1
    shr ah, 1
    jmp .act_chk
.act1:
    cmp dl, 3
    jne .act2
    mov ah, al
    xor al, al
    jmp .act_chk
.act2:
    mov dh, cl                     ; colorbit (mode 2) or 2 * colorbit (1)
    cmp dl, 1
    jne .act_div
    add dh, dh
.act_div:
    div dh                         ; AL = access, AH = pos
    xchg al, ah
.act_chk:
    cmp ah, 2
    jae .bad
.act_set:
    mov [bp+T1], al                ; pos
    mov [bp+T1+1], ah              ; access
    ; ---- display screen (plane, bank)
    mov al, [si+3]
    cmp al, 0FFh
    jne .disp
    mov ax, 0001h                  ; plane 1, bank 0
    cmp byte [bp+T0+1], 0
    jne .disp_set
    mov al, [LW_PLANE]
    mov ah, [LW_DISP]
    jmp .disp_set
.disp:
    mov dl, 2
    shl dl, cl
    dec dl                         ; (2 << colorbit) - 1
    mov ah, al
    and al, dl                     ; plane
    inc cl
    shr ah, cl                     ; bank
    dec cl
    cmp ah, 2
    jae .bad
    ; plane limits per mode
    mov dl, 1
    shl dl, cl                     ; upperbit
    test al, al
    jz .disp_set
    mov dh, [bp+T0]
    cmp dh, 0
    je .d0
    cmp al, dl
    je .disp_set
    cmp dh, 3
    je .bad_plane3
    cmp dh, 1
    jne .d2
    add dl, dl
    dec dl                         ; mode 1: upperbit * 2 - 1
    cmp al, dl
    ja .bad
    jmp .disp_set
.d2:
    dec dl                         ; mode 2: upperbit - 1
    cmp al, dl
    ja .bad
    jmp .disp_set
.bad_plane3:
    cmp al, 1
    ja .bad
    jmp .disp_set
.d0:
    cmp al, 2
    ja .bad
.disp_set:
    mov [bp+T2], al                ; plane
    mov [bp+T2+1], ah              ; bank
    ; ---- display on/off
    mov al, [si+1]
    cmp al, 0FFh
    je .store
    mov ah, 40h
    test al, 2
    jz .on
    mov ah, 41h
.on:
    int 18h
.store:
    mov al, [bp+T0]
    mov [LW_SCRNMODE], al
    mov ax, [bp+T1]
    mov [LW_POS], al
    mov [LW_ACCESS], ah
    mov ax, [bp+T2]
    mov [LW_PLANE], al
    mov [LW_DISP], ah
    cmp byte [bp+T0+1], 0
    je .crt
    xor ax, ax
    mov [LW_VX1], ax
    mov [LW_VY1], ax
    mov word [LW_VX2], 639
    mov word [LW_VY2], 199
    test byte [LW_SCRNMODE], 2
    jz .crt
    mov word [LW_VY2], 399
.crt:
    call lio_crtmode               ; CH = INT 18h 42h mode
    mov ah, 42h
    int 18h
    mov al, [LW_ACCESS]
    out GR_DRAW_PAGE, al
    xor al, al
    ret
.bad:
    mov al, LIO_ILLEGAL
    ret

; CH = INT 18h 42h mode for the current screen/plane/bank.
lio_crtmode:
    push ax
    push dx
    mov cl, [bp+DV_PLANES]
    mov dl, 1
    shl dl, cl                     ; upperbit
    mov al, [LW_PLANE]
    mov ah, [LW_SCRNMODE]
    mov ch, 0C0h
    test al, al
    jz .done
    cmp al, dl
    jne .by_mode
    test ah, ah
    jnz .done
    cmp cl, 3
    jne .done
.by_mode:
    cmp ah, 1
    jb .m0
    je .m1
    cmp ah, 2
    jne .bank                      ; mode 3: C0h
    dec dl                         ; lowmask
    test al, dl
    jz .bank
    mov ch, 0E0h
    jmp .bank
.m0:
    mov ch, 80h
    cmp al, 2
    jne .bank
    mov ch, 40h
    jmp .bank
.m1:
    mov ch, 0A0h
    test al, dl
    jz .bank
    mov ch, 60h
.bank:
    mov al, [LW_DISP]
    shl al, 4
    or ch, al
.done:
    pop dx
    pop ax
    ret

; A2 GVIEW: DS:BX -> x1, y1, x2, y2, background colour, frame colour.
lio_gview:
    mov si, [bp+L_BX]
    mov ax, [si]
    cmp ax, [si+4]
    jge .bad
    mov ax, [si+2]
    cmp ax, [si+6]
    jge .bad
    mov al, [si+8]
    cmp al, 0FFh
    je .ln
    cmp al, [bp+DV_PALMAX]
    jae .bad
.ln:
    mov al, [si+9]
    cmp al, 0FFh
    je .ok
    cmp al, [bp+DV_PALMAX]
    jae .bad
.ok:
    mov ax, [si]
    mov [LW_VX1], ax
    mov ax, [si+2]
    mov [LW_VY1], ax
    mov ax, [si+4]
    mov [LW_VX2], ax
    mov ax, [si+6]
    mov [LW_VY2], ax
    call lio_update
    mov ax, [bp+DV_X1]
    mov [bp+T0], ax
    mov ax, [bp+DV_Y1]
    mov [bp+T1], ax
    mov ax, [bp+DV_X2]
    mov [bp+T2], ax
    mov ax, [bp+DV_Y2]
    mov [bp+T3], ax
    mov al, [si+8]
    cmp al, 0FFh
    je .frame
    call lio_box
.frame:
    mov al, [si+9]
    cmp al, 0FFh
    je .done
    mov word [bp+T4], 0FFFFh
    call lio_frame
.done:
    xor al, al
    ret
.bad:
    mov al, LIO_ILLEGAL
    ret

; A3 GCOLOR1: DS:BX -> dummy, background, border, foreground, palette mode.
lio_gcolor1:
    mov si, [bp+L_BX]
    mov al, [si+1]
    cmp al, 0FFh
    je .fg
    mov [LW_BG], al
.fg:
    mov al, [si+3]
    cmp al, 0FFh
    je .pal
    mov [LW_FG], al
.pal:
    mov al, [si+4]
    cmp al, 0FFh
    je .done
    push es
    xor dx, dx
    mov es, dx
    mov ah, [es:PRXCRT]
    pop es
    test ah, 01h                   ; 8-colour only machine
    jz .digital
    test ah, 04h                   ; 16 colours need the E plane
    jz .bad
    push ax
    test al, al
    setnz al
    out MODE_FF2, al               ; 00h digital, 01h analog
    pop ax
    mov [LIO_PALMODE], al
    jmp .done
.digital:
    mov byte [LIO_PALMODE], 0
.done:
    xor al, al
    ret
.bad:
    mov al, LIO_ILLEGAL
    ret

; A4 GCOLOR2: DS:BX -> palette, colour1 (digital colour or R<<4|B), colour2 (G).
lio_gcolor2:
    mov si, [bp+L_BX]
    mov bl, [si]                   ; palette number
    mov ah, 8
    cmp byte [LIO_PALMODE], 2
    jne .max
    mov ah, 16
.max:
    cmp bl, ah
    jae .bad
    cmp byte [LIO_PALMODE], 0
    jne .analog
    mov al, [si+1]
    and al, 7
    mov ah, [LW_SCRNMODE]
    dec ah
    cmp ah, 1                      ; modes 1 and 2: monochrome palette
    ja .store
    test al, 1
    mov al, 0
    jz .store
    mov al, 7
.store:
    xor bh, bh
    mov [LW_COLOR+bx], al
    call lio_set_digital
    xor al, al
    ret
.analog:
    mov al, bl
    out PAL_A8, al
    mov al, [si+2]
    and al, 0Fh
    out PAL_AA, al                 ; green
    mov al, [si+1]
    shr al, 4
    out PAL_AC, al                 ; red
    mov al, [si+1]
    and al, 0Fh
    out PAL_AE, al                 ; blue
    xor al, al
    ret
.bad:
    mov al, LIO_ILLEGAL
    ret

; Digital palette entry BL (0-7) = colour AL. Rewrites the port pair from
; the work-area copy (ports are write-only in general).
lio_set_digital:
    push bx
    push cx
    and bx, 3
    mov al, [LW_COLOR+bx]
    shl al, 4
    or al, [LW_COLOR+bx+4]
    ; colours n and n+4 share a port: 0/4 AEh, 1/5 AAh, 2/6 ACh, 3/7 A8h
    mov cl, [cs:lio_palport+bx]
    xor ch, ch
    mov dx, cx
    out dx, al
    pop cx
    pop bx
    ret
lio_palport: db PAL_AE, PAL_AA, PAL_AC, PAL_A8

; A5 GCLS: fill the window with the background colour.
lio_gcls:
    mov ax, [bp+DV_X1]
    mov [bp+T0], ax
    mov ax, [bp+DV_Y1]
    mov [bp+T1], ax
    mov ax, [bp+DV_X2]
    mov [bp+T2], ax
    mov ax, [bp+DV_Y2]
    mov [bp+T3], ax
    mov al, [LW_BG]
    call lio_box
    xor al, al
    ret

; ---------------------------------------------------------------- A6, AF
; A6 GPSET: DS:BX -> x, y, colour (FFh: AH=1 foreground, AH=2 background).
lio_gpset:
    mov si, [bp+L_BX]
    mov al, [si+4]
    cmp al, 0FFh
    jne .pal
    mov ah, [bp+L_AH]
    mov al, [LW_FG]
    cmp ah, 1
    je .pal
    mov al, [LW_BG]
    cmp ah, 2
    jne .bad
.pal:
    cmp al, [bp+DV_PALMAX]
    jae .bad
    mov cx, [si]
    mov dx, [si+2]
    call lio_pset
    xor al, al
    ret
.bad:
    mov al, LIO_ILLEGAL
    ret

; AF GPOINT2: DS:BX -> x, y. Returns AL = colour (FFh outside the window).
lio_gpoint2:
    mov si, [bp+L_BX]
    mov cx, [si]
    mov dx, [si+2]
    call lio_point
    mov [bp+L_AL], al
    xor al, al
    ret

; ---------------------------------------------------------------- A7 GLINE
; DS:BX -> x1, y1, x2, y2, colour, type (0 line, 1 box, 2 filled box),
; sw (0 solid, 1 style / fill colour, 2 tile), style[2], tile length,
; tile offset, tile segment.
lio_gline:
    mov si, [bp+L_BX]
    mov ax, [si]
    mov [bp+T0], ax
    mov ax, [si+2]
    mov [bp+T1], ax
    mov ax, [si+4]
    mov [bp+T2], ax
    mov ax, [si+6]
    mov [bp+T3], ax
    mov bl, [si+8]                 ; colour
    cmp bl, 0FFh
    jne .pal
    mov bl, [LW_FG]
.pal:
    cmp bl, [bp+DV_PALMAX]
    jae .bad
    mov bh, [si+10]                ; sw
    cmp bh, 2
    ja .bad
    mov al, [si+9]                 ; type
    cmp al, 2
    je .filled
    ja .bad
    cmp bh, 2
    je .bad
    mov word [bp+T4], 0FFFFh
    cmp bh, 1
    jne .draw
    mov al, [si+11]
    call lio_reverse
    mov ah, al
    mov al, [si+12]
    call lio_reverse
    mov [bp+T4], ax                ; rev(style0) << 8 | rev(style1)
.draw:
    mov al, bl
    cmp byte [si+9], 0
    jne .box
    call lio_line
    jmp .ok
.box:
    call lio_frame
    jmp .ok
.filled:
    cmp bh, 2
    je .tile
    cmp bh, 1
    je .fillcolour
    mov al, bl
    call lio_box
    jmp .ok
.fillcolour:                       ; fill with style[0], frame with colour
    mov al, [si+11]
    cmp al, 0FFh
    jne .fc
    mov al, [LW_FG]
.fc:
    cmp al, [bp+DV_PALMAX]
    jae .bad
    call lio_box
    mov word [bp+T4], 0FFFFh
    mov al, bl
    call lio_frame
    jmp .ok
.tile:
    movzx ax, byte [si+13]         ; tile length
    call lio_tile_check
    jc .bad
    mov [bp+T9], ax
    mov ax, [si+14]
    mov [bp+T11], ax
    mov ax, [si+16]
    mov [bp+T10], ax
    call lio_tile_box
.ok:
    xor al, al
    ret
.bad:
    mov al, LIO_ILLEGAL
    ret

; CF=1 unless AX is a positive multiple of the number of planes.
lio_tile_check:
    push ax
    push dx
    push cx
    test ax, ax
    jz .bad
    movzx cx, byte [bp+DV_PLANES]
    cmp byte [bp+DV_MONO], 0
    je .div
    mov cx, 1
.div:
    xor dx, dx
    div cx
    test dx, dx
    jnz .bad
    clc
    jmp .done
.bad:
    stc
.done:
    pop cx
    pop dx
    pop ax
    ret

; ---------------------------------------------------------------- A8 GCIRCLE
; DS:BX -> cx, cy, rx, ry, colour, flags, sx, sy, ex, ey, fill colour /
; tile length, tile offset, tile segment. Flags: 01h start point, 02h line
; to start, 04h end point, 08h line to end, 10h start = end is one point,
; 20h fill, 40h tile fill.
C_CX            equ T0
C_CY            equ T1
C_RX            equ T2
C_RY            equ T3
C_FLAGS         equ T4
C_X             equ T5
C_Y             equ T6
lio_gcircle:
    mov si, [bp+L_BX]
    test byte [si+9], 80h
    jnz .bad
    mov ax, [si+4]
    or ax, [si+6]
    js .bad
    mov bl, [si+8]
    cmp bl, 0FFh
    jne .pal
    mov bl, [LW_FG]
.pal:
    cmp bl, [bp+DV_PALMAX]
    jae .bad
    mov ax, [si]
    mov [bp+C_CX], ax
    mov ax, [si+2]
    mov [bp+C_CY], ax
    mov ax, [si+4]
    mov [bp+C_RX], ax
    mov ax, [si+6]
    mov [bp+C_RY], ax
    mov al, [si+9]
    mov [bp+C_FLAGS], al
    ; fill first (the outline is drawn over it)
    test al, 20h
    jz .outline
    test al, 40h
    jnz .tile
    mov bh, [si+18]
    cmp bh, 0FFh
    jne .fillpal
    mov bh, bl
.fillpal:
    cmp bh, [bp+DV_PALMAX]
    jae .bad
    mov al, bh
    call lio_ellipse_fill
    jmp .outline
.tile:
    movzx ax, byte [si+18]
    call lio_tile_check
    jc .bad
    mov [bp+T9], ax
    mov ax, [si+19]
    mov [bp+T11], ax
    mov ax, [si+21]
    mov [bp+T10], ax
    mov al, 0FEh                   ; FEh: tile colour
    call lio_ellipse_fill
.outline:
    mov al, bl
    call lio_ellipse
    ; radius lines of an arc
    mov si, [bp+L_BX]
    test byte [bp+C_FLAGS], 02h
    jz .endline
    mov ax, [si+10]
    mov dx, [si+12]
    call lio_radius
.endline:
    test byte [bp+C_FLAGS], 08h
    jz .ok
    mov ax, [si+14]
    mov dx, [si+16]
    call lio_radius
.ok:
    xor al, al
    ret
.bad:
    mov al, LIO_ILLEGAL
    ret

; Line from the centre to (AX, DX) in colour BL.
lio_radius:
    push word [bp+T0]
    push word [bp+T1]
    push word [bp+T2]
    push word [bp+T3]
    push word [bp+T4]
    mov [bp+T2], ax
    mov [bp+T3], dx
    mov word [bp+T4], 0FFFFh
    mov al, bl
    call lio_line
    pop word [bp+T4]
    pop word [bp+T3]
    pop word [bp+T2]
    pop word [bp+T1]
    pop word [bp+T0]
    ret

; CF=0 if offset (CX, DX) from the centre lies on the arc selected by the
; start/end flags: counter-clockwise from start to end with the y axis up.
; Uses registers only (the callers keep state in the scratch words).
lio_on_arc:
    test byte [bp+C_FLAGS], 05h
    jnz .test
    clc
    ret
.test:
    pushad
    movsx eax, cx                  ; P.x
    movsx ebx, dx
    neg ebx                        ; P.y
    call lio_arc_vectors           ; ECX, EDX = S; ESI, EDI = E
    push eax
    push ebx
    ; c3 = S x E
    mov eax, ecx
    imul eax, edi
    mov ebx, edx
    imul ebx, esi
    sub eax, ebx
    jnz .have_c3
    ; parallel: same direction = full ellipse, opposite = half
    mov eax, ecx
    imul eax, esi
    mov ebx, edx
    imul ebx, edi
    add eax, ebx                   ; S . E
    jg .full
    mov eax, 0                     ; half: inside if c1 >= 0
.have_c3:
    push eax                       ; [esp] c3, [esp+4] P.y, [esp+8] P.x
    mov ebx, [esp+4]
    mov eax, [esp+8]
    imul ebx, ecx                  ; P.y * S.x
    imul edx, eax                  ; S.y * P.x
    sub ebx, edx                   ; c1 = S x P
    imul eax, edi                  ; P.x * E.y
    mov ecx, [esp+4]
    imul ecx, esi                  ; P.y * E.x
    sub eax, ecx                   ; c2 = P x E
    pop ecx                        ; c3
    add esp, 8
    test ecx, ecx
    jz .half
    js .major
    test ebx, ebx                  ; minor arc: both on the inside
    js .no
    test eax, eax
    js .no
    jmp .yes
.major:
    test ebx, ebx
    jns .yes
    test eax, eax
    jns .yes
    jmp .no
.half:
    test ebx, ebx
    jns .yes
    jmp .no
.full:
    add esp, 8
.yes:
    popad
    clc
    ret
.no:
    popad
    stc
    ret

; ECX, EDX = start vector, ESI, EDI = end vector (relative to the centre,
; y axis up; a missing point means the +x axis). Preserves EAX, EBX.
lio_arc_vectors:
    push eax
    push bx
    mov bx, [bp+L_BX]
    mov ecx, 1
    xor edx, edx
    test byte [bp+C_FLAGS], 01h
    jz .s
    movsx ecx, word [bx+10]
    movsx eax, word [bp+C_CX]
    sub ecx, eax
    movsx edx, word [bx+12]
    movsx eax, word [bp+C_CY]
    sub edx, eax
    neg edx
.s:
    mov esi, 1
    xor edi, edi
    test byte [bp+C_FLAGS], 04h
    jz .e
    movsx esi, word [bx+14]
    movsx eax, word [bp+C_CX]
    sub esi, eax
    movsx edi, word [bx+16]
    movsx eax, word [bp+C_CY]
    sub edi, eax
    neg edi
.e:
    pop bx
    pop eax
    ret

; Plot (centre + (CX, DX)) in colour AL if it lies on the arc.
lio_arc_plot:
    call lio_on_arc
    jc .skip
    push cx
    push dx
    add cx, [bp+C_CX]
    add dx, [bp+C_CY]
    call lio_pset
    pop dx
    pop cx
.skip:
    ret

; AX = half width of the ellipse (radii C_RX, C_RY) on row |AX| from the
; centre: isqrt(a^2 (b^2 - y^2) / b^2), with 64-bit intermediates.
lio_ellipse_width:
    push ebx
    push ecx
    push edx
    movsx ecx, ax
    test ecx, ecx
    jns .pos
    neg ecx
.pos:
    movzx ebx, word [bp+C_RY]
    xor eax, eax
    cmp ecx, ebx
    ja .done                       ; outside: width 0 (caller filters)
    movzx eax, word [bp+C_RX]
    test ebx, ebx
    jz .done                       ; flat ellipse: full width
    imul ecx, ecx                  ; y^2
    imul ebx, ebx                  ; b^2
    push ebx
    sub ebx, ecx                   ; b^2 - y^2
    imul eax, eax                  ; a^2
    mul ebx                        ; EDX:EAX = a^2 (b^2 - y^2)
    pop ebx
    div ebx                        ; EAX = x^2 bound
    call lio_isqrt
.done:
    pop edx
    pop ecx
    pop ebx
    ret

; EAX = floor(sqrt(EAX)).
lio_isqrt:
    push ebx
    push ecx
    push edx
    mov ecx, eax                   ; remainder
    xor eax, eax                   ; result
    mov ebx, 40000000h
.shift:
    cmp ebx, ecx
    jbe .loop
    shr ebx, 2
    jnz .shift
.loop:
    test ebx, ebx
    jz .done
    lea edx, [eax+ebx]
    cmp ecx, edx
    jb .smaller
    sub ecx, edx
    shr eax, 1
    add eax, ebx
    jmp .next
.smaller:
    shr eax, 1
.next:
    shr ebx, 2
    jmp .loop
.done:
    pop edx
    pop ecx
    pop ebx
    ret

; Plot (+-CX, +-DX) around the centre in colour AL (arc-filtered).
lio_plot4:
    call lio_arc_plot
    neg cx
    call lio_arc_plot
    neg dx
    call lio_arc_plot
    neg cx
    call lio_arc_plot
    neg dx
    ret

; Ellipse outline in colour AL. Row y (0..b) gets the pixels between the
; half width of the row below it and its own half width, so the outline is
; connected at any radius.
lio_ellipse:
    push ax
    push bx
    push cx
    push dx
    push si
    mov bl, al
    xor dx, dx                     ; y
.row:
    cmp dx, [bp+C_RY]
    ja .done
    mov ax, dx
    call lio_ellipse_width
    mov si, ax                     ; this row
    mov ax, -1
    cmp dx, [bp+C_RY]
    je .top
    mov ax, dx
    inc ax
    call lio_ellipse_width
.top:
    inc ax
    mov cx, ax                     ; from (next row width + 1)
    cmp cx, si
    jle .x
    mov cx, si
.x:
    cmp cx, si
    jg .next
    mov al, bl
    call lio_plot4
    inc cx
    jmp .x
.next:
    inc dx
    jmp .row
.done:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Filled ellipse (a pie for arcs) in colour AL; AL = FEh uses the tile.
lio_ellipse_fill:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bl, al
    mov dx, [bp+C_RY]
    neg dx
.row:
    cmp dx, [bp+C_RY]
    jg .done
    mov ax, dx
    call lio_ellipse_width
    mov si, ax
    ; full ellipses with a solid colour: one span
    test byte [bp+C_FLAGS], 05h
    jnz .pixels
    cmp bl, 0FEh
    je .pixels
    push dx
    mov cx, [bp+C_CX]
    sub cx, si
    mov di, [bp+C_CX]
    add di, si
    add dx, [bp+C_CY]
    push si
    mov si, di
    mov al, bl
    call lio_hline
    pop si
    pop dx
    jmp .next
.pixels:
    mov cx, si
    neg cx
.px:
    cmp cx, si
    jg .next
    call lio_on_arc
    jc .skip
    push cx
    push dx
    add cx, [bp+C_CX]
    add dx, [bp+C_CY]
    mov al, bl
    cmp al, 0FEh
    jne .plot
    call lio_tile_colour
.plot:
    call lio_pset
    pop dx
    pop cx
.skip:
    inc cx
    jmp .px
.next:
    inc dx
    jmp .row
.done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ---------------------------------------------------------------- A9, AA
; A9 GPAINT1: DS:BX -> x, y, colour, border colour, work end, work start.
; AA GPAINT2: DS:BX -> x, y, -, tile length, tile off, tile seg, border,
; 5 bytes, work end, work start.
; Scan-line flood fill using the caller's work area as the stack. A pixel
; can be filled if it is inside the window and neither the border colour
; nor already painted (for tiles, a mark bitmap at A400:0000 records
; painted pixels, which limits tile paint to windows of 204 lines).
P_X             equ T0
P_Y             equ T1
P_START         equ T2
P_END           equ T3
P_SP            equ T4
P_XL            equ T5
P_XR            equ T6
P_COL           equ T7            ; low: colour (FEh tile), high: border
MARK_SEG        equ 0A400h
lio_gpaint1:
    mov si, [bp+L_BX]
    mov al, [si+4]
    cmp al, 0FFh
    jne .pal
    mov al, [LW_FG]
.pal:
    cmp al, [bp+DV_PALMAX]
    jae lio_paint_bad
    mov ah, [si+5]
    cmp ah, 0FFh
    jne .bd
    mov ah, al
.bd:
    cmp ah, [bp+DV_PALMAX]
    jae lio_paint_bad
    mov [bp+P_COL], ax
    mov ax, [si+6]
    mov [bp+P_END], ax
    mov ax, [si+8]
    mov [bp+P_START], ax
    jmp lio_paint

lio_gpaint2:
    mov si, [bp+L_BX]
    movzx ax, byte [si+5]
    call lio_tile_check
    jc lio_paint_bad
    mov [bp+T9], ax
    mov ax, [si+6]
    mov [bp+T11], ax
    mov ax, [si+8]
    mov [bp+T10], ax
    mov ah, [si+10]
    cmp ah, [bp+DV_PALMAX]
    jae lio_paint_bad
    mov al, 0FEh
    mov [bp+P_COL], ax
    mov ax, [si+16]
    mov [bp+P_END], ax
    mov ax, [si+18]
    mov [bp+P_START], ax
    ; mark bitmap covers 204 lines of 640 pixels
    mov ax, [bp+DV_Y2]
    sub ax, [bp+DV_Y1]
    cmp ax, 204
    jae lio_paint_bad
    push es
    mov ax, MARK_SEG
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 16320/2
    rep stosw
    pop es
    jmp lio_paint

lio_paint_bad:
    mov al, LIO_ILLEGAL
    ret

; CF=0 if (CX, DX) can be painted.
lio_paint_ok:
    push ax
    call lio_point
    cmp al, 0FFh
    je .no
    cmp al, [bp+P_COL+1]           ; border
    je .no
    cmp byte [bp+P_COL], 0FEh
    je .tile
    cmp al, [bp+P_COL]             ; already this colour
    je .no
    pop ax
    clc
    ret
.tile:
    call lio_mark_test
    jnz .no
    pop ax
    clc
    ret
.no:
    pop ax
    stc
    ret

; ZF=0 if (CX, DX) is marked; lio_mark_set marks it.
lio_mark_test:
    push ax
    push bx
    push cx
    push es
    mov ax, dx
    sub ax, [bp+DV_Y1]
    imul bx, ax, 80
    mov ax, cx
    shr ax, 3
    add bx, ax
    and cl, 7
    mov al, 80h
    shr al, cl
    mov cx, MARK_SEG
    mov es, cx
    test [es:bx], al
    pop es
    pop cx
    pop bx
    pop ax
    ret
lio_mark_set:
    push ax
    push bx
    push cx
    push es
    mov ax, dx
    sub ax, [bp+DV_Y1]
    imul bx, ax, 80
    mov ax, cx
    shr ax, 3
    add bx, ax
    and cl, 7
    mov al, 80h
    shr al, cl
    mov cx, MARK_SEG
    mov es, cx
    or [es:bx], al
    pop es
    pop cx
    pop bx
    pop ax
    ret

; Push (CX, DX) on the work stack. CF=1 when full.
lio_paint_push:
    mov bx, [bp+P_SP]
    lea ax, [bx+4]
    cmp ax, [bp+P_END]
    ja .full
    mov [bx], cx
    mov [bx+2], dx
    mov [bp+P_SP], ax
    clc
    ret
.full:
    stc
    ret

lio_paint:
    mov ax, [bp+P_END]
    sub ax, [bp+P_START]
    jbe lio_paint_bad
    cmp ax, 16
    jb lio_paint_bad
    mov si, [bp+L_BX]
    mov cx, [si]
    mov dx, [si+2]
    call lio_outside
    jc lio_paint_bad
    call lio_paint_ok
    jc .ok
    mov ax, [bp+P_START]
    mov [bp+P_SP], ax
    call lio_paint_push
.pop:
    mov bx, [bp+P_SP]
    cmp bx, [bp+P_START]
    jbe .ok
    sub bx, 4
    mov [bp+P_SP], bx
    mov cx, [bx]
    mov dx, [bx+2]
    call lio_paint_ok
    jc .pop
    ; extend left and right
    mov si, cx
.left:
    cmp si, [bp+DV_X1]
    jle .leftdone
    dec si
    push cx
    mov cx, si
    call lio_paint_ok
    pop cx
    jnc .left
    inc si
.leftdone:
    mov [bp+P_XL], si
    mov si, cx
.right:
    cmp si, [bp+DV_X2]
    jge .rightdone
    inc si
    push cx
    mov cx, si
    call lio_paint_ok
    pop cx
    jnc .right
    dec si
.rightdone:
    mov [bp+P_XR], si
    ; paint the run
    mov cx, [bp+P_XL]
.run:
    cmp cx, [bp+P_XR]
    jg .neighbours
    cmp byte [bp+P_COL], 0FEh
    jne .solid
    call lio_mark_set
    call lio_tile_colour
    jmp .plot
.solid:
    mov al, [bp+P_COL]
.plot:
    call lio_pset
    inc cx
    jmp .run
.neighbours:
    push dx
    dec dx
    cmp dx, [bp+DV_Y1]
    jl .below
    call .scan
    jc .full
.below:
    pop dx
    push dx
    inc dx
    cmp dx, [bp+DV_Y2]
    jg .next
    call .scan
    jc .full
.next:
    pop dx
    jmp .pop
.full:
    pop dx
    mov al, LIO_NOMEM
    ret
.ok:
    xor al, al
    ret
; push the start of each paintable run of line DX within [XL, XR]
.scan:
    mov cx, [bp+P_XL]
    xor di, di                     ; in run
.sx:
    cmp cx, [bp+P_XR]
    jg .send
    call lio_paint_ok
    jc .sgap
    test di, di
    jnz .snext
    mov di, 1
    call lio_paint_push
    jc .sret
    jmp .snext
.sgap:
    xor di, di
.snext:
    inc cx
    jmp .sx
.send:
    clc
.sret:
    ret

; ---------------------------------------------------------------- AB-AD
; AB GGET: DS:BX -> x1, y1, x2, y2, buffer offset, segment, length.
; Buffer: width, height words, then per line one byte row per plane
; (blue, red, green[, E]; the selected plane only in monochrome modes).
lio_gget:
    mov si, [bp+L_BX]
    mov cx, [si]
    mov dx, [si+2]
    cmp cx, [bp+DV_X1]
    jl .bad
    cmp dx, [bp+DV_Y1]
    jl .bad
    mov ax, [si+4]
    cmp ax, [bp+DV_X2]
    jg .bad
    sub ax, cx
    inc ax
    jle .bad
    mov [bp+T2], ax                ; width
    mov ax, [si+6]
    cmp ax, [bp+DV_Y2]
    jg .bad
    sub ax, dx
    inc ax
    jle .bad
    mov [bp+T3], ax                ; height
    call lio_put_planes            ; T4 = planes stored, T5 = bytes per row
    push dx
    mov ax, [bp+T5]
    mul word [bp+T4]
    mul word [bp+T3]
    pop dx
    add ax, 4
    jc .bad
    cmp ax, [si+12]
    ja .bad
    mov es, [si+10]
    mov di, [si+8]
    mov ax, [bp+T2]
    stosw
    mov ax, [bp+T3]
    stosw
    mov [bp+T0], cx
    mov [bp+T1], dx
.line:
    xor bx, bx                     ; plane slot
.plane:
    cmp bx, [bp+T4]
    jae .nextline
    mov cx, [bp+T0]
    mov si, [bp+T2]                ; pixels left
.byte:
    xor ah, ah
    mov al, 80h
.bit:
    push ax
    call lio_plane_bit             ; AL = bit of plane slot BX at (CX, DX)
    mov [bp+T6], al
    pop ax
    cmp byte [bp+T6], 0
    je .zero
    or ah, al
.zero:
    inc cx
    dec si
    jz .flush
    shr al, 1
    jnz .bit
.flush:
    mov [es:di], ah
    inc di
    test si, si
    jnz .byte
    inc bx
    jmp .plane
.nextline:
    inc dx
    mov ax, dx
    sub ax, [bp+T1]
    cmp ax, [bp+T3]
    jb .line
    xor al, al
    ret
.bad:
    mov al, LIO_ILLEGAL
    ret

; T4 = number of stored planes, T5 = bytes per row (from width T2).
lio_put_planes:
    movzx ax, byte [bp+DV_PLANES]
    cmp byte [bp+DV_MONO], 0
    je .n
    mov ax, 1
.n:
    mov [bp+T4], ax
    mov ax, [bp+T2]
    add ax, 7
    shr ax, 3
    mov [bp+T5], ax
    ret

; AL = 1 if plane slot BX (mono: the selected plane) is set at (CX, DX).
lio_plane_bit:
    push bx
    push cx
    push di
    push es
    push si
    mov si, bx
    cmp byte [bp+DV_MONO], 0
    je .slot
    movzx si, byte [bp+DV_PLANE]
.slot:
    add si, si
    push ax
    call lio_addr
    mov al, ah
    mov es, [cs:lio_planeseg+si]
    test [es:di], al
    pop ax
    setnz al
    pop si
    pop es
    pop di
    pop cx
    pop bx
    ret

; AC GPUT1: DS:BX -> x, y, buffer offset, segment, length, mode (0 PSET,
; 1 PRESET, 2 OR, 3 AND, 4 XOR), colour switch, foreground, background.
lio_gput1:
    mov si, [bp+L_BX]
    cmp byte [si+10], 4
    ja .bad
    cmp byte [si+11], 1
    ja .bad
    mov es, [si+6]
    mov di, [si+4]
    mov ax, [es:di]
    mov [bp+T2], ax                ; width
    mov ax, [es:di+2]
    mov [bp+T3], ax                ; height
    add di, 4
    mov [bp+T8], di                ; data offset
    mov [bp+T9], es
    mov al, [si+10]
    mov [bp+T7], al                ; mode
    cmp byte [si+11], 0
    je .colour
    ; one bit plane of data drawn with foreground/background
    mov al, [si+12]
    mov ah, [si+13]
    cmp byte [bp+DV_MONO], 0
    je .fgcheck
    test al, al
    setnz al
    test ah, ah
    setnz ah
    jmp .fgok
.fgcheck:
    cmp al, [bp+DV_PALMAX]
    jae .bad
    cmp ah, [bp+DV_PALMAX]
    jae .bad
.fgok:
    mov [bp+T6], ax
    mov word [bp+T4], 1            ; one stored plane
    mov ax, [bp+T2]
    add ax, 7
    shr ax, 3
    mov [bp+T5], ax
    jmp .size
.colour:
    call lio_put_planes
    mov word [bp+T6], 0FFFFh       ; colour data
.size:
    mov ax, [bp+T5]
    mul word [bp+T4]
    mul word [bp+T3]
    add ax, 4
    cmp ax, [si+8]
    ja .bad
    mov cx, [si]
    mov dx, [si+2]
    call lio_put
    xor al, al
    ret
.bad:
    mov al, LIO_ILLEGAL
    ret

; Draw a GET-format image at (CX, DX): T2 width, T3 height, T4 stored
; planes, T5 bytes per row, T8:T9 data offset/segment, T7 mode, T6 =
; FFFFh for colour data, else AL = foreground, AH = background.
lio_put:
    push cx
    push dx
    mov [bp+T0], cx
    mov [bp+T1], dx
    xor bx, bx                     ; line
.line:
    cmp bx, [bp+T3]
    jae .done
    xor si, si                     ; column
.col:
    cmp si, [bp+T2]
    jae .nextline
    ; source colour of pixel (si, bx)
    push bx
    mov ax, bx
    mul word [bp+T4]
    mul word [bp+T5]               ; start of this line's rows
    mov di, [bp+T8]
    add di, ax
    mov ax, si
    shr ax, 3
    add di, ax
    mov cx, si
    and cl, 7
    mov ch, 80h
    shr ch, cl                     ; bit
    push es
    mov es, [bp+T9]
    xor al, al
    xor cl, cl
.src:
    movzx dx, cl
    cmp dx, [bp+T4]
    jae .gotsrc
    test [es:di], ch
    jz .s0
    mov dl, 1
    shl dl, cl
    or al, dl
.s0:
    add di, [bp+T5]
    inc cl
    jmp .src
.gotsrc:
    pop es
    pop bx
    ; map through foreground/background for one-plane data
    cmp word [bp+T6], 0FFFFh
    je .mono_map
    mov dl, byte [bp+T6+1]         ; background
    test al, al
    jz .mapped
    mov dl, byte [bp+T6]           ; foreground
.mapped:
    mov al, dl
    jmp .apply
.mono_map:
    cmp byte [bp+DV_MONO], 0
    je .apply
    and al, 1
.apply:
    mov cx, [bp+T0]
    add cx, si
    mov dx, [bp+T1]
    add dx, bx
    call lio_put_pixel
    inc si
    jmp .col
.nextline:
    inc bx
    jmp .line
.done:
    pop dx
    pop cx
    ret

; Combine colour AL into (CX, DX) with the put mode in T7.
lio_put_pixel:
    call lio_outside
    jc .done
    push ax
    mov ah, [bp+T7]
    cmp ah, 0                      ; PSET
    je .set
    mov dl, [bp+DV_PALMAX]
    dec dl                         ; colour mask
    push dx
    mov dx, [bp+T1]
    add dx, bx
    push ax
    call lio_point
    mov dh, al                     ; destination
    pop ax
    cmp ah, 1                      ; PRESET: complement of the source
    jne .or
    not al
    jmp .masked
.or:
    cmp ah, 2
    jne .and
    or al, dh
    jmp .masked
.and:
    cmp ah, 3
    jne .xor
    and al, dh
    jmp .masked
.xor:
    xor al, dh
.masked:
    pop dx
    and al, dl
    mov dx, [bp+T1]
    add dx, bx
.set:
    call lio_pset
    pop ax
.done:
    ret

; AD GPUT2: DS:BX -> x, y, character code, mode, colour switch, fg, bg.
; Draws an 8x16 ANK or 16x16 kanji glyph from the character generator.
lio_gput2:
    mov si, [bp+L_BX]
    cmp byte [si+6], 4
    ja .bad
    cmp byte [si+7], 1
    ja .bad
    mov al, [si+6]
    mov [bp+T7], al
    mov al, [LW_FG]
    mov ah, [LW_BG]
    cmp byte [si+7], 0
    je .colours
    mov al, [si+8]
    mov ah, [si+9]
    cmp byte [bp+DV_MONO], 0
    je .check
    test al, al
    setnz al
    test ah, ah
    setnz ah
    jmp .colours
.check:
    cmp al, [bp+DV_PALMAX]
    jae .bad
    cmp ah, [bp+DV_PALMAX]
    jae .bad
.colours:
    mov [bp+T6], ax
    ; glyph into TB (bytes per row in T5)
    mov dx, [si+4]
    cmp dx, 100h
    jb .ank
    cmp dx, 200h
    jae .kanji
    xor dh, dh
.ank:
    xor al, al
    out CG_CODE_HI, al
    mov al, dl
    out CG_CODE_LO, al
    lea di, [bp+TB]
    xor cx, cx
.aline:
    mov al, cl
    or al, 20h
    out CG_LINE, al
    in al, CG_DATA
    mov [ss:di], al
    inc di
    inc cx
    cmp cx, 16
    jb .aline
    mov word [bp+T2], 8
    mov word [bp+T5], 1
    jmp .draw
.kanji:
    mov al, dl
    out CG_CODE_HI, al
    mov al, dh
    sub al, 20h
    out CG_CODE_LO, al
    lea di, [bp+TB]
    xor cx, cx
.kline:
    mov al, cl
    or al, 20h
    out CG_LINE, al
    in al, CG_DATA
    mov [ss:di], al
    mov al, cl
    out CG_LINE, al
    in al, CG_DATA
    mov [ss:di+1], al
    add di, 2
    inc cx
    cmp cx, 16
    jb .kline
    mov word [bp+T2], 16
    mov word [bp+T5], 2
.draw:
    mov word [bp+T3], 16
    mov word [bp+T4], 1
    lea ax, [bp+TB]
    mov [bp+T8], ax
    mov [bp+T9], ss
    mov cx, [si]
    mov dx, [si+2]
    call lio_put
    xor al, al
    ret
.bad:
    mov al, LIO_ILLEGAL
    ret

; ---------------------------------------------------------------- AE GROLL
; DS:BX -> dy, dx (pixels, moved in whole bytes), clear flag. Scrolls the
; whole page by (dx, dy): destination (x, y) takes source (x + dx, y + dy);
; uncovered parts become the background colour (clear = 1) or 0.
lio_groll:
    mov si, [bp+L_BX]
    cmp byte [si+4], 1
    ja .bad
    mov ax, 200
    test byte [LW_SCRNMODE], 2
    jz .h
    mov ax, 400
.h:
    mov [bp+T3], ax                ; height
    mov cx, [si]                   ; dy
    mov ax, cx
    test ax, ax
    jns .ady
    neg ax
.ady:
    cmp ax, [bp+T3]
    jae .bad
    mov [bp+T1], cx
    mov ax, [si+2]                 ; dx
    cmp ax, -639
    jl .bad
    cmp ax, 639
    jg .bad
    cwd
    mov cx, 8
    idiv cx
    mov [bp+T0], ax                ; dx in bytes
    xor al, al
    cmp byte [si+4], 0
    je .fill
    mov al, [LW_BG]
.fill:
    mov [bp+T7], al
    ; planes
    xor bx, bx
.plane:
    movzx ax, byte [bp+DV_PLANES]
    cmp byte [bp+DV_MONO], 0
    je .count
    mov ax, 1
.count:
    cmp bx, ax
    jae .ok
    mov si, bx
    cmp byte [bp+DV_MONO], 0
    je .seg
    movzx si, byte [bp+DV_PLANE]
.seg:
    movzx ax, byte [bp+T7]         ; clear colour
    cmp byte [bp+DV_MONO], 0
    jne .fb
    bt ax, bx                      ; this plane's bit of the colour
    sbb cl, cl                     ; 00h or FFh
    jmp .fbdone
.fb:
    test al, al
    setnz cl
    neg cl
.fbdone:
    mov [bp+T6], cl
    add si, si
    push bx
    push ds
    mov es, [cs:lio_planeseg+si]
    mov ds, [cs:lio_planeseg+si]
    call lio_roll_plane
    pop ds
    pop bx
    inc bx
    jmp .plane
.ok:
    xor al, al
    ret
.bad:
    mov al, LIO_ILLEGAL
    ret

; Scroll one plane (DS = ES = plane) by T0 bytes, T1 lines over T3 lines.
lio_roll_plane:
    mov ax, [bp+T1]
    test ax, ax
    js .up
    ; dy >= 0: copy top to bottom
    xor dx, dx
.down_line:
    cmp dx, [bp+T3]
    jae .done
    call .copy_line
    inc dx
    jmp .down_line
.up:
    mov dx, [bp+T3]
.up_line:
    dec dx
    js .done
    call .copy_line
    jmp .up_line
.done:
    ret
; line DX = source line DX + dy, shifted by T0 bytes
.copy_line:
    mov di, dx
    imul di, di, 80
    add di, [bp+DV_UPPER]
    mov ax, dx
    add ax, [bp+T1]
    xor bx, bx                     ; byte column
.col:
    cmp bx, 80
    jae .ret
    ; iterate columns so that sources are read before they are overwritten
    mov cx, bx
    cmp word [bp+T0], 0
    jle .order
    mov cx, bx                     ; dx > 0: left to right
    jmp .have
.order:
    mov cx, 79
    sub cx, bx                     ; dx <= 0: right to left
.have:
    push ax
    mov si, cx
    add si, [bp+T0]
    cmp ax, 0
    jl .blank
    cmp ax, [bp+T3]
    jge .blank
    cmp si, 0
    jl .blank
    cmp si, 80
    jge .blank
    imul ax, ax, 80
    add ax, [bp+DV_UPPER]
    add si, ax
    mov al, [si]
    jmp .store
.blank:
    mov al, [bp+T6]
.store:
    push di
    add di, cx
    mov [es:di], al
    pop di
    pop ax
    inc bx
    jmp .col
.ret:
    ret
