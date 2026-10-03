; Expression evaluation: FAC = value of the expression at SI.
; Numbers are 16-bit integers for now (floating point is a later step);
; constants and variables that need it raise "Feature not available".

P_IMP           equ 1
P_EQV           equ 2
P_XOR           equ 3
P_OR            equ 4
P_AND           equ 5
P_NOT           equ 6
P_REL           equ 7
P_ADD           equ 8
P_MOD           equ 9
P_IDIV          equ 10
P_MUL           equ 11
P_NEG           equ 12
P_POW           equ 13

OP_IMP          equ 0
OP_EQV          equ 1
OP_XOR          equ 2
OP_OR           equ 3
OP_AND          equ 4
OP_ADD          equ 5
OP_SUB          equ 6
OP_MOD          equ 7
OP_IDIV         equ 8
OP_MUL          equ 9
OP_DIV          equ 10
OP_POW          equ 11
OP_REL          equ 10h             ; | mask: 1 '<', 2 '=', 4 '>'

b_eval:
    mov dl, P_IMP
eval_prec:                          ; DL = lowest precedence to accept
    push dx
    call eval_unary
    pop dx
.loop:
    call b_skipsp
    call op_info                    ; AL = op, AH = precedence, CX = length
    jc .done
    cmp ah, dl
    jb .done
    add si, cx
    push dx
    push ax
    cmp byte [FAC_TYPE], VT_STR
    jne .lint
    call tstk_push
    push word 0
    push word VT_STR
    jmp .right
.lint:
    push word [FAC_I]
    push word VT_INT
.right:
    mov dl, ah
    inc dl
    call eval_prec
    pop cx                          ; left type
    pop bx                          ; left integer
    pop ax                          ; operator
    pop dx
    call apply_op
    jmp .loop
.done:
    ret

; Operator at SI (AL = [SI]): CF clear and AL = op, AH = precedence,
; CX = bytes, or CF set.
op_info:
    mov cx, 1
    cmp al, T_GT
    jb .no
    cmp al, T_LT
    jbe .rel
    push bx
    mov bx, op_table
.f:
    cmp byte [cs:bx], 0
    je .nf
    cmp al, [cs:bx]
    je .hit
    add bx, 3
    jmp .f
.hit:
    mov ax, [cs:bx+1]
    pop bx
    clc
    ret
.nf:
    pop bx
.no:
    stc
    ret
.rel:
    call .relbit
    mov ah, al
    mov al, [si+1]
    cmp al, T_GT
    jb .rel1
    cmp al, T_LT
    ja .rel1
    call .relbit
    or ah, al
    inc cx
.rel1:
    mov al, ah
    or al, OP_REL
    mov ah, P_REL
    clc
    ret
.relbit:                            ; F0h '>' 4, F1h '=' 2, F2h '<' 1
    sub al, T_GT
    mov ah, 4
    jz .rb
    mov ah, 2
    dec al
    jz .rb
    mov ah, 1
.rb:
    mov al, ah
    ret

op_table:
    db T_IMP, OP_IMP, P_IMP
    db T_EQV, OP_EQV, P_EQV
    db T_XOR, OP_XOR, P_XOR
    db T_OR, OP_OR, P_OR
    db T_AND, OP_AND, P_AND
    db T_PLUS, OP_ADD, P_ADD
    db T_MINUS, OP_SUB, P_ADD
    db T_MOD, OP_MOD, P_MOD
    db T_IDIV, OP_IDIV, P_IDIV
    db T_MUL, OP_MUL, P_MUL
    db T_DIV, OP_DIV, P_MUL
    db T_POW, OP_POW, P_POW
    db 0

; AL = op, CX = left type (BX = left integer, or left string on TSTK),
; FAC = right operand -> FAC = result.
apply_op:
    cmp cx, VT_STR
    jne .numeric
    cmp byte [FAC_TYPE], VT_STR
    jne err_type
    cmp al, OP_ADD
    je str_concat
    test al, OP_REL
    jnz str_compare
    jmp err_type
.numeric:
    cmp byte [FAC_TYPE], VT_INT
    jne err_type
    mov dx, [FAC_I]                 ; right
    test al, OP_REL
    jnz .rel
    movzx di, al
    shl di, 1
    jmp [cs:int_ops+di]
.rel:
    mov ah, 1
    cmp bx, dx
    jl .rset
    mov ah, 2
    je .rset
    mov ah, 4
.rset:
    and al, ah
    jmp fac_bool

int_ops:
    dw .imp, .eqv, .xor, .or, .and, .add, .sub, .mod, .idiv, .mul, .div, .pow
.imp:
    not bx
    or bx, dx
    jmp .bx
.eqv:
    xor bx, dx
    not bx
    jmp .bx
.xor:
    xor bx, dx
    jmp .bx
.or:
    or bx, dx
    jmp .bx
.and:
    and bx, dx
    jmp .bx
.add:
    add bx, dx
    jo err_overflow
    jmp .bx
.sub:
    sub bx, dx
    jo err_overflow
    jmp .bx
.mul:
    mov ax, bx
    imul dx
    jo err_overflow
    mov bx, ax
    jmp .bx
.idiv:
    call .divide
    mov bx, ax
    jmp .bx
.mod:
    call .divide
    mov bx, dx
    jmp .bx
.div:
    call .divide
    test dx, dx
    jnz err_feature                 ; fractional result needs floating point
    mov bx, ax
    jmp .bx
.divide:                            ; BX / DX -> AX quotient, DX remainder
    test dx, dx
    jz err_div0
    mov cx, dx
    mov ax, bx
    cmp ax, 8000h
    jne .dok
    cmp cx, -1
    je err_overflow
.dok:
    cwd
    idiv cx
    ret
.pow:
    test dx, dx
    js err_feature
    mov cx, dx
    mov ax, 1
    jcxz .pw2
.pw:
    imul bx
    jo err_overflow
    loop .pw
.pw2:
    mov bx, ax
.bx:
    mov [FAC_I], bx
    mov byte [FAC_TYPE], VT_INT
    ret

; FAC = -1 when AL is non-zero, else 0.
fac_bool:
    xor bx, bx
    test al, al
    jz .s
    dec bx
.s:
    mov [FAC_I], bx
    mov byte [FAC_TYPE], VT_INT
    ret

; left (TSTK top) + right (FAC) -> FAC = new string
str_concat:
    push si
    call tstk_top                   ; BX -> left descriptor
    movzx cx, byte [bx]
    add cx, [FAC_I]
    cmp cx, 255
    ja .long
    call b_stralloc                 ; DI (descriptors updated if moved)
    push di
    push es
    mov es, [B_VSEG]
    call tstk_top
    movzx cx, byte [bx]
    mov si, [bx+2]
    push ds
    mov ds, [bx+4]
    rep movsb
    pop ds
    mov cx, [FAC_I]
    mov si, [FAC_P]
    push ds
    mov ds, [FAC_SEG]
    rep movsb
    pop ds
    pop es
    pop ax                          ; start
    sub di, ax
    mov [FAC_I], di
    mov [FAC_P], ax
    mov ax, [B_VSEG]
    mov [FAC_SEG], ax
    dec word [B_TSP]
    pop si
    ret
.long:
    mov al, E_STRLONG
    jmp b_error

; Compare left (TSTK top) with right (FAC); AL = OP_REL | mask.
str_compare:
    push si
    push ax
    call tstk_top
    movzx cx, byte [bx]             ; left length
    mov dx, [FAC_I]                 ; right length
    mov si, [bx+2]
    mov di, [FAC_P]
    mov ax, [bx+4]                  ; left segment
    push es
    mov es, [FAC_SEG]
    dec word [B_TSP]
    mov bx, cx
    cmp bx, dx
    jbe .min
    mov bx, dx
.min:
    xchg cx, bx                     ; CX = common length, BX = left length
    jcxz .lens
    push ds
    mov ds, ax
    repe cmpsb
    pop ds
    jne .diff
.lens:
    cmp bx, dx
.diff:
    pop es
    mov ah, 1
    jb .set
    mov ah, 2
    je .set
    mov ah, 4
.set:
    pop cx
    mov al, cl
    and al, ah
    pop si
    jmp fac_bool

; ---------------------------------------------------------------- operands
eval_unary:
    call b_skipsp
    cmp al, T_MINUS
    jne .notneg
    inc si
    mov dl, P_NEG
    call eval_prec
    call fac_int
    neg ax
    jo err_overflow
    mov [FAC_I], ax
    ret
.notneg:
    cmp al, T_PLUS
    jne .notplus
    inc si
    mov dl, P_NEG
    jmp eval_prec
.notplus:
    cmp al, T_NOT
    jne eval_atom
    inc si
    mov dl, P_REL
    call eval_prec
    call fac_int
    not ax
    mov [FAC_I], ax
    ret

eval_atom:
    call b_skipsp
    inc si
    cmp al, 10h
    jb .not_small
    cmp al, 19h
    ja .not_small
    sub al, 10h
    cbw
    jmp fac_set_int
.not_small:
    cmp al, 0Fh
    jne .not_byte
    lodsb
    xor ah, ah
    jmp fac_set_int
.not_byte:
    cmp al, 1Ch
    je .word
    cmp al, 0Ch
    je .word
    cmp al, 0Bh
    je .word
    cmp al, 0Eh
    jne .not_word
.word:
    lodsw
    jmp fac_set_int
.not_word:
    cmp al, 1Dh
    je mbf4_const
    cmp al, 1Fh
    je err_feature
    cmp al, '"'
    je .literal
    cmp al, '('
    jne .not_paren
    call b_eval
    mov ah, ')'
    jmp b_expect
.not_paren:
    cmp al, 'A'
    jb .not_var
    cmp al, 'Z'
    ja .not_var
    dec si
    call b_getvar
    cmp al, VT_STR
    je .strvar
    mov ax, [fs:bx]
    jmp fac_set_int
.strvar:
    movzx ax, byte [fs:bx]
    mov [FAC_I], ax
    mov ax, [fs:bx+2]
    mov [FAC_P], ax
    mov ax, [B_VSEG]
    mov [FAC_SEG], ax
    mov byte [FAC_TYPE], VT_STR
    ret
.not_var:
    cmp al, 0FFh
    je eval_function
    cmp al, T_USR
    je eval_usr
    jmp err_syntax
.literal:
    mov [FAC_P], si
    xor cx, cx
.lit:
    mov al, [si]
    test al, al
    jz .litend
    inc si
    cmp al, '"'
    je .litend
    inc cx
    jmp .lit
.litend:
    mov [FAC_I], cx
    mov [FAC_SEG], ds
    mov byte [FAC_TYPE], VT_STR
    ret

fac_set_int:
    mov [FAC_I], ax
    mov byte [FAC_TYPE], VT_INT
    ret

; FAC must be an integer: AX = value.
fac_int:
    cmp byte [FAC_TYPE], VT_INT
    jne err_type
    mov ax, [FAC_I]
    ret

; Single-precision constant (Microsoft binary format) that is an integer.
mbf4_const:
    lodsw                           ; mantissa low, mid
    mov dx, ax
    lodsw                           ; AL = mantissa high (bit 7 sign), AH = exponent
    test ah, ah
    jz .zero
    mov bl, al                      ; sign
    or al, 80h
    movzx eax, al
    shl eax, 16
    mov ax, dx                      ; EAX = 24-bit mantissa
    mov cl, 152
    sub cl, [si-1]                  ; shift = 152 - exponent
    jbe err_overflow
    cmp cl, 24
    ja err_feature                  ; |x| < 1
    mov edx, eax
    shr eax, cl
    shl eax, cl
    cmp eax, edx
    jne err_feature                 ; fraction
    shr eax, cl
    cmp eax, 32768
    ja err_overflow
    test bl, 80h
    jz .pos
    neg eax
    jmp fac_set_int
.pos:
    cmp eax, 32767
    ja err_overflow
    jmp fac_set_int
.zero:
    xor ax, ax
    jmp fac_set_int

; Evaluate an integer expression: AX.
b_eval_int:
    call b_eval
    jmp fac_int

; Evaluate a string expression: CX = length, BX = pointer (FAC).
b_eval_str:
    call b_eval
    cmp byte [FAC_TYPE], VT_STR
    jne err_type
    mov cx, [FAC_I]
    mov bx, [FAC_P]
    ret

; ---------------------------------------------------------------- temporaries
tstk_push:
    push ax
    push bx
    mov bx, [B_TSP]
    cmp bx, B_TSTK_N
    jae .full
    inc word [B_TSP]
    imul bx, bx, 6
    add bx, B_TSTK
    mov al, [FAC_I]
    mov [bx], al
    mov byte [bx+1], 0
    mov ax, [FAC_P]
    mov [bx+2], ax
    mov ax, [FAC_SEG]
    mov [bx+4], ax
    pop bx
    pop ax
    ret
.full:
    mov al, E_COMPLEX
    jmp b_error

; BX -> top temporary descriptor.
tstk_top:
    mov bx, [B_TSP]
    dec bx
    imul bx, bx, 6
    add bx, B_TSTK
    ret

; ---------------------------------------------------------------- functions
eval_function:
    lodsb
    and al, 7Fh
    mov bx, func_table
.f:
    cmp byte [cs:bx], 0FFh
    je err_feature
    cmp al, [cs:bx]
    je .hit
    add bx, 3
    jmp .f
.hit:
    jmp [cs:bx+1]

func_table:
    db F_ABS
    dw fn_abs
    db F_SGN
    dw fn_sgn
    db F_INT
    dw fn_ident
    db F_FIX
    dw fn_ident
    db F_CINT
    dw fn_ident
    db F_ASC
    dw fn_asc
    db F_LEN
    dw fn_len
    db F_CHR_S
    dw fn_chr
    db F_STR_S
    dw fn_str
    db F_HEX_S
    dw fn_hex
    db F_VAL
    dw fn_val
    db F_LEFT_S
    dw fn_left
    db F_RIGHT_S
    dw fn_right
    db F_MID_S
    dw fn_mid
    db F_SPACE_S
    dw fn_space
    db F_PEEK
    dw fn_peek
    db F_INP
    dw fn_inp
    db F_VARPTR
    dw fn_varptr
    db F_INKEY_S
    dw fn_inkey
    db F_CSRLIN
    dw fn_csrlin
    db F_POS
    dw fn_pos
    db F_FRE
    dw fn_fre
    db 0FFh

; '(' integer ')' -> AX
fn_arg_int:
    mov ah, '('
    call b_expect
    call b_eval_int
fn_close:
    push ax
    mov ah, ')'
    call b_expect
    pop ax
    ret

fn_ident:
    call fn_arg_int
    jmp fac_set_int
fn_abs:
    call fn_arg_int
    test ax, ax
    jns fac_set_int
    neg ax
    jo err_overflow
    jmp fac_set_int
fn_sgn:
    call fn_arg_int
    test ax, ax
    jz fac_set_int
    mov ax, 1
    jg fac_set_int
    neg ax
    jmp fac_set_int
fn_peek:
    call fn_arg_int
    push es
    mov es, [B_DEFSEG]
    mov bx, ax
    movzx ax, byte [es:bx]
    pop es
    jmp fac_set_int
fn_inp:
    call fn_arg_int
    mov dx, ax
    in al, dx
    xor ah, ah
    jmp fac_set_int
fn_fre:
    mov ah, '('
    call b_expect
    call b_eval
    mov ah, ')'
    call b_expect
    mov ax, [B_FRETOP]
    sub ax, [B_VAREND]
    jmp fac_set_int
fn_csrlin:
    movzx ax, byte [B_CSRY]
    jmp fac_set_int
fn_pos:
    call fn_arg_int
    movzx ax, byte [B_CSRX]
    jmp fac_set_int

; '(' string ')' -> CX length, BX pointer
fn_arg_str:
    mov ah, '('
    call b_expect
    call b_eval_str
    push cx
    mov ah, ')'
    call b_expect
    pop cx
    ret
fn_len:
    call fn_arg_str
    mov ax, cx
    jmp fac_set_int
fn_asc:
    call fn_arg_str
    test cx, cx
    jz err_func
    push es
    mov es, [FAC_SEG]
    movzx ax, byte [es:bx]
    pop es
    jmp fac_set_int
fn_val:
    call fn_arg_str
    push si
    push ds
    mov si, bx
    mov ds, [FAC_SEG]
    call b_val_text
    pop ds
    pop si
    jmp fac_set_int

; Text at SI (CX bytes) -> AX: blanks, sign, decimal or &H digits.
b_val_text:
    xor ax, ax
    xor dx, dx                      ; sign
.sp:
    jcxz .r
    cmp byte [si], ' '
    jne .sg
    inc si
    dec cx
    jmp .sp
.sg:
    cmp byte [si], '-'
    jne .plus
    inc dx
    jmp .skip1
.plus:
    cmp byte [si], '+'
    jne .amp
.skip1:
    inc si
    dec cx
.amp:
    jcxz .r
    cmp byte [si], '&'
    jne .dec
    cmp cx, 2
    jb .r
    mov bl, [si+1]
    or bl, 20h
    cmp bl, 'h'
    jne .r
    add si, 2
    sub cx, 2
.hex:
    jcxz .r
    mov bl, [si]
    or bl, 20h
    sub bl, '0'
    cmp bl, 9
    jbe .hd
    sub bl, 'a'-'0'-10
    cmp bl, 10
    jb .r
    cmp bl, 15
    ja .r
.hd:
    shl ax, 4
    or al, bl
    inc si
    dec cx
    jmp .hex
.dec:
    jcxz .r
    movzx bx, byte [si]
    sub bl, '0'
    cmp bl, 9
    ja .r
    imul ax, ax, 10
    jo err_overflow
    add ax, bx
    jo err_overflow
    inc si
    dec cx
    jmp .dec
.r:
    test dx, dx
    jz .done
    neg ax
.done:
    ret

; New string of CX bytes -> DI, ES = VSEG (FAC set to it; the statement
; loop restores ES).
fn_newstr:
    call b_stralloc
    mov [FAC_P], di
    mov [FAC_I], cx
    mov es, [B_VSEG]
    mov [FAC_SEG], es
    mov byte [FAC_TYPE], VT_STR
    ret

fn_chr:
    call fn_arg_int
    cmp ax, 255
    ja err_func
    push ax
    mov cx, 1
    call fn_newstr
    pop ax
    stosb
    jmp b_ds_es
fn_space:
    call fn_arg_int
    cmp ax, 255
    ja err_func
    mov cx, ax
    call fn_newstr
    mov al, ' '
    rep stosb
    jmp b_ds_es
fn_str:
    call fn_arg_int
    call b_fmt_int                  ; BX, CX
fn_copy_buf:                        ; FAC = copy of BX/CX (BSEG)
    push si
    push cx
    push bx
    call fn_newstr
    pop si
    pop cx
    rep movsb
    pop si
    jmp b_ds_es
fn_hex:
    call fn_arg_int
    mov bx, B_NUMBUF+8
    xor cx, cx
.h:
    dec bx
    inc cx
    mov dl, al
    and dl, 0Fh
    add dl, '0'
    cmp dl, '9'
    jbe .hd
    add dl, 7
.hd:
    mov [bx], dl
    shr ax, 4
    jnz .h
    jmp fn_copy_buf

; LEFT$(s$,n) / RIGHT$(s$,n) / MID$(s$,p[,n])
fn_strn_args:                       ; '(' string ',' int -> TSTK top string, AX
    mov ah, '('
    call b_expect
    call b_eval_str
    call tstk_push
    mov ah, ','
    call b_expect
    jmp b_eval_int
fn_left:
    call fn_strn_args
    call fn_close
    xor dx, dx                      ; start
    jmp fn_substr
fn_right:
    call fn_strn_args
    call fn_close
    call tstk_top
    movzx dx, byte [bx]
    sub dx, ax
    jae fn_substr
    xor dx, dx
    jmp fn_substr
fn_mid:
    call fn_strn_args               ; AX = position (1-based)
    test ax, ax
    jle err_func
    dec ax
    push ax
    mov ax, 255
    call b_skipsp
    cmp al, ','
    mov ax, 255
    jne .all
    inc si
    call b_eval_int
.all:
    call fn_close
    pop dx
; TSTK top = source, DX = start, AX = count -> FAC = substring
fn_substr:
    test ax, ax
    js err_func
    call tstk_top
    movzx cx, byte [bx]
    cmp dx, cx
    jb .in
    mov dx, cx
.in:
    sub cx, dx                      ; available from start
    cmp ax, cx
    jae .n
    mov cx, ax
.n:
    push si
    push dx
    push cx
    call fn_newstr                  ; may move the source; TSTK is updated
    pop cx
    pop dx
    call tstk_top
    mov si, [bx+2]
    add si, dx
    push ds
    mov ds, [bx+4]
    rep movsb
    pop ds
    dec word [B_TSP]
    pop si
    jmp b_ds_es

; VARPTR(var[,1]): value address, or with ,1 the segment.
fn_varptr:
    mov ah, '('
    call b_expect
    call b_getvar
    mov ax, bx
    push ax
    call b_skipsp
    cmp al, ','
    jne .off
    inc si
    call b_eval_int
    test ax, ax
    jz .off
    pop ax
    push word [B_VSEG]
.off:
    mov ah, ')'
    call b_expect
    pop ax
    jmp fac_set_int

; INKEY$: next key without waiting, "" when none.
fn_inkey:
    mov ah, 05h
    int 18h
    test bh, bh
    jz .none
    push ax
    mov cx, 1
    call fn_newstr
    pop ax
    stosb
    jmp b_ds_es
.none:
    mov word [FAC_I], 0
    mov [FAC_P], si
    mov [FAC_SEG], ds
    mov byte [FAC_TYPE], VT_STR
    ret

; USR[n](arg): call the machine-code routine set by DEF USRn through INT C3h.
eval_usr:
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
    mov ah, '('
    call b_expect
    call b_eval
    mov ah, ')'
    call b_expect
    pop bx
    shl bx, 2
    add bx, USRTAB
    mov ax, [bx]
    mov dx, [bx+2]
    call b_call_c3                  ; DX:AX, BX -> FAC
    ret

b_usr_unset:
    iret
