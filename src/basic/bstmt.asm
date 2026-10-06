; Statements.

FRAME_GOSUB     equ 4753h           ; 'GS'
FRAME_WHILE     equ 5748h           ; 'WH': marker, line header, statement start
WHILE_WORDS     equ 3
FRAME_FOR       equ 4F46h           ; 'FO'
FOR_WORDS       equ 9               ; marker, var, type, limit(2), step(2), line, text
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
    cmp byte [FAC_TYPE], VT_STR
    je err_type
    cmp al, VT_INT
    jne .flt
    push ax
    call fac_int
    mov [fs:bx], ax
    pop ax
    ret
.flt:
    push eax
    push ax
    call fac_sng
    mov dl, al                      ; (keep EAX)
    pop dx
    cmp dl, VT_DBL
    je .dbl
    mov [fs:bx], eax
    pop eax
    ret
.dbl:
    mov dword [fs:bx], 0
    mov [fs:bx+4], eax
    pop eax
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
    call b_skipsp
    cmp al, '#'
    je print_file
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
    cmp al, T_USING
    jne .notusing
    inc si
    jmp print_using
.notusing:
    cmp al, T_SPC
    je .spc
    cmp al, T_TAB
    je .tab2
    mov byte [B_PRNL], 0
    call b_eval
    cmp byte [FAC_TYPE], VT_STR
    je .str
    call b_fmt_fac
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
.spc:                               ; SPC(n): n blanks
    inc si
    call fn_arg_int
    mov byte [B_PRNL], 1
    mov cx, ax
.spl:
    test cx, cx
    jle .item
    mov al, ' '
    call b_putc
    dec cx
    jmp .spl
.tab2:                              ; TAB(n): to column n
    inc si
    call fn_arg_int
    mov byte [B_PRNL], 1
.tbl:
    movzx cx, byte [B_CSRX]
    cmp cx, ax
    jge .item
    push ax
    mov al, ' '
    call b_putc
    pop ax
    jmp .tbl
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
    call b_get_target
    jmp b_goto_bx

stmt_gosub:
    call b_get_target
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
    cmp ax, FRAME_WHILE
    jne .nw
    add sp, (WHILE_WORDS-1)*2
    jmp .find
.nw:
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
    cmp al, T_ERROR
    je .onerror
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
.onerror:                           ; ON ERROR GOTO line/label (0: off)
    inc si
    mov ah, T_GOTO
    call b_expect
    call b_skipsp
    cmp al, 0Eh
    jne .oetgt
    cmp word [si+1], 0
    jne .oetgt
    add si, 3
    jmp .oeoff
.oetgt:
    cmp al, 10h                     ; GOTO 0 written as a small constant
    jne .oeset
    inc si
.oeoff:
    mov word [B_ONERR], 0
    cmp byte [B_INERR], 0
    je stmt_end
    mov byte [B_INERR], 0           ; inside a handler: report the error now
    mov al, [B_ERRNO]
    jmp b_error
.oeset:
    call b_get_target
    mov [B_ONERR], bx
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
    xor bx, bx                      ; chosen line header, 0 = none
.l:
    call b_skipsp
    cmp al, 0Eh
    je .tgt
    cmp al, '*'
    jne .ldone
.tgt:
    dec cx
    jnz .skip
    push dx
    call b_get_target
    pop dx
    jmp .lnext
.skip:
    inc si
    cmp al, '*'
    je .skipname
    add si, 2
    jmp .lnext
.skipname:
    movzx ax, byte [si+1]
    add si, ax
    add si, 2
.lnext:
    call b_skipsp
    cmp al, ','
    jne .ldone
    inc si
    jmp .l
.ldone:
    test bx, bx
    jz stmt_end
    cmp dl, T_GOTO
    je b_goto_bx
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
    je .tgt
    cmp al, '*'
    jne stmt_next
.tgt:
    call b_get_target
    jmp b_goto_bx
.goto_form:
    inc si
    test dx, dx
    jz .false
    call b_get_target
    jmp b_goto_bx
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
; Frame (top first): marker, variable, type, limit (2 words), step (2
; words), line header, text pointer. Integer loops keep integers, the rest
; singles.
stmt_for:
    call b_getvar
    cmp al, VT_STR
    je err_type
    push bx
    push ax
    mov ah, T_EQ
    call b_expect
    call b_eval
    pop ax
    pop bx
    push bx
    push ax
    call b_assign
    mov ah, T_TO
    call b_expect
    call b_eval
    pop ax
    push ax
    call .tovar                     ; EAX = limit in the variable's type
    push eax
    call b_skipsp
    cmp al, T_STEP
    jne .one
    inc si
    call b_eval
    mov bx, sp
    mov al, [ss:bx+4]               ; type
    call .tovar
    jmp .stepok
.one:
    mov bx, sp
    mov eax, 1
    cmp byte [ss:bx+4], VT_INT
    je .stepok
    mov eax, F_ONE
.stepok:
    mov [B_FSTEP], eax
    pop eax
    mov [B_FLIM], eax
    pop ax
    mov [B_FTYPE], al
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
    call b_for_done                 ; does the loop run at all?
    jc .skip
    cmp sp, STACK_LIMIT
    jb err_memory
    push si
    push word [B_CURLINE]
    push dword [B_FSTEP]
    push dword [B_FLIM]
    movzx ax, byte [B_FTYPE]
    push ax
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
    test cx, cx
    jz .found
    dec cx
.sknext:
    call b_tok_skip
    jmp .sk
.found:
    inc si
    call b_skip_stmt
    jmp stmt_end
.nonext:
    mov al, E_NEXT
    jmp b_error
.tovar:                             ; FAC -> EAX in type AL (int: low word)
    cmp al, VT_INT
    jne .tf
    call fac_int
    movsx eax, ax
    ret
.tf:
    jmp fac_sng

; Variable BX of type [B_FTYPE] against [B_FLIM] with step [B_FSTEP]:
; CF set when the loop is finished (past the limit).
b_for_done:
    push eax
    push ebx
    push edx
    cmp byte [B_FTYPE], VT_INT
    jne .f
    mov ax, [fs:bx]
    cmp word [B_FSTEP], 0
    jl .ineg
    cmp ax, [B_FLIM]
    jg .fin
    jmp .run
.ineg:
    cmp ax, [B_FLIM]
    jl .fin
    jmp .run
.f:
    mov eax, [fs:bx]
    cmp byte [B_FTYPE], VT_DBL
    jne .s
    mov eax, [fs:bx+4]
.s:
    mov ebx, [B_FLIM]
    call f_cmp
    test dword [B_FSTEP], 800000h
    jnz .fneg
    cmp dh, 4
    je .fin
    jmp .run
.fneg:
    cmp dh, 1
    je .fin
.run:
    pop edx
    pop ebx
    pop eax
    clc
    ret
.fin:
    pop edx
    pop ebx
    pop eax
    stc
    ret

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
    mov bx, [bp+2]                  ; variable
    mov al, [bp+4]
    mov [B_FTYPE], al
    mov eax, [bp+6]
    mov [B_FLIM], eax
    mov eax, [bp+10]
    mov [B_FSTEP], eax
    cmp byte [B_FTYPE], VT_INT
    jne .fadd
    mov ax, [fs:bx]
    add ax, [B_FSTEP]
    jo .done                        ; past the integer range: loop ends
    mov [fs:bx], ax
    jmp .test
.fadd:
    push bx
    mov eax, [fs:bx]
    cmp byte [B_FTYPE], VT_DBL
    jne .fs
    mov eax, [fs:bx+4]
.fs:
    mov ebx, [B_FSTEP]
    call f_add
    pop bx
    cmp byte [B_FTYPE], VT_DBL
    jne .fst
    mov dword [fs:bx], 0
    mov [fs:bx+4], eax
    jmp .test
.fst:
    mov [fs:bx], eax
.test:
    call b_for_done
    jc .done
    mov bx, [bp+14]
    mov si, [bp+16]
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

; ---------------------------------------------------------------- WHILE/WEND
; WHILE cond ... WEND: WEND goes back to the WHILE statement, which tests
; again; a false condition skips to the statement after the matching WEND.
stmt_while:
    mov di, [B_STMT]                ; this WHILE statement (for WEND)
    push di
    call b_eval
    call fac_int
    pop di
    test ax, ax
    jz .skip
    ; drop a frame of this same WHILE (we came back from its WEND)
    cmp sp, B_STACK
    jae .push
    mov bp, sp
    cmp word [bp], FRAME_WHILE
    jne .push
    cmp [bp+4], di
    jne .push
    add sp, WHILE_WORDS*2
.push:
    cmp sp, STACK_LIMIT
    jb err_memory
    push di
    push word [B_CURLINE]
    push word FRAME_WHILE
    jmp stmt_end
.skip:
    ; leave a frame of this WHILE if there is one
    cmp sp, B_STACK
    jae .scan
    mov bp, sp
    cmp word [bp], FRAME_WHILE
    jne .scan
    cmp [bp+4], di
    jne .scan
    add sp, WHILE_WORDS*2
.scan:
    mov bx, [B_CURLINE]
    xor cx, cx
.sk:
    mov al, [si]
    test al, al
    jnz .tok
    cmp word [bx+2], 0FFFFh
    je basic_ready
    add bx, [bx]
    cmp word [bx], 0
    je .nowend
    mov [B_CURLINE], bx
    mov ax, [bx+2]
    mov [CURLIN], ax
    lea si, [bx+4]
    jmp .sk
.tok:
    cmp al, T_WHILE
    jne .nw
    inc cx
.nw:
    cmp al, T_WEND
    jne .nx
    test cx, cx
    jz .found
    dec cx
.nx:
    call b_tok_skip
    jmp .sk
.found:
    inc si
    jmp stmt_end
.nowend:
    mov al, 26                      ; (WHILE without WEND)
    jmp b_error

stmt_wend:
    cmp sp, B_STACK
    jae .err
    mov bp, sp
    cmp word [bp], FRAME_WHILE
    jne .err
    mov bx, [bp+2]
    mov si, [bp+4]
    mov [B_CURLINE], bx
    mov ax, [bx+2]
    mov [CURLIN], ax
    jmp stmt_next                   ; the WHILE again (its frame is reused)
.err:
    mov al, 30                      ; WEND without WHILE
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
    push ax
    push di
    mov si, bx
    call b_val_fac                  ; DATA text -> FAC
    pop bx
    pop ax
    pop si
    call b_assign
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
    call b_get_target
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
    cmp al, T_FN
    jne err_syntax
    ; DEF FN name[(params)] = expr: remember where the name is
    inc si
    call b_skipsp
    mov di, si
    push di
    call b_parse_name               ; DX, CX, AH
    call b_find_fn                  ; BX -> slot (existing or new)
    pop di
    mov [bx], di
    call b_skip_stmt
    jmp stmt_end
.seg:
    inc si
    mov word [B_DEFSEG], BSEG
    call b_at_end
    je stmt_end
    mov ah, T_EQ
    call b_expect
    call b_eval_uint
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
    call b_eval_uint
    pop bx
    shl bx, 2
    mov [USRTAB+bx], ax
    mov ax, [B_DEFSEG]
    mov [USRTAB+bx+2], ax
    jmp stmt_end

; ---------------------------------------------------------------- memory, ports
stmt_poke:
    call b_eval_uint
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

; CALL scalar[(variables)]: argument pointers are in reverse order.
stmt_call:
    call b_skipsp
    call b_parse_name
    call b_getsimple                ; parentheses belong to CALL, not the target
    cmp al, VT_STR
    je err_type
    cmp al, VT_INT
    je .integer
    cmp al, VT_DBL
    jne .single
    add bx, 4
.single:
    mov eax, [fs:bx]
    call fac_set_sng
    jmp .address
.integer:
    mov ax, [fs:bx]
    call fac_set_int
.address:
    call fac_uint
    mov [B_CALLTARGET], ax
    mov dx, [B_DEFSEG]
    mov [B_CALLTARGET+2], dx
    push ax
    call b_skipsp
    cmp al, '('
    pop ax
    je .args
    call b_call_c3
    jmp stmt_end
.args:
    inc si
    xor cx, cx
.first:
    cmp cx, 16
    jae err_func
    push cx
    call b_getvar
    pop cx
    mov di, cx
    shl di, 2
    mov ax, [B_VSEG]
    cmp byte [B_ISARR], 0
    je .pointer
    sub bx, [B_ADATA]               ; later scalars can relocate array storage
    xor ax, ax                     ; mark this as an array-relative pointer
.pointer:
    mov [B_CALLARGS+di], bx
    mov [B_CALLARGS+di+2], ax
    inc cx
    call b_skipsp
    inc si
    cmp al, ','
    je .first
    cmp al, ')'
    jne err_syntax
    mov [B_CALLCOUNT], cx
    push si
    mov di, B_CALLARGS
.resolve:
    cmp word [di+2], 0
    jne .resolved
    mov ax, [B_ADATA]
    add [di], ax
    mov ax, [B_VSEG]
    mov [di+2], ax
.resolved:
    add di, 4
    loop .resolve
    ; Reverse the completed table without evaluating any subscript twice.
    sub di, 4
    mov bx, B_CALLARGS
.reverse:
    cmp bx, di
    jae .ready
    mov eax, [bx]
    xchg eax, [di]
    mov [bx], eax
    add bx, 4
    sub di, 4
    jmp .reverse
.ready:
    xor ax, ax
    mov es, ax
    mov eax, [B_CALLTARGET]
    pushf
    cli
    mov [es:0C3h*4], eax
    popf
    push ds
    pop es
    push bp
    mov bx, B_CALLARGS
    mov ax, [B_CALLCOUNT]
    mov cx, ds
    mov dx, [B_VSEG]
    int 0C3h
    call b_ds_es
    cld
    pop bp
    pop si
    jmp stmt_end

; ---------------------------------------------------------------- program control
; CLEAR [string space][,top of the data area (VSEG offset)[,stack]]
stmt_clear:
    call b_args_uint
    cmp byte [B_ARGN+1], 0
    je .keep
    mov ax, [B_ARGS+2]
    cmp ax, VAR_START+100h
    jb err_func
    mov [B_STRTOP], ax
    call b_set_fbuf
.keep:
    call b_clear_vars
    mov sp, B_STACK
    jmp stmt_end

stmt_run:
    call b_skipsp
    cmp al, 0Eh
    je .num
    call b_at_end
    je .num
    mov al, 1                       ; RUN "file"
    jmp fs_load_program
.num:
    call fs_close_all
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
    call fs_close_all
    jmp basic_ready

; ERROR n
stmt_error:
    call b_eval_int
    test ax, ax
    jz err_func
    cmp ax, 255
    ja err_func
    jmp b_error

; RESUME [0 | NEXT | line]
stmt_resume:
    cmp byte [B_INERR], 0
    jne .ok
    mov al, E_RESUME
    jmp b_error
.ok:
    mov byte [B_INERR], 0
    call b_at_end
    je .retry
    cmp al, 10h                     ; RESUME 0
    jne .notzero
    inc si
    jmp .retry
.notzero:
    cmp al, T_NEXT
    je .next
    call b_get_target
    jmp b_goto_bx
.retry:
    mov bx, [B_ERRHDR]
    mov [B_CURLINE], bx
    mov ax, [bx+2]
    mov [CURLIN], ax
    mov si, [B_ERRSTMT]
    jmp stmt_next
.next:
    mov bx, [B_ERRHDR]
    mov [B_CURLINE], bx
    mov ax, [bx+2]
    mov [CURLIN], ax
    mov si, [B_ERRSTMT]
    ; skip the failed statement (token-aware)
.sk:
    mov al, [si]
    test al, al
    jz stmt_end
    cmp al, ':'
    je stmt_end
    cmp al, T_ELSE
    je stmt_end
    call b_tok_skip
    jmp .sk

; MID$(var$, p[, n]) = expr$: overwrite part of a string variable in place.
stmt_midassign:
    inc si                          ; 81h
    mov ah, '('
    call b_expect
    call b_getvar
    cmp al, VT_STR
    jne err_type
    push bx
    mov ah, ','
    call b_expect
    call b_eval_int
    test ax, ax
    jle err_func
    push ax
    mov ax, 255
    call b_skipsp
    cmp al, ','
    mov ax, 255
    jne .np
    inc si
    call b_eval_int
.np:
    push ax
    mov ah, ')'
    call b_expect
    mov ah, T_EQ
    call b_expect
    call b_eval_str                 ; CX, BX (FAC_SEG)
    pop dx                          ; n
    pop ax                          ; p
    pop di                          ; descriptor
    push si
    movzx si, byte [fs:di]          ; length of the variable's string
    dec ax
    cmp ax, si
    jae .bad
    sub si, ax                      ; room after p
    cmp cx, si
    jbe .c1
    mov cx, si
.c1:
    cmp cx, dx
    jbe .c2
    mov cx, dx
.c2:
    mov di, [fs:di+2]
    add di, ax
    mov si, bx
    push es
    push ds
    mov es, [B_VSEG]
    mov ds, [FAC_SEG]
    rep movsb
    pop ds
    pop es
    pop si
    jmp stmt_end
.bad:
    pop si
    jmp err_func

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
