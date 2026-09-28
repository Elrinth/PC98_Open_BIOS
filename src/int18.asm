; INT 18h - keyboard and CRT BIOS (text services). Graphics functions
; (40h-4Dh) are in int18_gfx.asm. Function semantics follow the PC-98
; technical references; register conventions and corner cases were checked
; against NP2kai bios18.c (BSD-3-Clause, NP2 developer team).
;
; Frame after the entry prologue (BP = SP):
;   [bp+0] DI  [bp+2] SI  [bp+4] BP  [bp+6] SP  [bp+8] BX  [bp+10] DX
;   [bp+12] CX [bp+14] AX [bp+16] ES [bp+18] DS [bp+20] IP [bp+22] CS
;   [bp+24] FLAGS
F_DI    equ 0
F_SI    equ 2
F_BP    equ 4
F_BX    equ 8
F_BL    equ 8
F_BH    equ 9
F_DX    equ 10
F_DL    equ 10
F_DH    equ 11
F_CX    equ 12
F_CL    equ 12
F_CH    equ 13
F_AX    equ 14
F_AL    equ 14
F_AH    equ 15
F_ES    equ 16
F_DS    equ 18
F_FLAGS equ 24

int18_entry:
    sti
    cld
    push ds
    push es
    pusha
    mov bp, sp
    xor bx, bx
    mov ds, bx
    mov bl, ah
    cmp bl, INT18_COUNT
    jae .gfx
    add bx, bx
    call [cs:int18_table+bx]
.done:
    popa
    pop es
    pop ds
    iret
.gfx:
    call int18_graphics            ; AH >= INT18_COUNT
    jmp .done

int18_table:
    dw k18_read_key         ; 00 read key (wait)
    dw k18_sense_buffer     ; 01 sense key buffer
    dw k18_shift_status     ; 02 shift status
    dw k18_init_keyboard    ; 03 keyboard interface init
    dw k18_key_group        ; 04 key-down state of a group
    dw k18_read_key_nowait  ; 05 read key without waiting
    dw k18_nop              ; 06
    dw k18_nop              ; 07
    dw k18_nop              ; 08
    dw k18_nop              ; 09
    dw c18_set_mode         ; 0A set CRT mode
    dw c18_get_mode         ; 0B sense CRT mode
    dw c18_text_start       ; 0C start text display
    dw c18_text_stop        ; 0D stop text display
    dw c18_single_area      ; 0E single display area
    dw c18_multi_area       ; 0F multiple display areas
    dw c18_cursor_type      ; 10 cursor blink type
    dw c18_cursor_on        ; 11 show cursor
    dw c18_cursor_off       ; 12 hide cursor
    dw c18_cursor_pos       ; 13 cursor position
    dw c18_read_font        ; 14 read font pattern
    dw k18_nop              ; 15 light pen
    dw c18_fill_text        ; 16 initialise text VRAM
    dw c18_beep_on          ; 17 buzzer on
    dw c18_beep_off         ; 18 buzzer off
    dw k18_nop              ; 19 light pen init
    dw c18_user_char        ; 1A define user character
    dw c18_kcg_mode         ; 1B KCG access mode
INT18_COUNT equ ($-int18_table)/2

k18_nop:
    ret

; ---------------------------------------------------------------- keyboard
; Dequeue one key into AX (returns CF=1 and AX unchanged if empty). DS=0.
kbd_dequeue:
    cli
    cmp byte [KB_COUNT], 0
    je .empty
    dec byte [KB_COUNT]
    mov bx, [KB_BUF_HEAD]
    mov ax, [bx]
    add bx, 2
    cmp bx, KB_BUF_END
    jb .head
    mov bx, KB_BUF
.head:
    mov [KB_BUF_HEAD], bx
    sti
    clc
    ret
.empty:
    sti
    stc
    ret

k18_read_key:
.wait:
    call kbd_dequeue
    jnc .got
    hlt                            ; interrupts are enabled: wait for IRQ1
    jmp .wait
.got:
    mov [bp+F_AX], ax
    ret

k18_sense_buffer:
    cli
    mov byte [bp+F_BH], 0
    cmp byte [KB_COUNT], 0
    je .none
    mov bx, [KB_BUF_HEAD]
    mov ax, [bx]
    mov [bp+F_AX], ax
    mov byte [bp+F_BH], 1
.none:
    sti
    ret

k18_shift_status:
    mov al, [SHIFT_STS]
    mov [bp+F_AL], al
    ret

k18_init_keyboard:
    call kbd_init
    ret

k18_key_group:
    mov bl, [bp+F_AL]
    and bx, 0Fh
    mov al, [KB_KY_STS+bx]
    mov [bp+F_AH], al
    ret

k18_read_key_nowait:
    mov byte [bp+F_BH], 0
    call kbd_dequeue
    jc .none
    mov [bp+F_AX], ax
    mov byte [bp+F_BH], 1
.none:
    ret

; Reset the 8251 and the keyboard work area. DS=0. Also called by POST.
kbd_init:
    push ax
    push cx
    push di
    push es
    mov al, 3Ah                    ; keyboard reset high
    out KB_CMD, al
    out CPU_RESET_WAIT, al
    mov al, 32h                    ; keyboard reset low
    out KB_CMD, al
    out CPU_RESET_WAIT, al
    mov al, 16h                    ; error reset, RX enable
    out KB_CMD, al
    push ds
    pop es
    xor ax, ax
    mov di, KB_BUF
    mov cx, 10h
    rep stosw
    mov di, KB_COUNT
    mov cx, 13h
    rep stosb
    mov word [KB_SHIFT_TBL], 0E00h
    mov word [KB_BUF_HEAD], KB_BUF
    mov word [KB_BUF_TAIL], KB_BUF
    mov word [KB_CODE_OFF], 0E00h
    mov word [KB_CODE_SEG], SEG_FD80
    pop es
    pop di
    pop cx
    pop ax
    ret

; ---------------------------------------------------------------- CRT
; CRTC timing for 400-line (24 kHz) text: raster, PL, BL, CL.
crt_400_20: db 13h, 1Eh, 11h, 10h
crt_400_25: db 0Fh, 00h, 0Fh, 10h

c18_set_mode:
    mov al, [bp+F_AL]
; AL = mode (bit 0: 20 lines, bit 1: 40 columns, bit 2: simple graphics
; attribute, bit 3: KCG dot access). DS=0. Also used by POST.
crt_set_mode:
    push ax
    push bx
    push si
    or al, 80h                     ; this machine always runs 400-line text
    mov [CRT_STS_FLAG], al
    mov bl, al
    mov al, 06h                    ; 7x13 (400-line) character font
    or al, 1
    out MODE_FF1, al
    mov al, bl
    shr al, 1
    and al, 1
    or al, 04h                     ; 40/80 columns
    out MODE_FF1, al
    mov al, bl
    shr al, 2
    and al, 1                      ; 00h/01h: vertical line / simple graphics
    out MODE_FF1, al
    mov al, bl
    shr al, 3
    and al, 1
    or al, 0Ah                     ; KCG code / dot access
    out MODE_FF1, al
    mov si, crt_400_25
    test bl, 1
    jz .rows
    mov si, crt_400_20
.rows:
    mov al, [cs:si]
    mov [CRT_RASTER], al
    mov al, [cs:si+1]
    out CRTC_PL, al
    mov al, [cs:si+2]
    out CRTC_BL, al
    mov al, [cs:si+3]
    out CRTC_CL, al
    xor al, al
    out CRTC_SSL, al
    xor al, al
    call crt_cursor_form
    pop si
    pop bx
    pop ax
    ret

; Program the cursor form. AL = 0 blinking, 1 steady. DS=0.
; CSRFORM parameters for 400-line text: lines per row, blink/top, bottom.
csrform_table: db 0Fh, 7Bh, 13h, 9Bh     ; 25-line, 20-line
crt_cursor_form:
    push ax
    push bx
    and al, 1
    shl al, 5
    mov [CRT_CNT], al
    mov bh, al
    and byte [CRT_STS_FLAG], 0BFh
    mov bl, [CRT_STS_FLAG]
    and bx, 0FF01h
    add bl, bl
    mov al, GDC_CSRFORM
    call tgdc_cmd
    mov al, [cs:csrform_table+bx]
    call tgdc_param
    mov al, bh
    call tgdc_param
    mov al, [cs:csrform_table+bx+1]
    call tgdc_param
    pop bx
    pop ax
    ret

c18_get_mode:
    mov al, [CRT_STS_FLAG]
    mov [bp+F_AL], al
    ret

c18_text_start:
    mov al, GDC_START
    jmp tgdc_cmd

c18_text_stop:
    mov al, GDC_STOP
    jmp tgdc_cmd

; DX = text VRAM start address (bytes).
c18_single_area:
    mov ax, [bp+F_DX]
    shr ax, 1
    mov [CRT_W_VRAMADR], ax
    mov bx, 400 << 4
    mov [CRT_W_RASTER], bx
    mov cx, ax
    mov al, GDC_SCROLL
    call tgdc_cmd
    mov al, cl
    call tgdc_param
    mov al, ch
    call tgdc_param
    mov al, bl
    call tgdc_param
    mov al, bh
    call tgdc_param
    ret

; BX:CX -> table of (VRAM address, row count) words, DH = first area,
; DL = count.
c18_multi_area:
    mov ax, [bp+F_CX]
    mov [CRT_MULTI_OFF], ax
    mov ax, [bp+F_BX]
    mov [CRT_MULTI_SEG], ax
    mov al, [bp+F_DH]
    mov [CRT_MULTI_NUM], al
    mov al, [bp+F_DL]
    mov [CRT_CNT], al
    ; rasters per text row: 25-line 16, 20-line 20 (400-line text)
    mov si, 16 << 4
    test byte [CRT_STS_FLAG], 1
    jz .raster
    mov si, 20 << 4
.raster:
    mov cl, [bp+F_DH]
    and cl, 3
    mov al, cl
    shl al, 2
    or al, GDC_SCROLL
    call tgdc_cmd
    mov es, [bp+F_BX]
    mov di, [bp+F_CX]
    movzx bx, byte [bp+F_DL]
.area:
    test bx, bx
    jz .done
    cmp cl, 4
    jae .done
    mov ax, [es:di]
    shr ax, 1
    call tgdc_param
    mov al, ah
    call tgdc_param
    mov ax, [es:di+2]
    mul si
    call tgdc_param
    mov al, ah
    call tgdc_param
    add di, 4
    inc cl
    dec bx
    jmp .area
.done:
    ret

c18_cursor_type:
    mov al, [bp+F_AL]
    jmp crt_cursor_form

c18_cursor_on:
    mov al, GDC_CSRFORM
    call tgdc_cmd
    mov al, [CRT_RASTER]
    or al, 80h
    jmp tgdc_param

c18_cursor_off:
    mov al, GDC_CSRFORM
    call tgdc_cmd
    mov al, [CRT_RASTER]
    jmp tgdc_param

; DX = VRAM byte address of the cursor.
c18_cursor_pos:
    mov al, GDC_CSRW
    call tgdc_cmd
    mov ax, [bp+F_DX]
    shr ax, 1
    call tgdc_param
    mov al, ah
    call tgdc_param
    xor al, al
    jmp tgdc_param

; DX = character code, BX:CX = buffer. Returns size word + pattern.
c18_read_font:
    mov es, [bp+F_BX]
    mov di, [bp+F_CX]
    mov dx, [bp+F_DX]
    cmp dh, 0
    je .ank8
    cmp dh, 80h
    je .ank16
    cmp dh, 29h
    jb .kanji
    cmp dh, 2Bh
    jbe .half
.kanji:
    mov word [es:di], 0202h
    add di, 2
    call cg_select_jis
    xor cx, cx
.kline:
    mov al, cl
    or al, 20h                     ; left half
    out CG_LINE, al
    in al, CG_DATA
    stosb
    mov al, cl
    out CG_LINE, al                ; right half
    in al, CG_DATA
    stosb
    inc cx
    cmp cx, 16
    jb .kline
    ret
.half:
    mov word [es:di], 0102h
    add di, 2
    call cg_select_jis
    jmp .sixteen
.ank16:
    mov word [es:di], 0102h
    add di, 2
    xor al, al
    out CG_CODE_HI, al
    mov al, dl
    out CG_CODE_LO, al
.sixteen:
    xor cx, cx
.aline:
    mov al, cl
    or al, 20h
    out CG_LINE, al
    in al, CG_DATA
    stosb
    inc cx
    cmp cx, 16
    jb .aline
    ret
.ank8:
    ; 8x8 graphic characters are not reachable through the CG window;
    ; they come from the BIOS copy (tables.asm).
    mov word [es:di], 0101h
    add di, 2
    push ds
    push cs
    pop ds
    movzx si, dl
    shl si, 3
    add si, font8x8
    mov cx, 8
    rep movsb
    pop ds
    ret

; Point the CG window at JIS code DX (DH = first byte, DL = second byte).
cg_select_jis:
    mov al, dl
    out CG_CODE_HI, al
    mov al, dh
    sub al, 20h
    out CG_CODE_LO, al
    ret

; DL = character, DH = attribute. Clears codes and attributes, leaving the
; memory switches at A3FE0h-A3FFFh untouched.
c18_fill_text:
    mov dx, [bp+F_DX]
text_fill:
    push es
    push ax
    push cx
    push di
    mov ax, 0A000h
    mov es, ax
    xor di, di
    mov al, dl
    xor ah, ah
    mov cx, 1000h
    rep stosw
    mov al, dh
    mov cx, (3FE0h-2000h)/2
.attr:
    stosb
    inc di
    loop .attr
    pop di
    pop cx
    pop ax
    pop es
    ret

c18_beep_on:
    mov al, 06h
    out SYS_CTRL, al
    ret

c18_beep_off:
    mov al, 07h
    out SYS_CTRL, al
    ret

; DX = code (76xxh/77xxh user area), BX:CX -> size word + 32 bytes.
c18_user_char:
    mov dx, [bp+F_DX]
    mov al, dh
    and al, 7Eh
    cmp al, 76h
    jne .done
    mov es, [bp+F_BX]
    mov si, [bp+F_CX]
    add si, 2
    call cg_select_jis
    xor cx, cx
.line:
    mov al, cl
    or al, 20h
    out CG_LINE, al
    mov al, [es:si]
    out CG_DATA, al
    mov al, cl
    out CG_LINE, al
    mov al, [es:si+1]
    out CG_DATA, al
    add si, 2
    inc cx
    cmp cx, 16
    jb .line
.done:
    ret

c18_kcg_mode:
    mov al, [bp+F_AL]
    cmp al, 1
    ja .done
    and byte [CRT_STS_FLAG], 0F7h
    test al, al
    jz .set
    or byte [CRT_STS_FLAG], 08h
.set:
    or al, 0Ah
    out MODE_FF1, al
.done:
    ret
