; INT 18h graphics functions (AH >= 1Ch). Same frame as int18.asm.
; Figure drawing (45h-49h) programs the graphics uPD7220's drawing engine:
; CSRW, VECTW, TEXTW, a WDAT mode command and VECTE/TEXTE, as NEC's BIOS
; does. Vector parameters follow NP2kai bios18.c / gdc_sub.c (BSD-3-Clause).

; UCW (DS:BX) field offsets
UCW_ON_PTN      equ 0
UCW_DOTU        equ 2
UCW_DSP         equ 3
UCW_CPC         equ 4
UCW_SX1         equ 8
UCW_SY1         equ 10
UCW_LNG1        equ 12
UCW_WDPA        equ 14
UCW_SX2         equ 22
UCW_SY2         equ 24
UCW_MDOT        equ 26
UCW_CIR         equ 28
UCW_LNG2        equ 30
UCW_MDOTI       equ 32
UCW_DTYP        equ 40

; Locals of the drawing functions, below the return address at [bp-2]:
G_VECT          equ -16         ; ope, DC, D, D2, D1, DM (11 bytes)
G_DC            equ G_VECT+1
G_D             equ G_VECT+3
G_D2            equ G_VECT+5
G_D1            equ G_VECT+7
G_DM            equ G_VECT+9
G_ADDR          equ -20         ; dword: word address within a plane
G_PAT           equ -22         ; TEXTW pattern word
G_TPAT          equ -30         ; 8 graphic-character pattern bytes
G_DOT           equ -31
G_CHAR          equ -32         ; 1: TEXTE (graphic character), 0: VECTE
G_Y2            equ -34         ; y2 for gdc_line_vector
G_LOCALS        equ 36

int18_graphics:
    mov al, [bp+F_AH]
    cmp al, 40h
    je g18_start
    cmp al, 41h
    je g18_stop
    cmp al, 42h
    je g18_area
    cmp al, 43h
    je g18_palette
    cmp al, 4Ah
    je g18_draw_mode
    cmp al, 47h
    je g18_line
    cmp al, 48h
    je g18_line
    cmp al, 49h
    je g18_gchar
    cmp al, 45h
    je g18_pattern
    cmp al, 30h
    je g18_set_31k
    cmp al, 31h
    je g18_get_31k
    cmp al, 4Dh
    je g18_ext
    ret

g18_start:
    mov al, GDC_START
    call ggdc_cmd
    or byte [PRXCRT], 80h
    ret

g18_stop:
    mov al, GDC_STOP
    call ggdc_cmd
    and byte [PRXCRT], 7Fh
    ret

; CH bits 7-6: 11 = 640x400, 10 = lower 200 lines, 01 = upper 200 lines;
; bit 5: 1 = colour; bit 4: display bank.
g18_area:
    ; In a 31 kHz 640x480 screen the request goes through the 30h path
    ; (screen = mode << 4 | 25 lines), as NEC's BIOS does.
    test byte [CRT_BIOS], 80h
    jz .legacy
    mov al, [CRT_BIOS]
    and al, 3
    cmp al, 3
    jne .legacy
    mov al, [bp+F_CH]
    shr al, 6
    movzx bx, al
    mov al, [cs:.modenum+bx]
    shl al, 4
    or al, 1
    push word [bp+F_AX]
    push word [bp+F_BX]
    mov [bp+F_BH], al
    mov byte [bp+F_AL], 0Ch
    call g18_set_31k
    pop word [bp+F_BX]
    pop word [bp+F_AX]
    ret
.modenum: db 3, 1, 0, 2
.legacy:
    mov ch, [bp+F_CH]
    mov al, GDC_SCROLL
    call ggdc_cmd
    xor ax, ax                     ; start address
    mov bl, ch
    and bl, 0C0h
    cmp bl, 40h
    jne .sad
    mov ax, 200*40                 ; upper half displayed: start at line 200
.sad:
    call ggdc_param
    mov al, ah
    call ggdc_param
    xor al, al
    call ggdc_param
    mov al, 40h                    ; length field (all lines)
    call ggdc_param
    ; Raster lines per row: 1 for 640x400, 2 for the 200-line modes (each
    ; row shown twice). Without it a 200-line picture was squeezed into the
    ; upper half of a 400-line screen (Flame Zapper Kotsujin).
    mov al, GDC_CSRFORM
    call ggdc_cmd
    mov al, 01h
    cmp bl, 0C0h
    jne .rows
    xor al, al
.rows:
    call ggdc_param
    xor al, al
    call ggdc_param
    call ggdc_param
    ; 200-line modes hide every other raster line (mode flip-flop bit 4)
    mov al, 08h
    cmp bl, 0C0h
    je .lines
    or al, 1
.lines:
    out MODE_FF1, al
    mov al, ch
    shr al, 5
    and al, 1
    or al, 02h                     ; colour / monochrome
    out MODE_FF1, al
    mov al, ch
    shr al, 4
    and al, 1
    out GR_DISP_PAGE, al
    ret

; DS:BX -> UCW; GBCPC (4 bytes at +4) holds colours 7..0 as nibbles.
g18_palette:
    mov es, [bp+F_DS]
    mov si, [bp+F_BX]
    mov bx, [es:si+4]              ; BL = c0 (colours 6/7), BH = c1 (4/5)
    mov dx, [es:si+6]              ; DL = c2 (colours 2/3), DH = c3 (0/1)
    ; port AEh: colour 0 (high) / 4 (low)
    mov al, dh
    and al, 0F0h
    mov ah, bh
    shr ah, 4
    or al, ah
    out PAL_AE, al
    ; port AAh: colour 1 / 5
    mov al, dh
    shl al, 4
    mov ah, bh
    and ah, 0Fh
    or al, ah
    out PAL_AA, al
    ; port ACh: colour 2 / 6
    mov al, dl
    and al, 0F0h
    mov ah, bl
    shr ah, 4
    or al, ah
    out PAL_AC, al
    ; port A8h: colour 3 / 7
    mov al, dl
    shl al, 4
    mov ah, bl
    and ah, 0Fh
    or al, ah
    out PAL_A8, al
    ret

g18_draw_mode:
    test byte [PRXCRT], 01h
    jnz .done
    mov al, GDC_SYNC_OFF
    call ggdc_cmd
    mov al, [bp+F_CH]
    call ggdc_param
.done:
    ret

