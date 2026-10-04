; Graphics statements through LIO (DS = BSEG, LIO state at BSEG:0620h):
; LINE, PSET, PRESET, CIRCLE, PAINT, VIEW, POINT, PUT @, COLOR @, and BEEP.
; Coordinates are relative to the VIEW origin (VIEW SCREEN: absolute); LIO
; works in screen coordinates and clips to the view.

; '(' x ',' y ')' -> CX, DX
g_pair:
    mov ah, '('
    call b_expect
    call b_eval_int
    push ax
    mov ah, ','
    call b_expect
    call b_eval_int
    push ax
    mov ah, ')'
    call b_expect
    pop dx
    pop cx
    ret

; [STEP](x,y) -> CX, DX in screen coordinates; the point becomes the last
; point (view coordinates).
g_coord:
    call b_skipsp
    cmp al, T_STEP
    jne .abs
    inc si
    call g_pair
    add cx, [G_LX]
    add dx, [G_LY]
    jmp .set
.abs:
    call g_pair
.set:
    mov [G_LX], cx
    mov [G_LY], dx
    add cx, [G_OX]
    add dx, [G_OY]
    ret

; ZF set when no ',' follows; otherwise steps over it.
g_comma:
    call b_skipsp
    cmp al, ','
    jne .no
    inc si
    test si, si                     ; ZF clear
    ret
.no:
    cmp al, al
    ret

; Optional argument after a ',': AX = value, 0FFh when left out.
g_arg_ff:
    call b_at_end
    je .ff
    cmp al, ','
    je .ff
    jmp b_eval_int
.ff:
    mov ax, 0FFh
    ret

; Text-area end for LIO work buffers (PAINT): DX = start, AX = end.
g_work:
    mov dx, [PRGEND]
    add dx, 1
    and dl, 0FEh
    mov ax, TEXT_LIMIT
    ret

; LIO status AH: 0 = done, 7 = out of memory, else Illegal function call.
g_status:
    test ah, ah
    jz .r
    cmp ah, 7
    je err_memory
    jmp err_func
.r:
    ret

; LINE [[STEP](x1,y1)]-[STEP](x2,y2)[,[colour][,[B|BF][,style|tile$]]]
stmt_line:
    call b_skipsp
    cmp al, T_INPUT
    je err_feature                  ; LINE INPUT
    mov cx, [G_LX]
    mov dx, [G_LY]
    add cx, [G_OX]
    add dx, [G_OY]
    cmp al, T_MINUS
    je .second
    call g_coord
.second:
    push cx
    push dx
    mov ah, T_MINUS
    call b_expect
    call g_coord
    mov di, G_PB
    mov [di+4], cx
    mov [di+6], dx
    pop word [di+2]
    pop word [di]
    mov byte [di+8], 0FFh           ; colour: foreground
    mov word [di+9], 0              ; line, solid
    call g_comma
    jz .draw
    call g_arg_ff
    mov [G_PB+8], al
    call g_comma
    jz .draw
    call b_skipsp
    cmp al, ','
    je .style
    cmp al, 'B'                     ; B / BF are stored as variable names
    jne err_syntax
    mov bl, 1
    cmp byte [si+1], 0
    je .b
    cmp byte [si+1], 1
    jne err_syntax
    cmp byte [si+2], 'F'
    jne err_syntax
    inc si
    inc bl
.b:
    add si, 2
    mov [G_PB+9], bl
.style:
    call g_comma
    jz .draw
    call b_eval
    cmp byte [FAC_TYPE], VT_STR
    je .tile
    call fac_uint
    cmp byte [G_PB+9], 2
    je .fill
    mov [G_PB+11], ah               ; line style: first 8 dots in the high byte
    mov [G_PB+12], al
    mov byte [G_PB+10], 1
    jmp .draw
.fill:
    mov [G_PB+11], al               ; BF with a fill colour
    mov byte [G_PB+10], 1
    jmp .draw
.tile:
    cmp byte [G_PB+9], 2
    jne err_func
    mov al, [FAC_I]
    mov [G_PB+13], al
    mov ax, [FAC_P]
    mov [G_PB+14], ax
    mov ax, [FAC_SEG]
    mov [G_PB+16], ax
    mov byte [G_PB+10], 2
.draw:
    mov bx, G_PB
    int 0A7h                        ; LIO GLINE
    call g_status
    jmp stmt_end

; PSET / PRESET [STEP](x,y)[,colour]
stmt_pset:
    mov ah, 1
    jmp g_pset
stmt_preset:
    mov ah, 2
g_pset:
    push ax
    call g_coord
    mov [G_PB], cx
    mov [G_PB+2], dx
    mov byte [G_PB+4], 0FFh
    call g_comma
    jz .go
    call g_arg_ff
    mov [G_PB+4], al
.go:
    pop ax
    mov bx, G_PB
    int 0A6h                        ; LIO GPSET (AH 1 foreground, 2 background)
    call g_status
    jmp stmt_end

; CIRCLE [STEP](x,y),r[,colour[,start,end[,aspect]]] (no arcs or F here)
stmt_circle:
    call g_coord
    mov di, G_PB
    mov [di], cx
    mov [di+2], dx
    mov ah, ','
    call b_expect
    call b_eval_int
    push ax                         ; radius
    mov byte [G_PB+8], 0FFh
    mov byte [G_PB+9], 0
    mov dword [G_ASP], F_ONE
    call g_comma
    jz .go
    call g_arg_ff
    mov [G_PB+8], al
    mov cx, 2                       ; start and end angles: must be empty
.angle:
    call g_comma
    jz .go
    call b_at_end
    je .go
    cmp al, ','
    jne err_feature
    loop .angle
    call g_comma
    jz .go
    call b_at_end
    je .go
    cmp al, ','
    je .go
    call b_eval
    call fac_sng
    mov [G_ASP], eax
    call g_comma
    jnz err_feature                 ; F (filled): not yet
.go:
    pop ax
    push ax
    call f_from_int                 ; EAX = r
    push eax
    mov eax, [G_ASP]
    mov ebx, F_ONE
    call f_cmp                      ; aspect < 1: ry = r * aspect
    pop eax
    mov ebx, [G_ASP]
    cmp dh, 1
    jne .tall
    call f_mul
    call f_to_int
    mov [G_PB+6], ax
    pop ax
    mov [G_PB+4], ax
    jmp .draw
.tall:                              ; aspect >= 1: rx = r / aspect
    call f_div
    call f_to_int
    mov [G_PB+4], ax
    pop ax
    mov [G_PB+6], ax
.draw:
    mov bx, G_PB
    int 0A8h                        ; LIO GCIRCLE
    call g_status
    jmp stmt_end

; PAINT [STEP](x,y)[,colour|tile$[,border]]
stmt_paint:
    call g_coord
    mov [G_PB], cx
    mov [G_PB+2], dx
    mov word [G_PB+4], 0FFFFh       ; colour, border: foreground / same
    call g_comma
    jz .solid
    call b_at_end
    je .solid
    cmp al, ','
    je .border
    call b_eval
    cmp byte [FAC_TYPE], VT_STR
    je .tile
    call fac_int
    mov [G_PB+4], al
.border:
    call g_comma
    jz .solid
    call g_arg_ff
    mov [G_PB+5], al
    call g_comma
    jnz err_feature
.solid:
    call g_work
    mov [G_PB+6], ax
    mov [G_PB+8], dx
    mov bx, G_PB
    int 0A9h                        ; LIO GPAINT1
    call g_status
    jmp stmt_end
.tile:
    mov al, [FAC_I]
    mov [G_PB+5], al
    mov ax, [FAC_P]
    mov [G_PB+6], ax
    mov ax, [FAC_SEG]
    mov [G_PB+8], ax
    mov al, [G_LWFG]
    mov [G_PB+10], al
    call g_comma
    jz .t
    call g_arg_ff
    cmp al, 0FFh
    je .t1
    mov [G_PB+10], al
.t1:
    call g_comma
    jnz err_feature
.t:
    call g_work
    mov [G_PB+16], ax
    mov [G_PB+18], dx
    mov bx, G_PB
    int 0AAh                        ; LIO GPAINT2
    call g_status
    jmp stmt_end

; VIEW [[SCREEN](x1,y1)-(x2,y2)[,[area colour][,frame colour]]]
stmt_view:
    inc si                          ; (FFh 85h)
    call b_at_end
    je g_view_full
    xor bx, bx
    cmp al, T_SCREEN
    jne .v
    inc si
    inc bx
.v:
    push bx
    call g_pair
    push cx
    push dx
    mov ah, T_MINUS
    call b_expect
    call g_pair
    mov di, G_PB
    mov [di+4], cx
    mov [di+6], dx
    pop word [di+2]
    pop word [di]
    mov word [di+8], 0FFFFh
    call g_comma
    jz .set
    call g_arg_ff
    mov [G_PB+8], al
    call g_comma
    jz .set
    call g_arg_ff
    mov [G_PB+9], al
.set:
    mov bx, G_PB
    int 0A2h                        ; LIO GVIEW
    call g_status
    pop bx
    xor ax, ax
    xor dx, dx
    test bx, bx
    jnz .org
    mov ax, [G_PB]
    mov dx, [G_PB+2]
.org:
    mov [G_OX], ax
    mov [G_OY], dx
    jmp stmt_end

; Whole screen, origin 0,0 (VIEW without arguments; SCREEN resets the view).
g_view_full:
    mov di, G_PB
    xor ax, ax
    mov [di], ax
    mov [di+2], ax
    mov word [di+4], 639
    mov word [di+6], 399            ; (LIO limits it to the screen)
    mov word [di+8], 0FFFFh
    push 1                          ; origin 0,0
    jmp stmt_view.set

; POINT [STEP](x,y): sets the last point.
stmt_point:
    inc si                          ; (FFh 82h)
    call g_coord
    jmp stmt_end

; POINT(x,y): colour of a dot (-1 outside the view).
fn_point:
    call g_pair
    add cx, [G_OX]
    add dx, [G_OY]
    mov [G_PB], cx
    mov [G_PB+2], dx
    mov bx, G_PB
    int 0AFh                        ; LIO GPOINT2: AL = palette
    test ah, ah
    jnz .out
    xor ah, ah
    jmp fac_set_int
.out:
    mov ax, -1
    jmp fac_set_int

; Array argument of PUT @ / GET @: name(subscripts) or the whole array (its
; first element) -> BX (VSEG).
g_array:
    call b_skipsp
    call b_parse_name
    cmp byte [si], '('
    jne .whole
    jmp b_getvar_named
.whole:
    call b_find_array
    jc err_func
    push es
    mov es, [B_VSEG]
    movzx di, byte [es:bx+1]
    lea di, [bx+di+2]               ; -> entry size
    movzx cx, byte [es:di+2]
    shl cx, 1
    add di, cx
    mov bx, [es:di+3]               ; data offset
    add bx, [B_ADATA]
    pop es
    ret

; PUT @[STEP](x,y),array[,PSET|PRESET|OR|AND|XOR]
stmt_put_at:
    inc si                          ; '@'
    call g_coord
    mov [G_PB], cx
    mov [G_PB+2], dx
    mov ah, ','
    call b_expect
    call g_array
    mov [G_PB+4], bx
    mov ax, [B_VSEG]
    mov [G_PB+6], ax
    mov word [G_PB+8], 0FFFFh
    mov word [G_PB+10], 4           ; XOR, colour data
    call g_comma
    jz .go
    call b_skipsp
    inc si
    mov bl, 0
    cmp al, T_PSET
    je .m
    inc bl
    cmp al, T_PRESET
    je .m
    inc bl
    cmp al, T_OR
    je .m
    inc bl
    cmp al, T_AND
    je .m
    inc bl
    cmp al, T_XOR
    jne err_syntax
.m:
    mov [G_PB+10], bl
    call g_comma
    jnz err_feature
.go:
    mov bx, G_PB
    int 0ACh                        ; LIO GPUT1
    call g_status
    jmp stmt_end

; COLOR @(x1,y1)-(x2,y2),colour: text attributes of a rectangle.
stmt_color_at:
    inc si                          ; '@'
    call g_pair
    push cx
    push dx
    mov ah, T_MINUS
    call b_expect
    call g_pair
    push cx
    push dx
    mov ah, ','
    call b_expect
    call b_eval_int
    and al, 7
    shl al, 5
    or al, 1
    mov bl, al                      ; attribute
    pop dx                          ; y2
    pop cx                          ; x2
    pop word [G_PB]                 ; y1
    pop ax                          ; x1
    push ax
    movzx ax, byte [B_WIDTH]
    dec ax
    cmp cx, ax
    jbe .x2
    mov cx, ax
.x2:
    pop ax
    cmp dx, 24
    jbe .y2
    mov dx, 24
.y2:
    push es
    push si
    mov si, TATTR
    mov es, si
    sub cx, ax
    jb .done
    inc cx                          ; columns
.row:
    cmp [G_PB], dx
    ja .done
    imul di, [G_PB], 160
    add di, ax
    add di, ax
    cmp byte [B_WIDTH], 40
    jne .w
    add di, ax
    add di, ax
.w:
    push cx
.col:
    mov [es:di], bl
    mov byte [es:di+1], 0
    add di, 2
    cmp byte [B_WIDTH], 40
    jne .n
    add di, 2
.n:
    loop .col
    pop cx
    inc word [G_PB]
    jmp .row
.done:
    pop si
    pop es
    jmp stmt_end

; BEEP [switch]: 1 on, 0 off, none = a short beep.
stmt_beep:
    call b_at_end
    je .short
    call b_eval_int
    test ax, ax
    mov al, 07h                     ; 8255 port C bit 3 = 1: buzzer off
    jz .out
    mov al, 06h
.out:
    out 37h, al
    jmp stmt_end
.short:
    mov al, 06h
    out 37h, al
    mov bx, 4
.w:
    xor cx, cx
.w1:
    out 5Fh, al                     ; ~0.6 us each
    loop .w1
    dec bx
    jnz .w
    mov al, 07h
    out 37h, al
    jmp stmt_end
