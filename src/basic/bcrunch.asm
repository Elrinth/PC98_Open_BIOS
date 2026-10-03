; Tokeniser: ASCII statements -> N88-BASIC(86) program text.
;
; Format (docs/N88BASIC.md): keywords as tokens (functions FFh, token|80h),
; blank -> 01h, small integers 0-9 -> 10h-19h, 10-255 -> 0Fh nn, other
; integers -> 1Ch lo hi, &H -> 0Ch lo hi, &O -> 0Bh lo hi, line numbers after
; GOTO/GOSUB/THEN/ELSE... -> 0Eh lo hi, variables -> first letter, length of
; the rest, the rest, type character. Strings and DATA stay ASCII; ' and REM
; are stored as 00h followed by the comment text.

; DS:SI -> line, CX = length (0: up to the 0 terminator).
; Unnumbered: tokenise into DIRLINE as line FFFFh, CF clear.
; Numbered: store it in the program (delete it when empty), CF set.
b_crunch_direct:
    jcxz .term
    mov di, si
    add di, cx
    mov byte [di], 0                ; the module's autostart text is not terminated
.term:
    call b_skipsp_ascii
    cmp al, '0'
    jb .direct
    cmp al, '9'
    ja .direct
    call b_parse_uint               ; AX = line number
    jc err_syntax
    push ax
    mov di, DIRLINE+4
    call b_crunch
    pop ax
    mov [DIRLINE+2], ax
    sub di, DIRLINE
    mov [DIRLINE], di
    call b_store_line
    stc
    ret
.direct:
    mov di, DIRLINE+4
    call b_crunch
    mov word [DIRLINE+2], 0FFFFh
    sub di, DIRLINE
    mov [DIRLINE], di
    mov word [DIRLINE+di], 0        ; end marker after the direct line
    clc
    ret

b_skipsp_ascii:
    mov al, [si]
    cmp al, ' '
    jne .r
    inc si
    jmp b_skipsp_ascii
.r:
    ret

; Tokenise DS:SI (0-terminated) to ES:DI, append the 0 terminator.
; BP bit 0: line numbers follow (after GOTO, THEN, ...).
b_crunch:
    xor bp, bp
.next:
    lodsb
    test al, al
    jz .end
    cmp al, ' '
    jne .notblank
    mov al, 01h                     ; a run of 1-10 blanks is one byte
.blanks:
    cmp byte [si], ' '
    jne .blankend
    cmp al, 0Ah
    jae .blankend
    inc al
    inc si
    jmp .blanks
.blankend:
    stosb
    jmp .next
.notblank:
    cmp al, '"'
    jne .notstr
    stosb
.str:
    lodsb
    test al, al
    jz .end
    stosb
    cmp al, '"'
    jne .str
    jmp .next
.notstr:
    cmp al, 27h                     ; ' comment: 00h, then the text
    jne .notrem
    dec si
    jmp b_crunch_rawrest
.notrem:
    cmp al, '?'
    jne .notq
    mov al, T_PRINT
    stosb
    xor bp, bp
    jmp .next
.notq:
    cmp al, ':'
    jne .notcolon
    stosb
    xor bp, bp
    jmp .next
.notcolon:
    call b_upcase
    cmp al, 'A'
    jb .notalpha
    cmp al, 'Z'
    ja .notalpha
    dec si
    call b_crunch_word
    jc .end2                        ; REM copied the rest of the line
    jmp .next
.notalpha:
    cmp al, '0'
    jb .notdigit
    cmp al, '9'
    ja .notdigit
    dec si
    call b_parse_uint
    jc err_overflow
    test bp, 1
    jnz .linenum
    mov dl, [si]
    cmp dl, '.'
    je err_feature                  ; no floating point yet
    call b_store_int
    jmp .next
.linenum:
    push ax
    mov al, 0Eh
    stosb
    pop ax
    stosw
    jmp .next
.notdigit:
    cmp al, '&'
    jne .notamp
    call b_crunch_amp
    jmp .next
.notamp:
    mov bx, crunch_ops
.op:
    mov ah, [cs:bx]
    test ah, ah
    jz .plain
    cmp al, ah
    je .optok
    add bx, 2
    jmp .op
.optok:
    mov al, [cs:bx+1]
    and bp, ~1
.plain:
    stosb
    jmp .next
.end:
    stosb
.end2:
    ret

; 00h, then the rest of the line unchanged (comments).
b_crunch_rawrest:
    xor al, al
    stosb
.raw:
    lodsb
    stosb
    test al, al
    jnz .raw
    ret

crunch_ops:
    db '>', T_GT, '=', T_EQ, '<', T_LT, '+', T_PLUS, '-', T_MINUS
    db '*', T_MUL, '/', T_DIV, '^', T_POW, '\', T_IDIV, 0

; Keyword or variable at SI (a letter). CF set when REM consumed the line.
b_crunch_word:
    mov al, [si]
    call b_upcase
    movzx bx, al
    sub bx, 'A'
    shl bx, 1
    mov bx, [cs:kw_index+bx]
.entry:
    movzx cx, byte [cs:bx]
    test cx, cx
    jz .ident                       ; end of this letter's group
    push si
    inc si
    lea dx, [bx+1]
.cmp:
    mov al, [si]
    call b_upcase
    xchg bx, dx
    cmp al, [cs:bx]
    xchg bx, dx
    jne .nomatch
    inc si
    inc dx
    loop .cmp
    add sp, 2                       ; keyword matched, SI after it
    mov bx, dx
    mov al, [cs:bx]                 ; token
    mov ah, [cs:bx+1]               ; flags
    jmp .keyword
.nomatch:
    pop si
    movzx cx, byte [cs:bx]
    add bx, cx
    add bx, 3
    jmp .entry

.keyword:
    cmp al, T_REM
    jne .notrem
    sub si, 3                       ; keep "REM" in the comment text
    call b_crunch_rawrest
    stc
    ret
.notrem:
    test ah, KF_FUNC
    jz .stmt
    mov byte [es:di], 0FFh
    inc di
    or al, 80h
    stosb
    and bp, ~1
    clc
    ret
.stmt:
    test ah, KF_ELSE
    jz .noelse
    cmp byte [es:di-1], ':'
    je .noelse
    mov byte [es:di], ':'
    inc di
.noelse:
    stosb
    and bp, ~1
    test ah, KF_LINE
    jz .noline
    or bp, 1
.noline:
    test ah, KF_DATA
    jz .done
.data:                              ; DATA: text up to ':' outside quotes
    mov al, [si]
    test al, al
    jz .done
    cmp al, ':'
    je .done
    movsb
    cmp al, '"'
    jne .data
.dq:
    mov al, [si]
    test al, al
    jz .done
    movsb
    cmp al, '"'
    jne .dq
    jmp .data
.done:
    clc
    ret

.ident:                             ; variable: letter, count, rest, type
    lodsb
    call b_upcase
    stosb
    mov bx, di
    inc di
    xor cx, cx
.ic:
    mov al, [si]
    call b_upcase
    cmp al, '.'
    je .icok
    cmp al, '0'
    jb .icend
    cmp al, '9'
    jbe .icok
    cmp al, 'A'
    jb .icend
    cmp al, 'Z'
    ja .icend
.icok:
    stosb
    inc si
    inc cx
    jmp .ic
.icend:
    mov [es:bx], cl
    mov al, [si]
    cmp al, '$'
    je .type
    cmp al, '%'
    je .type
    cmp al, '!'
    je .type
    cmp al, '#'
    jne .notype
.type:
    movsb
.notype:
    and bp, ~1
    clc
    ret

; '&' seen (SI after it): &Hhex, &Ooctal or &octal.
b_crunch_amp:
    mov al, [si]
    call b_upcase
    cmp al, 'H'
    je .hex
    cmp al, 'O'
    je .oct1
    cmp al, '0'
    jb .plain
    cmp al, '7'
    ja .plain
    jmp .oct
.plain:
    mov al, '&'
    stosb
    ret
.oct1:
    inc si
.oct:
    xor dx, dx
.ol:
    mov al, [si]
    sub al, '0'
    cmp al, 7
    ja .od
    shl dx, 3
    or dl, al
    inc si
    jmp .ol
.od:
    mov al, 0Bh
    jmp .store
.hex:
    inc si
    xor dx, dx
.hl:
    mov al, [si]
    call b_upcase
    sub al, '0'
    cmp al, 9
    jbe .hd
    sub al, 'A'-'0'-10
    cmp al, 10
    jb .hdone
    cmp al, 15
    ja .hdone
.hd:
    shl dx, 4
    or dl, al
    inc si
    jmp .hl
.hdone:
    mov al, 0Ch
.store:
    stosb
    mov ax, dx
    stosw
    and bp, ~1
    ret

; AX = 0-65535 -> integer constant (0-9, 0Fh nn, 1Ch nnnn).
b_store_int:
    cmp ax, 9
    ja .byte
    add al, 10h
    stosb
    ret
.byte:
    cmp ax, 255
    ja .word
    mov ah, al
    mov al, 0Fh
    stosw
    ret
.word:
    cmp ax, 32767
    ja err_overflow
    push ax
    mov al, 1Ch
    stosb
    pop ax
    stosw
    ret

; Decimal digits at SI -> AX. CF set: no digit or more than 65535.
b_parse_uint:
    push bx
    xor ax, ax
    xor cx, cx
.d:
    movzx bx, byte [si]
    sub bl, '0'
    cmp bl, 9
    ja .end
    push bx
    mov bx, 10
    mul bx                          ; CF when the product needs DX
    pop bx
    jc .ovf
    add ax, bx
    jc .ovf
    inc si
    inc cx
    jmp .d
.end:
    pop bx
    cmp cx, 1
    ret                             ; CF set when CX = 0
.ovf:
    pop bx
    stc
    ret

b_upcase:
    cmp al, 'a'
    jb .r
    cmp al, 'z'
    ja .r
    sub al, 20h
.r:
    ret

; Store DIRLINE (line [DIRLINE+2]) in the program, replacing a line with the
; same number; a line without statements deletes it. Variables are cleared.
b_store_line:
    mov ax, [DIRLINE+2]
    mov bx, [TXTTAB]
.f:
    cmp word [bx], 0
    je .at
    cmp [bx+2], ax
    jae .at
    add bx, [bx]
    jmp .f
.at:
    cmp word [bx], 0
    je .ins
    cmp [bx+2], ax
    jne .ins
    mov dx, [bx]                    ; delete the old line
    mov si, bx
    add si, dx
    mov di, bx
    mov cx, [PRGEND]
    sub cx, si
    rep movsb
    sub [PRGEND], dx
.ins:
    mov si, DIRLINE+4
.blank:
    lodsb
    test al, al
    jz .done                        ; nothing but the number: deleted
    cmp al, 0Ah
    jbe .blank
    mov dx, [DIRLINE]
    mov ax, [PRGEND]
    add ax, dx
    jc err_memory
    cmp ax, TEXT_LIMIT
    jae err_memory
    mov cx, [PRGEND]
    sub cx, bx
    mov si, [PRGEND]
    dec si
    mov di, si
    add di, dx
    std
    rep movsb
    cld
    mov si, DIRLINE
    mov di, bx
    mov cx, dx
    rep movsb
    add [PRGEND], dx
.done:
    jmp b_clear_vars
