; Statements.

FRAME_GOSUB     equ 4753h           ; 'GS'
FRAME_FOR       equ 4F46h           ; 'FO'
FOR_WORDS       equ 6               ; marker, var, limit, step, line, text
STACK_LIMIT     equ B_STACK-0700h

; ---------------------------------------------------------------- token scan
; Step over one token at SI (not 00h). AL = its first byte.
b_tok_skip:
    lodsb
    cmp al, '"'
    je .str
    cmp al, 'A'
    jb .notvar
    cmp al, 'Z'
    ja .notvar
    push ax
    lodsb                           ; name: count, rest
    movzx ax, al
    add si, ax
    pop ax
    ret
.notvar:
    cmp al, 0Fh
    je .one
    cmp al, 0FFh
    je .one
    cmp al, 1Dh
    je .four
    cmp al, 1Fh
    je .eight
    cmp al, 0Bh
    je .two
    cmp al, 0Ch
    je .two
    cmp al, 0Dh
    je .two
    cmp al, 0Eh
    je .two
    cmp al, 1Ch
    je .two
    cmp al, T_DATA
    je .data
    ret
.eight:
    add si, 4
.four:
    add si, 2
.two:
    inc si
.one:
    inc si
    ret
.str:
    cmp byte [si], 0
    je .r
    cmp byte [si], '"'
    je .strend
    inc si
    jmp .str
.strend:
    inc si
.r:
    ret
.data:                              ; raw text up to ':' outside quotes
    push ax
.d:
    mov al, [si]
    test al, al
    jz .dend
    cmp al, ':'
    je .dend
    inc si
    cmp al, '"'
    jne .d
.dq:
    mov al, [si]
    test al, al
    jz .dend
    inc si
    cmp al, '"'
    jne .dq
    jmp .d
.dend:
    pop ax
    ret

; ---------------------------------------------------------------- LET
stmt_let_tok:
    jmp stmt_let

stmt_let:
    call b_getvar
    push bx
    push ax
    mov ah, T_EQ
    call b_expect
    call b_eval
    pop ax
    pop bx
    call b_assign
    jmp stmt_end

; FAC -> variable of type AL at BX.
b_assign:
    cmp al, VT_STR
    je .str
    cmp byte [FAC_TYPE], VT_INT
    jne err_type
    mov dx, [FAC_I]
    mov [fs:bx], dx
    ret
.str:
    cmp byte [FAC_TYPE], VT_STR
    jne err_type
    push bx
    call b_fac_to_vseg              ; strings outside VSEG are copied
    pop bx
    mov [fs:bx], cl
    mov byte [fs:bx+1], 0
    mov [fs:bx+2], di
    ret

; ---------------------------------------------------------------- PRINT
stmt_print:
    mov byte [B_PRNL], 0
.item:
    call b_at_end
    je .end
    cmp al, ';'
    jne .notsemi
    inc si
    mov byte [B_PRNL], 1
    jmp .item
.notsemi:
    cmp al, ','
    jne .notcomma
    inc si
    mov byte [B_PRNL], 1
    mov al, [B_CSRX]
    xor ah, ah
    mov bl, 14
    div bl
    inc al
    mul bl
    cmp al, [B_WIDTH]
    jb .tab
    call b_newline
    jmp .item
.tab:
    mov [B_CSRX], al
    jmp .item
.notcomma:
    mov byte [B_PRNL], 0
    call b_eval
    cmp byte [FAC_TYPE], VT_STR
    je .str
    mov ax, [FAC_I]
    call b_fmt_int
    call b_puts
    mov al, ' '
    call b_putc
    jmp .item
.str:
    mov bx, [FAC_P]
    mov cx, [FAC_I]
    mov es, [FAC_SEG]
    call b_puts
    push ds
    pop es
    jmp .item
.end:
    cmp byte [B_PRNL], 0
    jne stmt_end
    call b_newline
    jmp stmt_end

; ---------------------------------------------------------------- jumps
; Line number token at SI -> AX.
b_get_linenum:
    call b_skipsp
    cmp al, 0Eh
    jne err_syntax
    inc si
    lodsw
    ret

stmt_goto:
    call b_get_linenum
    jmp b_goto_line

stmt_gosub:
    call b_get_linenum
    call b_find_line
    jc err_line
b_gosub_bx:                         ; return to SI
    cmp sp, STACK_LIMIT
    jb err_memory
    push si
    push word [B_CURLINE]
    push word FRAME_GOSUB
    jmp b_goto_bx

stmt_return:
.find:
    cmp sp, B_STACK
    jae .none
    pop ax
    cmp ax, FRAME_GOSUB
    je .got
    cmp ax, FRAME_FOR
    jne .none
    add sp, (FOR_WORDS-1)*2
    jmp .find
.got:
    pop bx
    pop si
    mov [B_CURLINE], bx
    mov ax, [bx+2]
    mov [CURLIN], ax
    jmp stmt_end
.none:
    mov al, E_RETURN
    jmp b_error

; ON expr GOTO/GOSUB lines   |   ON STOP/KEY/... (event traps: ignored)
stmt_on:
    call b_skipsp
    cmp al, 80h
    jb .expr
    cmp al, T_NOT
    je .expr
    cmp al, T_MINUS
    je .expr
    cmp al, T_PLUS
    je .expr
    cmp al, 0FFh
    je .expr
    cmp al, T_USR
    je .expr
    call b_skip_stmt                ; ON STOP GOSUB, ON KEY ... not trapped yet
    jmp stmt_end
.expr:
    call b_eval_int
    mov cx, ax
    call b_skipsp
    inc si
    cmp al, T_GOTO
    je .list
    cmp al, T_GOSUB
    jne err_syntax
.list:
    mov dl, al
    xor bx, bx                      ; chosen line
.l:
    call b_skipsp
    cmp al, 0Eh
    jne .ldone
    inc si
    lodsw
    dec cx
    jnz .lnext
    mov bx, ax
    inc bx                          ; remember (line + 1, 0 = none)
.lnext:
    call b_skipsp
    cmp al, ','
    jne .ldone
    inc si
    jmp .l
.ldone:
    test bx, bx
    jz stmt_end
    dec bx
    mov ax, bx
    cmp dl, T_GOTO
    je b_goto_line
    call b_find_line
    jc err_line
    jmp b_gosub_bx

; IF expr THEN statements/line [ELSE statements/line]   (or IF expr GOTO line)
stmt_if:
    call b_eval
    call fac_int
    push ax
    call b_skipsp
    pop dx
    cmp al, T_GOTO
    je .goto_form
    cmp al, T_THEN
    jne err_syntax
    inc si
    test dx, dx
    jz .false
.branch:
    call b_skipsp
    cmp al, 0Eh
    jne stmt_next
    inc si
    lodsw
    jmp b_goto_line
.goto_form:
    inc si
    test dx, dx
    jz .false
    call b_get_linenum
    jmp b_goto_line
.false:
    xor cx, cx                      ; IF nesting
.scan:
    mov al, [si]
    test al, al
    jz stmt_eol
    cmp al, T_IF
    jne .notif
    inc cx
.notif:
    cmp al, T_ELSE
    jne .skip
    jcxz .else
    dec cx
.skip:
    call b_tok_skip
    jmp .scan
.else:
    inc si
    jmp .branch

; ---------------------------------------------------------------- FOR/NEXT
stmt_for:
    call b_getvar
    cmp al, VT_STR
    je err_type
    push bx
    mov ah, T_EQ
    call b_expect
    call b_eval_int
    pop bx
    mov [fs:bx], ax
    push bx
    mov ah, T_TO
    call b_expect
    call b_eval_int
    push ax                         ; limit
    mov ax, 1
    call b_skipsp
    cmp al, T_STEP
    mov ax, 1
    jne .nostep
    inc si
    call b_eval_int
.nostep:
    mov dx, ax                      ; step
    pop cx                          ; limit
    pop bx                          ; variable
    ; drop an earlier FOR frame of the same variable (and those inside it)
    mov bp, sp
.old:
    cmp bp, B_STACK
    jae .push
    cmp word [bp], FRAME_FOR
    jne .push
    cmp [bp+2], bx
    je .drop
    add bp, FOR_WORDS*2
    jmp .old
.drop:
    lea sp, [bp+FOR_WORDS*2]
.push:
    ; skip the loop when it would not run once
    mov ax, [fs:bx]
    test dx, dx
    js .neg
    cmp ax, cx
    jg .skip
    jmp .enter
.neg:
    cmp ax, cx
    jl .skip
.enter:
    cmp sp, STACK_LIMIT
    jb err_memory
    push si
    push word [B_CURLINE]
    push dx
    push cx
    push bx
    push word FRAME_FOR
    jmp stmt_end
.skip:                              ; to the matching NEXT
    mov bx, [B_CURLINE]
    xor cx, cx
.sk:
    mov al, [si]
    test al, al
    jnz .sktok
    cmp word [bx+2], 0FFFFh
    je basic_ready
    add bx, [bx]
    cmp word [bx], 0
    je .nonext
    mov [B_CURLINE], bx
    mov ax, [bx+2]
    mov [CURLIN], ax
    lea si, [bx+4]
    jmp .sk
.sktok:
    cmp al, T_FOR
    jne .notfor
    inc cx
.notfor:
    cmp al, T_NEXT
    jne .sknext
    jcxz .found
    dec cx
.sknext:
    call b_tok_skip
    jmp .sk
.found:
    inc si
    call b_skip_stmt                ; NEXT's variables
    jmp stmt_end
.nonext:
    mov al, E_NEXT
    jmp b_error

stmt_nextvar:
.one:
    xor bx, bx
    call b_at_end
    je .find
    call b_getvar
.find:
    mov bp, sp
.f:
    cmp bp, B_STACK
    jae .none
    cmp word [bp], FRAME_FOR
    jne .none
    test bx, bx
    jz .got
    cmp [bp+2], bx
    je .got
    add bp, FOR_WORDS*2
    jmp .f
.got:
    mov sp, bp
    mov di, [bp+2]                  ; variable
    mov ax, [fs:di]
    mov dx, [bp+6]                  ; step
    add ax, dx
    jo .done                        ; past the integer range: loop ends
    mov [fs:di], ax
    test dx, dx
    js .neg
    cmp ax, [bp+4]
    jg .done
    jmp .again
.neg:
    cmp ax, [bp+4]
    jl .done
.again:
    mov bx, [bp+8]
    mov si, [bp+10]
    mov [B_CURLINE], bx
    mov ax, [bx+2]
    mov [CURLIN], ax
    jmp stmt_end
.done:
    add sp, FOR_WORDS*2
    call b_skipsp
    cmp al, ','
    jne stmt_end
    inc si
    jmp .one
.none:
    mov al, E_NEXT
    jmp b_error

; ---------------------------------------------------------------- DATA / READ
stmt_data:
    dec si
    call b_tok_skip
    jmp stmt_end

stmt_read:
.var:
    call b_getvar
    push bx
    push ax
    call b_data_item                ; BX = text, CX = length
    pop ax
    pop di
    cmp al, VT_STR
    je .str
    push si
    mov si, bx
    call b_val_text
    pop si
    mov [fs:di], ax
    jmp .next
.str:
    mov [FAC_I], cx                 ; DATA text: copied into VSEG
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

; Next DATA item -> BX = text, CX = length (quotes removed).
b_data_item:
    push si
    push dx
    mov si, [B_DATPTR]
    mov dx, [B_DATLINE]
    test si, si
    jnz .at
    mov bx, [TXTTAB]
    cmp word [bx], 0
    je .out
    lea si, [bx+4]
    mov dx, bx
    jmp .search
.at:
    mov al, [si]
    cmp al, ','
    jne .notcomma
    inc si
    jmp .item
.notcomma:
    ; end of this DATA statement: look for the next one
.search:
    mov bx, dx
.s:
    mov al, [si]
    test al, al
    jnz .stok
    add bx, [bx]
    cmp word [bx], 0
    je .out
    lea si, [bx+4]
    jmp .s
.stok:
    cmp al, T_DATA
    je .found
    call b_tok_skip
    jmp .s
.found:
    inc si
    mov dx, bx
.item:
    mov al, [si]
    cmp al, ' '
    jne .nb
    inc si
    jmp .item
.nb:
    cmp al, '"'
    jne .plain
    inc si
    mov bx, si
.q:
    mov al, [si]
    test al, al
    jz .qend
    cmp al, '"'
    je .qclose
    inc si
    jmp .q
.qclose:
    mov cx, si
    sub cx, bx
    inc si
    jmp .skipto
.qend:
    mov cx, si
    sub cx, bx
    jmp .done
.plain:
    mov bx, si
.p:
    mov al, [si]
    test al, al
    jz .pend
    cmp al, ','
    je .pend
    cmp al, ':'
    je .pend
    inc si
    jmp .p
.pend:
    mov cx, si
    sub cx, bx
.trim:
    jcxz .done
    mov di, bx
    add di, cx
    cmp byte [di-1], ' '
    jne .done
    dec cx
    jmp .trim
.skipto:                            ; after a quoted item: up to ',' ':' 0
    mov al, [si]
    test al, al
    jz .done
    cmp al, ','
    je .done
    cmp al, ':'
    je .done
    inc si
    jmp .skipto
.done:
    mov [B_DATPTR], si
    mov [B_DATLINE], dx
    pop dx
    pop si
    ret
.out:
    mov al, E_DATA
    jmp b_error

stmt_restore:
    mov word [B_DATPTR], 0
    call b_at_end
    je stmt_end
    call b_get_linenum
    call b_find_line
    jc err_line
    lea ax, [bx+4]
    mov [B_DATPTR], ax
    mov [B_DATLINE], bx
    jmp stmt_end

; ---------------------------------------------------------------- DEF...
stmt_deftype:                       ; DEFINT/DEFSTR/DEFSNG/DEFDBL letter ranges
    mov dl, VT_INT
    cmp al, T_DEFINT
    je .go
    mov dl, VT_STR
    cmp al, T_DEFSTR
    je .go
    mov dl, VT_SNG
    cmp al, T_DEFSNG
    je .go
    mov dl, VT_DBL
.go:
    call b_skipsp
    cmp al, 'A'
    jb err_syntax
    cmp al, 'Z'
    ja err_syntax
    mov bl, al
    mov bh, al
    add si, 2                       ; letter, count 0
    call b_skipsp
    cmp al, T_MINUS
    jne .set
    inc si
    call b_skipsp
    cmp al, 'A'
    jb err_syntax
    cmp al, 'Z'
    ja err_syntax
    mov bh, al
    add si, 2
.set:
    cmp bl, bh
    ja err_syntax
    push bx
    movzx di, bl
    sub di, 'A'
    add di, B_DEFTBL
.l:
    mov [di], dl
    inc di
    inc bl
    cmp bl, bh
    jbe .l
    pop bx
    call b_skipsp
    cmp al, ','
    jne stmt_end
    inc si
    jmp .go

stmt_def:
    call b_skipsp
    cmp al, T_SEG
    je .seg
    cmp al, T_USR
    je .usr
    jmp err_feature                 ; DEF FN
.seg:
    inc si
    mov word [B_DEFSEG], BSEG
    call b_at_end
    je stmt_end
    mov ah, T_EQ
    call b_expect
    call b_eval_int
    mov [B_DEFSEG], ax
    jmp stmt_end
.usr:
    inc si
    xor bx, bx
    mov al, [si]
    cmp al, 10h
    jb .n
    cmp al, 19h
    ja .n
    inc si
    sub al, 10h
    mov bl, al
.n:
    push bx
    mov ah, T_EQ
    call b_expect
    call b_eval_int
    pop bx
    shl bx, 2
    mov [USRTAB+bx], ax
    mov ax, [B_DEFSEG]
    mov [USRTAB+bx+2], ax
    jmp stmt_end

; ---------------------------------------------------------------- memory, ports
stmt_poke:
    call b_eval_int
    push ax
    mov ah, ','
    call b_expect
    call b_eval_int
    pop bx
    push es
    mov es, [B_DEFSEG]
    mov [es:bx], al
    pop es
    jmp stmt_end

stmt_out:
    call b_eval_int
    push ax
    mov ah, ','
    call b_expect
    call b_eval_int
    pop dx
    out dx, al
    jmp stmt_end

; CALL variable: machine code at DEF SEG:value through INT C3h.
stmt_call:
    call b_getvar
    cmp al, VT_STR
    je err_type
    mov ax, [fs:bx]
    mov dx, [B_DEFSEG]
    call b_call_c3
    call b_skipsp
    cmp al, '('
    jne stmt_end
    jmp err_feature                 ; CALL with arguments

; ---------------------------------------------------------------- program control
; CLEAR [string space][,top of the data area (VSEG offset)[,stack]]
stmt_clear:
    call b_args
    cmp byte [B_ARGN+1], 0
    je .keep
    mov ax, [B_ARGS+2]
    cmp ax, VAR_START+100h
    jb err_func
    mov [B_STRTOP], ax
.keep:
    call b_clear_vars
    mov sp, B_STACK
    jmp stmt_end

stmt_run:
    call b_clear_vars
    mov sp, B_STACK
    call b_at_end
    je .first
    call b_get_linenum
    jmp b_goto_line
.first:
    mov bx, [TXTTAB]
    cmp word [bx], 0
    je basic_ready
    jmp b_goto_bx

stmt_end_tok:
    jmp basic_ready

stmt_stop:
    call b_skipsp
    cmp al, T_ON
    je .flag
    cmp al, T_OFF
    je .flag
    call b_newline_if_needed
    mov si, msg_break
    call b_puts_cs
    mov ax, [CURLIN]
    cmp ax, 0FFFFh
    je .nl
    push si
    mov si, msg_in
    call b_puts_cs
    pop si
    call b_print_uint
.nl:
    call b_newline
    jmp basic_ready
.flag:                              ; STOP ON / STOP OFF: no trap handling yet
    inc si
    jmp stmt_end

; Statements accepted and ignored for now (sound, keys, tracing, ...).
stmt_ignore:
    call b_skip_stmt
    jmp stmt_end
