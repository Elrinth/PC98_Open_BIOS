; INT 18h figure drawing (45h, 47h, 48h, 49h) and PC-9821 extensions
; (30h, 31h, 4Dh). The graphics uPD7220 does the drawing: the BIOS sends
; CSRW, VECTW, TEXTW, a WDAT mode command and VECTE/TEXTE per plane, as
; NEC's BIOS does. Vector parameters follow NP2kai bios18.c and gdc_sub.c
; (BSD-3-Clause, NP2 developer team). Locals (G_*) are in int18_gfx.asm.

; Wait until the graphics GDC has finished drawing and emptied its FIFO.
ggdc_idle:
    push ax
    push cx
    push dx
    mov dx, 20
.outer:
    mov cx, 0FFFFh
.wait:
    in al, GDC_G_STAT
    and al, GDC_FIFO_EMPTY | GDC_DRAWING
    cmp al, GDC_FIFO_EMPTY
    je .done
    loop .wait
    dec dx
    jnz .outer
.done:
    pop dx
    pop cx
    pop ax
    ret

; AL = AL with its bit order reversed (the GDC shifts patterns LSB first).
bit_reverse:
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

; Draw the figure described by the locals on one plane. EAX = plane base
; word address (4000h blue, 8000h red, C000h green), DL = write mode
; (0 replace, 1 complement, 2 clear, 3 set).
gdc_figure:
    pushad
    call ggdc_idle
    add eax, [bp+G_ADDR]
    mov ebx, eax
    mov al, GDC_CSRW
    call ggdc_cmd
    mov al, bl
    call ggdc_param
    mov al, bh
    call ggdc_param
    shr ebx, 16
    and bl, 03h
    mov al, [bp+G_DOT]
    shl al, 4
    or al, bl
    call ggdc_param
    mov al, GDC_VECTW
    call ggdc_cmd
    lea si, [bp+G_VECT]
    mov cx, 11
.vect:
    mov al, [ss:si]
    call ggdc_param
    inc si
    loop .vect
    mov al, GDC_TEXTW
    call ggdc_cmd
    lea si, [bp+G_PAT]
    mov cx, 2
    cmp byte [bp+G_CHAR], 0
    je .pattern
    lea si, [bp+G_TPAT]
    mov cx, 8
.pattern:
    mov al, [ss:si]
    call ggdc_param
    inc si
    loop .pattern
    mov al, dl
    and al, 03h
    or al, GDC_WRITE
    call ggdc_cmd
    mov al, GDC_VECTE
    cmp byte [bp+G_CHAR], 0
    je .start
    mov al, GDC_TEXTE
.start:
    call ggdc_cmd
    popad
    ret

; Draw on the planes selected by the caller's CH bits 5-4: 00 blue,
; 01 red, 10 green, 11 all three, each set or cleared by the GBON_PTN
; colour bits. ES:BX -> UCW. Records the last write mode in PRXDUPD.
gdc_draw_planes:
    push eax
    push cx
    push dx
    mov ah, [bp+F_CH]
    and ah, 30h
    cmp ah, 30h
    je .all
    movzx eax, ah
    shl eax, 10
    add eax, 4000h
    mov dl, [es:bx+UCW_DOTU]
    and dl, 03h
    call gdc_figure
    jmp .done
.all:
    mov eax, 4000h
    mov cl, 1
.plane:
    mov dl, 2                      ; clear
    test [es:bx+UCW_ON_PTN], cl
    jz .mode
    mov dl, 3                      ; set
.mode:
    call gdc_figure
    add eax, 4000h
    shl cl, 1
    cmp cl, 8
    jb .plane
.done:
    and byte [PRXDUPD], 0FCh
    or [PRXDUPD], dl
    pop dx
    pop cx
    pop eax
    ret

; ES:BX -> caller's UCW; clear the character flag. Returns CX = SY1
; adjusted for the upper 200-line half, AX = SX1.
gdc_ucw_xy:
    mov es, [bp+F_DS]
    mov bx, [bp+F_BX]
    mov byte [bp+G_CHAR], 0
    mov ax, [es:bx+UCW_SX1]
    mov cx, [es:bx+UCW_SY1]
gdc_adjust_y:
    push dx
    mov dl, [bp+F_CH]
    and dl, 0C0h
    cmp dl, 40h
    jne .done
    add cx, 200
.done:
    pop dx
    ret

; AX = x, CX = y -> G_ADDR = y * 40 + x / 16, G_DOT = x & 15.
gdc_set_xy:
    push eax
    push edx
    movzx edx, cx
    imul edx, edx, 40
    push ax
    shr ax, 4
    movzx eax, ax
    add edx, eax
    mov [bp+G_ADDR], edx
    pop ax
    and al, 0Fh
    mov [bp+G_DOT], al
    pop edx
    pop eax
    ret

; Line vector from (SI, DI) to (DX, [G_Y2]) into G_VECT.
gdc_line_vector:
    push ax
    push bx
    push cx
    mov bx, [bp+G_Y2]
    sub bx, di                     ; dy = y2 - y1
    jns .dy
    neg bx
.dy:
    xor al, al                     ; direction
    mov cx, dx
    sub cx, si                     ; dx = x2 - x1
    jnz .slope
    mov al, 7
    cmp di, [bp+G_Y2]
    jle .swapcheck
    mov al, 3
    jmp .swapcheck
.slope:
    jl .left
    cmp di, [bp+G_Y2]
    jl .octant
    add al, 2
    jmp .octant
.left:
    neg cx
    add al, 4
    cmp di, [bp+G_Y2]
    jg .octant
    add al, 2
.octant:
    test al, 2
    jz .shallow
    cmp cx, bx
    ja .swapcheck
    inc al
    jmp .swapcheck
.shallow:
    cmp cx, bx
    jb .swapcheck
    inc al
.swapcheck:
    mov ah, al
    inc ah
    test ah, 2
    jnz .noswap
    xchg cx, bx
.noswap:
    add al, 08h
    mov [bp+G_VECT], al
    mov [bp+G_DC], cx
    shl bx, 1
    mov [bp+G_D1], bx
    sub bx, cx
    mov [bp+G_D], bx
    sub bx, cx
    mov [bp+G_D2], bx
    mov word [bp+G_DM], 0
    pop cx
    pop bx
    pop ax
    ret

; 47h/48h: line, rectangle, circle or arc. DS:BX -> UCW, CH = plane/area.
g18_line:
    sub sp, G_LOCALS
    call gdc_ucw_xy
    call gdc_set_xy
    mov al, [es:bx+UCW_DTYP]
    cmp al, 1
    je .line
    cmp al, 2
    jbe .rect
    ; circle / arc
    mov al, [es:bx+UCW_DSP]
    and al, 7
    add al, 20h
    mov [bp+G_VECT], al
    mov ax, [es:bx+UCW_LNG1]
    mov [bp+G_DC], ax
    mov ax, [es:bx+UCW_CIR]
    dec ax
    mov [bp+G_D], ax
    shr ax, 1
    mov [bp+G_D2], ax
    mov word [bp+G_D1], 3FFFh
    xor ax, ax
    cmp byte [es:bx+UCW_DTYP], 4
    jne .dm
    mov ax, [es:bx+UCW_MDOT]
.dm:
    mov [bp+G_DM], ax
    jmp .pattern
.line:
    mov si, [es:bx+UCW_SX1]
    mov di, [es:bx+UCW_SY1]
    mov dx, [es:bx+UCW_SX2]
    mov cx, [es:bx+UCW_SY2]
    mov [bp+G_Y2], cx
    call gdc_line_vector
    jmp .pattern
.rect:
    mov al, [es:bx+UCW_DSP]
    and al, 7
    add al, 40h
    mov [bp+G_VECT], al
    mov cx, [es:bx+UCW_SX2]
    sub cx, [es:bx+UCW_SX1]
    jns .rdx
    neg cx
.rdx:
    mov dx, [es:bx+UCW_SY2]
    sub dx, [es:bx+UCW_SY1]
    jns .rdy
    neg dx
.rdy:                              ; CX = |dx|, DX = |dy|
    mov al, [es:bx+UCW_DSP]
    and al, 3
    jz .r0
    cmp al, 2
    je .r2
    mov si, cx
    add si, dx
    shr si, 1                      ; data2 = (dx + dy) / 2
    mov di, cx
    sub di, dx
    cmp al, 1
    je .rdiag
    neg di                         ; dy - dx
.rdiag:
    shr di, 1
    and di, 3FFFh
    jmp .rset
.r0:
    mov di, dx
    mov si, cx
    jmp .rset
.r2:
    mov di, cx
    mov si, dx
.rset:                             ; DI = data, SI = data2
    mov word [bp+G_DC], 3
    mov [bp+G_D], di
    mov [bp+G_D2], si
    mov word [bp+G_D1], 0FFFFh
    mov [bp+G_DM], di
.pattern:
    mov ax, [es:bx+UCW_MDOTI]
    mov [PRXGLS], ax
    mov al, [es:bx+UCW_MDOTI]
    call bit_reverse
    mov [bp+G_PAT+1], al           ; pattern = rev(b0) << 8 | rev(b1)
    mov al, [es:bx+UCW_MDOTI+1]
    call bit_reverse
    mov [bp+G_PAT], al
    call gdc_draw_planes
    add sp, G_LOCALS
    ret

; 49h: graphic character (8x8 pattern in GBMDOTI).
g18_gchar:
    sub sp, G_LOCALS
    call gdc_ucw_xy
    call gdc_set_xy
    mov byte [bp+G_CHAR], 1
    xor si, si
.pat:
    mov al, [es:bx+UCW_MDOTI+si]
    mov [PRXGLS+si], al
    call bit_reverse
    mov [bp+G_TPAT+si], al
    inc si
    cmp si, 8
    jb .pat
    mov al, [es:bx+UCW_DSP]
    and al, 7
    add al, 10h
    mov [bp+G_VECT], al
    mov ax, [es:bx+UCW_LNG1]
    test ax, ax
    jz .default
    mov [bp+G_D], ax
    mov ax, [es:bx+UCW_LNG2]
    dec ax
    and ax, 3FFFh
    mov [bp+G_DC], ax
    jmp .rest
.default:
    mov word [bp+G_DC], 7
    mov word [bp+G_D], 7
.rest:
    xor ax, ax
    mov [bp+G_D2], ax
    mov [bp+G_D1], ax
    mov [bp+G_DM], ax
    call gdc_draw_planes
    add sp, G_LOCALS
    ret

; 45h: draw GBLNG1 dots of the bit pattern at DS:GBWDPA, one byte (up to
; eight dots) per horizontal GDC line.
g18_pattern:
    sub sp, G_LOCALS
    call gdc_ucw_xy
    mov dx, ax                     ; DX = x of the current byte
    xor si, si                     ; byte index
.byte:
    mov ax, si
    shl ax, 3
    cmp ax, [es:bx+UCW_LNG1]
    jae .done
    mov di, [es:bx+UCW_LNG1]
    sub di, ax                     ; dots left
    cmp di, 8
    jbe .len
    mov di, 8
.len:
    push si
    add si, [es:bx+UCW_WDPA]
    mov al, [es:si]
    pop si
    mov cx, 8
    sub cx, di
    mov ah, 0FFh
    shl ah, cl                     ; keep the first DI dots
    and al, ah
    call bit_reverse
    mov [bp+G_PAT], al
    mov byte [bp+G_PAT+1], 0
    mov byte [bp+G_VECT], 0Ah      ; line, direction 2
    lea ax, [di-1]
    mov [bp+G_DC], ax
    mov word [bp+G_D1], 0
    neg ax
    mov [bp+G_D], ax
    add ax, ax
    mov [bp+G_D2], ax
    mov word [bp+G_DM], 0
    mov ax, dx
    mov cx, [es:bx+UCW_SY1]
    call gdc_adjust_y
    call gdc_set_xy
    call gdc_draw_planes
    add dx, 8
    inc si
    jmp .byte
.done:
    add sp, G_LOCALS
    ret

; ---------------------------------------------------------------- PC-9821
; 30h: set 24/31 kHz mode. AL = rate (08h 24 kHz, 0Ch 31 kHz), BH = screen:
; bits 5-4 graphics (00 640x200 lower/200-line, 01 upper, 10 640x400,
; 11 640x480), bits 1-0 text lines (0 20, 1 25, 2 30; 30 only with 480).
; Returns AH = 05h, AL = BH = 00h on success, else AH = 00h, AL = BH = 01h.
; Needs CRT_BIOS bit 7 (set by POST when the core decodes port 09A8h).
; Semantics and timing tables follow NP2kai bios18.c (BSD-3-Clause).
PORT_31K        equ 09A8h

; text GDC SYNC: 15 kHz, 24 kHz, 31 kHz 400, 31 kHz 480 (20/25/30 lines)
gdc_sync_master:
    db 10h,4Eh,07h,25h,0Dh,0Fh,0C8h,94h
    db 10h,4Eh,07h,25h,07h,07h,90h,65h
    db 10h,4Eh,47h,0Ch,07h,0Dh,90h,89h
    db 10h,4Eh,4Bh,0Ch,03h,06h,0E0h,95h
    db 10h,4Eh,4Bh,0Ch,03h,0Bh,0DBh,95h
    db 10h,4Eh,4Bh,0Ch,03h,06h,0E0h,95h
; graphics GDC SYNC: 15-L, 31-H(480), 24-L, 24-M, 31-L, 31-M
gdc_sync_slave:
    db 02h,26h,03h,11h,86h,0Fh,0C8h,94h
    db 02h,4Eh,4Bh,0Ch,83h,06h,0E0h,95h
    db 02h,26h,03h,11h,83h,07h,90h,65h
    db 02h,4Eh,07h,25h,87h,07h,90h,65h
    db 02h,26h,41h,0Ch,83h,0Dh,90h,89h
    db 02h,4Eh,47h,0Ch,87h,0Dh,90h,89h
; raster-1, PL, BL, CL per screen: 200-20/25, 400-20/25, 480-20/25/30
crt_modes:
    db 09h,1Fh,08h,08h, 07h,00h,07h,08h
    db 13h,1Eh,11h,10h, 0Fh,00h,0Fh,10h
    db 17h,1Ch,13h,10h, 12h,1Fh,11h,10h, 0Fh,00h,0Fh,10h

g18_set_31k:
    test byte [CRT_BIOS], 80h
    jz .fail
    mov al, [bp+F_AL]              ; rate
    mov ah, [bp+F_BH]              ; screen
    mov bl, al
    and bl, 0F8h
    cmp bl, 08h
    jne .fail
    test ah, 0CCh
    jnz .fail
    mov bl, ah
    and bl, 3
    cmp bl, 3
    je .fail
    mov bl, ah
    and bl, 30h
    cmp bl, 30h
    jne .not480
    ; 640x480: 31 kHz, 256-colour extension
    test al, 0Ch
    jz .fail
    call pegc_extend_on
    mov si, 4                      ; CRT row base
    movzx di, ah
    and di, 3
    add di, 3                      ; master SYNC 3 + lines
    mov cx, 1                      ; slave SYNC
    jmp .program
.not480:
    mov bl, ah
    and bl, 3
    cmp bl, 2
    jae .fail                      ; 30 lines need 480
    mov bl, [CRT_BIOS]
    and bl, 3
    cmp bl, 3
    jne .was_not_480
    call pegc_extend_off           ; leaving 640x480
.was_not_480:
    test al, 04h
    jz .rate24
    mov si, 2
    mov di, 2
    mov cx, 4
    jmp .slave_mode
.rate24:
    xor si, si
    xor di, di
    xor cx, cx
    test byte [PRXCRT], 40h
    jz .slave_mode
    mov si, 2
    mov di, 1
    mov cx, 2
.slave_mode:
    test ah, 20h
    jz .ext_off
    test byte [PRXDUPD], 04h
    jz .ext_off
    inc cx
    jmp .program
.ext_off:
    call pegc_extend_off
.program:
    ; SI = CRT row base, DI = master SYNC index, CX = slave SYNC index
    mov bl, ah
    and bl, 3
    xor bh, bh
    add si, bx                     ; CRT row
    ; 31 kHz select
    push ax
    mov dx, PORT_31K
    shr al, 2
    and al, 1
    out dx, al
    ; text GDC: SYNC, scroll, pitch, cursor form
    mov al, GDC_SYNC_OFF
    call tgdc_cmd
    push si
    mov si, di
    shl si, 3
    add si, gdc_sync_master
    push cx
    mov cx, 8
    mov dx, GDC_T_STAT
    call gdc_params
    pop cx
    pop si
    mov al, GDC_SCROLL
    call tgdc_cmd
    xor al, al
    call tgdc_param
    call tgdc_param
    call tgdc_param
    call tgdc_param
    mov al, GDC_PITCH
    call tgdc_cmd
    mov al, 80
    call tgdc_param
    shl si, 2
    mov al, [cs:crt_modes+si]      ; raster
    mov [CRT_RASTER], al
    mov bl, al
    mov al, GDC_CSRFORM
    call tgdc_cmd
    mov al, bl
    call tgdc_param
    xor al, al
    call tgdc_param
    mov al, bl
    shl al, 3
    add al, 3
    call tgdc_param
    mov al, [cs:crt_modes+si+1]
    out CRTC_PL, al
    mov al, [cs:crt_modes+si+2]
    out CRTC_BL, al
    mov al, [cs:crt_modes+si+3]
    out CRTC_CL, al
    xor al, al
    out CRTC_SSL, al
    mov al, 1
    out CRTC_SUR, al
    xor al, al
    out CRTC_SDR, al
    ; graphics GDC
    mov al, GDC_SYNC_OFF
    call ggdc_cmd
    mov si, cx
    shl si, 3
    add si, gdc_sync_slave
    push cx
    mov cx, 8
    mov dx, GDC_G_STAT
    call gdc_params
    pop cx
    pop ax
    mov al, GDC_SCROLL
    call ggdc_cmd
    xor bx, bx                     ; SAD
    mov bh, ah
    and bh, 30h
    cmp bh, 10h
    mov bx, 0
    jne .sad
    mov bx, 200*40                 ; upper 200-line half
.sad:
    mov al, bl
    call ggdc_param
    mov al, bh
    call ggdc_param
    xor al, al
    call ggdc_param
    mov al, 0
    test cl, 1
    jz .len
    mov al, 40h
.len:
    call ggdc_param
    mov al, GDC_PITCH
    call ggdc_cmd
    test cl, 1
    jz .pitch40
    mov al, 80
    call ggdc_param
    or byte [PRXDUPD], 04h
    mov al, 83h                    ; graphics GDC clock 5 MHz
    out MODE_FF2, al
    mov al, 85h
    out MODE_FF2, al
    jmp .lines
.pitch40:
    mov al, 40
    call ggdc_param
    and byte [PRXDUPD], 0FBh
    mov al, 82h                    ; graphics GDC clock 2.5 MHz
    out MODE_FF2, al
    mov al, 84h
    out MODE_FF2, al
.lines:
    ; 200-line doubling off for 400/480-line graphics or 24 kHz-less machines
    test ah, 20h
    jnz .noline200
    test byte [PRXCRT], 40h
    jz .noline200
    mov al, 09h
    out MODE_FF1, al
    mov bl, 1
    jmp .csrform
.noline200:
    mov al, 08h
    out MODE_FF1, al
    xor bl, bl
.csrform:
    mov al, GDC_CSRFORM
    call ggdc_cmd
    mov al, bl
    call ggdc_param
    mov al, GDC_STOP               ; text display off until AH=0Ch
    call tgdc_cmd
    ; work area
    mov al, ah
    shr al, 4
    and al, 3
    and byte [CRT_BIOS], 0FCh
    or [CRT_BIOS], al
    and byte [CRT_STS_FLAG], 0EEh
    test ah, 1
    jnz .rows25
    or byte [CRT_STS_FLAG], 01h    ; 20 lines
.rows25:
    test ah, 2
    jz .done
    or byte [CRT_STS_FLAG], 10h    ; 30 lines
.done:
    mov byte [bp+F_AH], 05h
    mov byte [bp+F_AL], 0
    mov byte [bp+F_BH], 0
    ret
.fail:
    mov byte [bp+F_AH], 0
    mov byte [bp+F_AL], 1
    mov byte [bp+F_BH], 1
    ret

; 256-colour (PEGC) extension on/off through mode flip-flop 2.
pegc_extend_on:
    push ax
    mov al, 07h                    ; unlock
    out MODE_FF2, al
    mov al, 21h                    ; 256 colours
    out MODE_FF2, al
    mov al, 69h                    ; single 512 KiB page (640x480 fits)
    out MODE_FF2, al
    mov al, 06h
    out MODE_FF2, al
    or byte [PRXDUPD], 80h
    pop ax
    ret
pegc_extend_off:
    push ax
    test byte [PRXDUPD], 80h
    jz .done
    mov al, 07h
    out MODE_FF2, al
    mov al, 68h                    ; two 256 KiB pages
    out MODE_FF2, al
    mov al, 20h
    out MODE_FF2, al
    mov al, 06h
    out MODE_FF2, al
    and byte [PRXDUPD], 7Fh
.done:
    pop ax
    ret

; 31h: sense. AL = 08h | 04h (31 kHz), BH = screen as for 30h.
g18_get_31k:
    test byte [CRT_BIOS], 80h
    jz .done
    mov dx, PORT_31K
    in al, dx
    and al, 1
    shl al, 2
    or al, 08h
    mov [bp+F_AL], al
    mov al, [CRT_BIOS]
    and al, 3
    shl al, 4
    test byte [CRT_STS_FLAG], 01h
    jnz .rows
    or al, 01h                     ; not 20 lines -> 25
.rows:
    test byte [CRT_STS_FLAG], 10h
    jz .set
    or al, 02h
    and al, 0FEh
.set:
    mov [bp+F_BH], al
.done:
    ret

; 4Dh: CH = 0 standard 16 colours, 1 = 256-colour (PEGC) mode.
g18_ext:
    mov al, 07h                    ; mode change enable
    out MODE_FF2, al
    mov ah, [bp+F_CH]
    cmp ah, 1
    ja .done
    mov al, 20h
    or al, ah
    out MODE_FF2, al
    and byte [PRXDUPD], 7Fh
    test ah, ah
    jz .done
    or byte [PRXDUPD], 80h
.done:
    mov al, 06h
    out MODE_FF2, al
    ret
