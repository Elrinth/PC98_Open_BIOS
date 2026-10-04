; INPUT, SWAP and PRINT USING.

; INPUT [;]["prompt"{;|,}] var[, var ...]   (INPUT #n: see bfile.asm)
stmt_input:
    call b_skipsp
    cmp al, '#'
    je stmt_input_file
    cmp al, ';'                     ; (no newline after the input: ignored)
    jne .p
    inc si
    call b_skipsp
.p:
    mov byte [B_INQ], 1
    cmp al, '"'
    jne .ask
    call b_eval_str
    push es
    mov es, [FAC_SEG]
    call b_puts
    pop es
    call b_skipsp
    inc si
    cmp al, ';'
    je .ask
    cmp al, ','
    jne err_syntax
    mov byte [B_INQ], 0             ; ',' after the prompt: no "? "
.ask:
    cmp byte [B_INQ], 0
    je .rd
    mov al, '?'
    call b_putc
    mov al, ' '
    call b_putc
.rd:
    mov word [B_INMORE], 0
    call b_readline                 ; KBUF
    mov word [B_INPTR], KBUF
b_input_vars:                       ; items from [B_INPTR] into the variables at SI
.var:
    call b_getvar
    push bx
    push ax
    call b_input_item               ; BX = text (BSEG), CX = length
    pop ax
    pop di
    cmp al, VT_STR
    je .str
    push si
    push ax
    push di
    mov si, bx
    call b_val_fac
    pop bx
    pop ax
    pop si
    call b_assign
    jmp .next
.str:
    mov [FAC_I], cx
    mov [FAC_P], bx
    mov [FAC_SEG], ds
    mov byte [FAC_TYPE], VT_STR
    mov bx, di
    call b_assign
.next:
    call b_skipsp
    cmp al, ','
    jne stmt_end
    inc si
    jmp .var

; Next input item at [B_INPTR] -> BX = text, CX = length ("..." or up to ','
; with trailing blanks removed). An empty buffer asks [B_INMORE] for more.
b_input_item:
    push si
    mov si, [B_INPTR]
    cmp byte [si], 0
    jne .sp
    cmp word [B_INMORE], 0
    je .sp
    call [B_INMORE]                 ; next line into the buffer, SI = start
.sp:
    cmp byte [si], ' '
    jne .q
    inc si
    jmp .sp
.q:
    cmp byte [si], '"'
    jne .raw
    inc si
    mov bx, si
.ql:
    mov al, [si]
    test al, al
    jz .qe
    cmp al, '"'
    je .qe
    inc si
    jmp .ql
.qe:
    mov cx, si
    sub cx, bx
.sk:
    mov al, [si]
    test al, al
    jz .done
    inc si
    cmp al, ','
    jne .sk
    jmp .done
.raw:
    mov bx, si
.rl:
    mov al, [si]
    test al, al
    jz .re
    cmp al, ','
    je .re
    inc si
    jmp .rl
.re:
    mov cx, si
    sub cx, bx
.tr:
    jcxz .t2
    mov di, bx
    add di, cx
    cmp byte [di-1], ' '
    jne .t2
    dec cx
    jmp .tr
.t2:
    cmp byte [si], ','
    jne .done
    inc si
.done:
    mov [B_INPTR], si
    pop si
    ret

; SWAP var, var
stmt_swap:
    call b_getvar
    push bx
    push ax
    mov ah, ','
    call b_expect
    call b_getvar
    pop dx
    cmp al, dl
    jne err_type
    pop di
    call b_typesize
    movzx cx, al
.l:
    mov al, [fs:bx]
    xchg al, [fs:di]
    mov [fs:bx], al
    inc bx
    inc di
    loop .l
    jmp stmt_end

; ---------------------------------------------------------------- USING
; PRINT USING "format"; items [;|,]   (SI after USING)
; Fields: ! (one character), &  & / \  \ (fixed width), & (whole string),
; [+]#,##.## (numbers; ',' separates thousands).
print_using:
    call b_eval_str                 ; CX, BX, FAC_SEG
    cmp cx, 63
    jbe .c
    mov cx, 63
.c:
    mov [G_USELEN], cx
    push si
    push ds
    mov si, bx
    mov di, G_USEBUF
    mov ds, [FAC_SEG]
    rep movsb
    pop ds
    pop si
    mov ah, ';'
    call b_expect
    mov byte [G_USEANY], 0
    mov byte [B_PRNL], 0
    xor di, di                      ; position in the format
.loop:
    cmp di, [G_USELEN]
    jb .ch
    call b_at_end                   ; end of the format: again while items remain
    je .finish
    cmp byte [G_USEANY], 0
    je err_func
    xor di, di
.ch:
    mov al, [G_USEBUF+di]
    call u_field                    ; CF: AL starts a field
    jc .field
    call b_putc
    inc di
    jmp .loop
.field:
    call b_at_end
    je .finish
    mov byte [G_USEANY], 1
    mov byte [B_PRNL], 0
    push di
    call b_eval
    pop di
    cmp byte [G_USEBUF+di], '!'
    je .s1
    cmp byte [G_USEBUF+di], '&'
    je .samp
    cmp byte [G_USEBUF+di], '\'
    je .sbs
    call u_number
    jmp .sep
.s1:
    inc di
    mov cx, 1
    jmp .sfix
.samp:
    call u_width                    ; CX = width, 0: whole string
    jcxz .swhole
    jmp .sfix
.sbs:
    call u_width
    jcxz .s1
.sfix:                              ; string in CX columns
    cmp byte [FAC_TYPE], VT_STR
    jne err_type
    push di
    mov dx, cx
    mov cx, [FAC_I]
    cmp cx, dx
    jbe .sf
    mov cx, dx
.sf:
    sub dx, cx
    mov bx, [FAC_P]
    push es
    mov es, [FAC_SEG]
    call b_puts
    pop es
.pad:
    test dx, dx
    jz .sd
    mov al, ' '
    call b_putc
    dec dx
    jmp .pad
.sd:
    pop di
    jmp .sep
.swhole:
    cmp byte [FAC_TYPE], VT_STR
    jne err_type
    mov cx, [FAC_I]
    mov bx, [FAC_P]
    push es
    mov es, [FAC_SEG]
    call b_puts
    pop es
.sep:
    call b_skipsp
    cmp al, ';'
    je .sp
    cmp al, ','
    jne .loop
.sp:
    inc si
    mov byte [B_PRNL], 1
    jmp .loop
.finish:
    cmp byte [B_PRNL], 0
    jne stmt_end
    call b_newline
    jmp stmt_end

; CF set when the format character AL at DI starts a field.
u_field:
    cmp al, '!'
    je .y
    cmp al, '&'
    je .y
    cmp al, '#'
    je .y
    cmp al, '\'
    je .bs
    cmp al, '+'
    je .num
    cmp al, '.'
    je .num
    clc
    ret
.bs:
    push di
    inc di
.b1:
    cmp di, [G_USELEN]
    jae .no
    cmp byte [G_USEBUF+di], ' '
    jne .b2
    inc di
    jmp .b1
.b2:
    cmp byte [G_USEBUF+di], '\'
    jne .no
    pop di
    stc
    ret
.no:
    pop di
    clc
    ret
.num:
    lea bx, [di+1]
    cmp bx, [G_USELEN]
    jae .n
    cmp byte [G_USEBUF+bx], '#'
    je .y
.n:
    clc
    ret
.y:
    stc
    ret

; '&'/'\' field at DI: CX = blanks + 2 when closed by the same character
; (DI after it), else CX = 0 (DI after the first character).
u_width:
    mov ah, [G_USEBUF+di]
    lea bx, [di+1]
    xor cx, cx
.l:
    cmp bx, [G_USELEN]
    jae .open
    mov al, [G_USEBUF+bx]
    cmp al, ah
    je .closed
    cmp al, ' '
    jne .open
    inc bx
    inc cx
    jmp .l
.closed:
    add cx, 2
    lea di, [bx+1]
    ret
.open:
    inc di
    xor cx, cx
    ret

; Number field at DI: FAC formatted, DI after the field.
u_number:
    cmp byte [FAC_TYPE], VT_STR
    je err_type
    mov dword [G_UPLUS], 0          ; G_UPLUS, G_UCOMMA, G_UINT, G_UDEC
    mov byte [G_UPT], 0
    cmp byte [G_USEBUF+di], '+'
    jne .i
    inc byte [G_UPLUS]
    inc di
.i:
    cmp di, [G_USELEN]
    jae .end
    mov al, [G_USEBUF+di]
    cmp al, '#'
    je .ip
    cmp al, ','
    jne .pt
    mov byte [G_UCOMMA], 1
.ip:
    inc byte [G_UINT]
    inc di
    jmp .i
.pt:
    cmp al, '.'
    jne .end
    inc byte [G_UPT]
    inc di
.d:
    cmp di, [G_USELEN]
    jae .end
    cmp byte [G_USEBUF+di], '#'
    jne .end
    inc byte [G_UDEC]
    inc di
    jmp .d
.end:
    push di
    push si
    call fac_sng                    ; EAX
    mov byte [F_NEG], 0
    test eax, 0FF000000h
    jz .pos                         ; zero: no sign
    test eax, 00800000h
    jz .pos
    xor eax, 00800000h
    mov byte [F_NEG], 1
.pos:
    movzx cx, byte [G_UDEC]
    jcxz .rnd
.sc:
    mov ebx, 84200000h              ; 10
    call f_mul
    loop .sc
.rnd:
    call f_to_int32_round           ; EAX = |value| * 10^decimals
    mov di, G_NUMBUF+31
    mov byte [di], 0
    mov ebx, 10
    movzx cx, byte [G_UDEC]
    jcxz .ipart
.fr:
    xor edx, edx
    div ebx
    add dl, '0'
    dec di
    mov [di], dl
    loop .fr
.ipart:
    cmp byte [G_UPT], 0
    je .int
    dec di
    mov byte [di], '.'
.int:
    xor si, si                      ; integer digits written
.il:
    xor edx, edx
    div ebx
    cmp byte [G_UCOMMA], 0
    je .nc
    test si, si
    jz .nc
    push ax
    push dx
    mov ax, si
    xor dx, dx
    mov cx, 3
    div cx
    test dx, dx
    pop dx
    pop ax
    jnz .nc
    dec di
    mov byte [di], ','
.nc:
    add dl, '0'
    dec di
    mov [di], dl
    inc si
    test eax, eax
    jnz .il
    cmp byte [F_NEG], 0
    je .ps
    dec di
    mov byte [di], '-'
    jmp .sg
.ps:
    cmp byte [G_UPLUS], 0
    je .sg
    dec di
    mov byte [di], '+'
.sg:
    movzx ax, byte [G_UINT]
    add al, [G_UPLUS]
    add al, [G_UPT]
    add al, [G_UDEC]
    mov cx, G_NUMBUF+31
    sub cx, di                      ; length
    cmp cx, ax
    jbe .pad
    push ax
    mov al, '%'                     ; does not fit
    call b_putc
    pop ax
    jmp .out
.pad:
    sub ax, cx
.pl:
    test ax, ax
    jz .out
    push ax
    mov al, ' '
    call b_putc
    pop ax
    dec ax
    jmp .pl
.out:
    mov bx, di
    call b_puts                     ; (ES = BSEG)
    pop si
    pop di
    ret
