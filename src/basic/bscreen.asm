; Text console for PRINT and the screen statements.
; Characters go straight to text VRAM (A000h codes, A200h attributes); the
; console scrolls between B_SCRTOP and B_SCRBOT (CONSOLE). Graphics
; statements use LIO with DS = BSEG, so LIO keeps its state at BSEG:0620h.

TVRAM           equ 0A000h
TATTR           equ 0A200h

; AL = character (control codes CR, LF, BS handled). Shift-JIS lead bytes
; take the next call's byte as the trail byte.
b_putc:
    push ax
    push bx
    push cx
    push di
    push es
    cmp byte [B_SJIS], 0
    jne .trail
    cmp al, 0Dh
    je .cr
    cmp al, 0Ah
    je .lf
    cmp al, 08h
    je .bs
    cmp al, 81h
    jb .ank
    cmp al, 9Fh
    jbe .lead
    cmp al, 0E0h
    jb .ank
    cmp al, 0FCh
    ja .ank
.lead:
    mov [B_SJIS], al
    jmp .r
.ank:
    xor ah, ah
    call b_cell
    jmp .r
.trail:
    mov ah, al                      ; Shift-JIS -> JIS -> two text cells
    mov al, [B_SJIS]
    mov byte [B_SJIS], 0
    call b_sjis_jis                 ; AH:AL = JIS row:cell
    sub al, 20h                     ; VRAM: low = row - 20h, high = cell
    push ax
    mov bl, [B_WIDTH]
    dec bl
    cmp [B_CSRX], bl
    jb .fits
    call b_newline
.fits:
    pop ax
    push ax
    call b_cell
    pop ax
    or al, 80h                      ; right half
    call b_cell
    jmp .r
.cr:
    mov byte [B_CSRX], 0
    jmp .r
.lf:
    call b_newline
    jmp .r
.bs:
    cmp byte [B_CSRX], 0
    je .r
    dec byte [B_CSRX]
.r:
    pop es
    pop di
    pop cx
    pop bx
    pop ax
    ret

; Store AX at the cursor with the current attribute and advance.
b_cell:
    push ax
    call b_cursor_addr              ; DI
    mov bx, TVRAM
    mov es, bx
    stosw
    sub di, 2
    mov bx, TATTR
    mov es, bx
    mov al, [B_TATTR]
    xor ah, ah
    stosw
    pop ax
    inc byte [B_CSRX]
    mov al, [B_CSRX]
    cmp al, [B_WIDTH]
    jb .r
    call b_newline
.r:
    ret

; DI = VRAM offset of the cursor.
b_cursor_addr:
    movzx di, byte [B_CSRY]
    imul di, di, 160
    movzx bx, byte [B_CSRX]
    shl bx, 1
    add di, bx
    ret

; Shift-JIS AL (lead), AH (trail) -> AL = JIS row, AH = JIS cell.
b_sjis_jis:
    cmp al, 0E0h
    jb .lo
    sub al, 40h
.lo:
    sub al, 70h
    shl al, 1                       ; 81h-9Fh -> 22h.. pairs
    cmp ah, 9Fh
    jae .second
    dec al
    cmp ah, 7Fh
    jb .t1
    dec ah
.t1:
    sub ah, 1Fh
    ret
.second:
    sub ah, 7Eh
    ret

b_newline:
    mov byte [B_CSRX], 0
    inc byte [B_CSRY]
    mov al, [B_CSRY]
    cmp al, [B_SCRBOT]
    jb .r
    mov al, [B_SCRBOT]
    dec al
    mov [B_CSRY], al
    call b_scroll
.r:
    ret

b_newline_if_needed:
    cmp byte [B_CSRX], 0
    je .r
    call b_newline
.r:
    ret

b_backspace:
    cmp byte [B_CSRX], 0
    je .r
    dec byte [B_CSRX]
    mov al, ' '
    call b_putc
    dec byte [B_CSRX]
.r:
    ret

; Scroll the console lines up by one, clear the last one.
b_scroll:
    push ds
    push es
    push si
    push di
    push cx
    push bx
    movzx ax, byte [B_SCRTOP]
    imul di, ax, 160                ; first console line
    movzx cx, byte [B_SCRBOT]
    sub cx, ax
    dec cx
    imul cx, cx, 80                 ; words to move
    movzx bx, byte [B_TATTR]
    mov dx, 0020h
    mov ax, TVRAM
    call .move
    mov dx, bx
    mov ax, TATTR
    call .move
    pop bx
    pop cx
    pop di
    pop si
    pop es
    pop ds
    ret
.move:                              ; AX = segment, DX = fill word
    push di
    push cx
    mov ds, ax
    mov es, ax
    lea si, [di+160]
    rep movsw
    mov cx, 80
    mov ax, dx
    rep stosw
    pop cx
    pop di
    ret

; Clear the console lines, cursor home.
b_cls_text:
    push es
    movzx ax, byte [B_SCRTOP]
    imul di, ax, 160
    movzx cx, byte [B_SCRBOT]
    sub cx, ax
    imul cx, cx, 80
    push di
    push cx
    mov ax, TVRAM
    mov es, ax
    mov ax, 0020h
    rep stosw
    pop cx
    pop di
    mov ax, TATTR
    mov es, ax
    movzx ax, byte [B_TATTR]
    rep stosw
    pop es
    mov byte [B_CSRX], 0
    mov al, [B_SCRTOP]
    mov [B_CSRY], al
    ret

; Cursor on at the cursor position (BASIC waits for input) / off.
b_cursor_show:
    push ax
    push bx
    push dx
    push di
    call b_cursor_addr
    mov dx, di
    mov ah, 13h
    int 18h
    mov ah, 11h
    int 18h
    pop di
    pop dx
    pop bx
    pop ax
    ret
b_cursor_hide:
    push ax
    push bx
    push dx
    push di
    mov ah, 12h
    int 18h
    pop di
    pop dx
    pop bx
    pop ax
    ret

; CS:SI -> 0-terminated text
b_puts_cs:
    mov al, [cs:si]
    test al, al
    jz .r
    call b_putc
    inc si
    jmp b_puts_cs
.r:
    ret

; ES:BX, CX bytes
b_puts:
    jcxz .r
    push bx
    push cx
.l:
    mov al, [es:bx]
    call b_putc
    inc bx
    loop .l
    pop cx
    pop bx
.r:
    ret

; AX unsigned -> decimal at the cursor
b_print_uint:
    push bx
    push cx
    call b_fmt_uint
    call b_puts
    pop cx
    pop bx
    ret

; AX signed -> " 123" / "-123" in B_NUMBUF: BX = text, CX = length.
b_fmt_int:
    push ax
    test ax, ax
    jns .pos
    neg ax
.pos:
    call b_fmt_uint
    pop ax
    dec bx
    inc cx
    mov byte [bx], ' '
    test ax, ax
    jns .r
    mov byte [bx], '-'
.r:
    ret

; AX unsigned -> digits in B_NUMBUF: BX = text, CX = length.
b_fmt_uint:
    push dx
    push si
    mov bx, B_NUMBUF+15
    xor cx, cx
    mov si, 10
.d:
    xor dx, dx
    div si
    add dl, '0'
    dec bx
    mov [bx], dl
    inc cx
    test ax, ax
    jnz .d
    pop si
    pop dx
    ret

; ---------------------------------------------------------------- statements
; Statement arguments: up to 8 optional integers separated by commas.
; B_ARGS[i] = value, B_ARGN[i] = 1 when given. CX = count read.
b_args:
    push di
    mov di, B_ARGN
    xor ax, ax
    mov cx, 8
    rep stosb
    xor cx, cx
.next:
    call b_at_end
    je .done
    call b_skipsp
    cmp al, ','
    je .empty
    push cx
    call b_eval_int
    pop cx
    mov bx, cx
    mov byte [B_ARGN+bx], 1
    shl bx, 1
    mov [B_ARGS+bx], ax
    call b_skipsp
.empty:
    inc cx
    cmp al, ','
    jne .done
    inc si
    cmp cx, 8
    jb .next
.done:
    pop di
    ret

; B_ARGS[BX] as a byte, FFh when not given -> AL
b_arg_or_ff:
    mov al, 0FFh
    cmp byte [B_ARGN+bx], 0
    je .r
    push bx
    shl bx, 1
    mov al, [B_ARGS+bx]
    pop bx
.r:
    ret

stmt_cls:                           ; CLS [1 text, 2 graphics, 3 both]
    call b_at_end
    mov ax, 1
    je .go
    call b_eval_int
.go:
    test al, 1
    jz .nt
    push ax
    call b_cls_text
    pop ax
.nt:
    test al, 2
    jz stmt_end
    mov ah, 0
    xor bx, bx
    int 0A5h                        ; LIO GCLS
    jmp stmt_end

; LOCATE x, y, cursor
stmt_locate:
    call b_args
    cmp byte [B_ARGN], 0
    je .y
    mov al, [B_ARGS]
    cmp al, [B_WIDTH]
    jae err_func
    mov [B_CSRX], al
.y:
    cmp byte [B_ARGN+1], 0
    je .c
    mov al, [B_ARGS+2]
    cmp al, [B_LINES]
    jae err_func
    mov [B_CSRY], al
.c:
    cmp byte [B_ARGN+2], 0
    je .done
    mov al, [B_ARGS+4]
    mov [B_CURSW], al
.done:
    jmp stmt_end

; COLOR f, bg, border, fg, mode   |   COLOR=(palette, colour)
stmt_color:
    call b_skipsp
    cmp al, T_EQ
    je .palette
    call b_args
    cmp byte [B_ARGN], 0
    je .lio
    mov al, [B_ARGS]
    and al, 7
    shl al, 5
    or al, 1
    mov [B_TATTR], al
.lio:
    mov di, B_LIOPB
    xor bx, bx
.pb:
    call b_arg_or_ff
    mov [di+bx], al
    inc bx
    cmp bx, 5
    jb .pb
    mov byte [di], 0FFh             ; LIO's first byte is unused
    cmp byte [B_ARGN+1], 0
    jne .call
    cmp byte [B_ARGN+2], 0
    jne .call
    cmp byte [B_ARGN+3], 0
    jne .call
    cmp byte [B_ARGN+4], 0
    je stmt_end
.call:
    mov bx, B_LIOPB
    mov ah, 0
    int 0A3h                        ; LIO GCOLOR1
    test ah, ah
    jnz err_func
    jmp stmt_end
.palette:
    inc si
    mov ah, '('
    call b_expect
    call b_args
    mov ah, ')'
    call b_expect
    mov al, [B_ARGS]
    mov [B_LIOPB], al
    mov al, [B_ARGS+2]
    mov [B_LIOPB+1], al
    mov al, [B_ARGS+4]
    mov [B_LIOPB+2], al
    mov bx, B_LIOPB
    mov ah, 0
    int 0A4h                        ; LIO GCOLOR2
    test ah, ah
    jnz err_func
    jmp stmt_end

; SCREEN mode, switch, active page, display page
stmt_screen:
    call b_args
    mov di, B_LIOPB
    xor bx, bx
.pb:
    call b_arg_or_ff
    mov [di+bx], al
    inc bx
    cmp bx, 4
    jb .pb
    mov bx, B_LIOPB
    mov ah, 0
    int 0A1h                        ; LIO GSCREEN
    test ah, ah
    jnz err_func
    jmp stmt_end

; CONSOLE first line, lines, function keys, colour
stmt_console:
    call b_args
    mov al, [B_SCRTOP]
    cmp byte [B_ARGN], 0
    je .a
    mov al, [B_ARGS]
.a:
    mov ah, [B_SCRBOT]
    sub ah, [B_SCRTOP]
    cmp byte [B_ARGN+1], 0
    je .b
    mov ah, [B_ARGS+2]
.b:
    cmp byte [B_ARGN+2], 0
    je .c
    mov bl, [B_ARGS+4]
    mov [B_FKEY], bl
.c:
    mov bl, [B_LINES]
    cmp byte [B_FKEY], 0
    je .full
    dec bl
.full:
    cmp al, bl
    jae err_func
    add ah, al
    cmp ah, bl
    jbe .ok
    mov ah, bl
.ok:
    mov [B_SCRTOP], al
    mov [B_SCRBOT], ah
    mov al, [B_CSRY]
    cmp al, [B_SCRTOP]
    jb .home
    cmp al, [B_SCRBOT]
    jb stmt_end
.home:
    mov al, [B_SCRTOP]
    mov [B_CSRY], al
    mov byte [B_CSRX], 0
    jmp stmt_end

; WIDTH columns, lines
stmt_width:
    call b_args
    mov al, [B_WIDTH]
    cmp byte [B_ARGN], 0
    je .l
    mov al, [B_ARGS]
.l:
    mov ah, [B_LINES]
    cmp byte [B_ARGN+1], 0
    je .set
    mov ah, [B_ARGS+2]
.set:
    xor bl, bl
    cmp al, 80
    je .c
    cmp al, 40
    jne err_func
    or bl, 2
.c:
    cmp ah, 25
    je .r
    cmp ah, 20
    jne err_func
    or bl, 1
.r:
    mov [B_WIDTH], al
    mov [B_LINES], ah
    mov byte [B_SCRTOP], 0
    mov [B_SCRBOT], ah
    push ax
    mov al, bl
    mov ah, 0Ah
    int 18h
    pop ax
    call b_cls_text
    jmp stmt_end
