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
    push word 0
    push word VT_STR
    jmp .right
.lint:
    push word [FAC_P]               ; high word of a single
    push word [FAC_I]
    movzx bx, byte [FAC_TYPE]
    push bx
.right:
    mov dl, ah
    inc dl
    call eval_prec
    pop cx                          ; left type
    pop bx                          ; left value, low word
    pop word [B_LEFTHI]             ; high word
    pop ax                          ; operator
    pop dx
    push dx                         ; apply_op uses DX; DL = our precedence
    call apply_op
    pop dx
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
    cmp byte [FAC_TYPE], VT_STR
    je err_type
    test al, OP_REL
    jnz .rel
    cmp al, OP_AND
    jbe .intonly                    ; IMP EQV XOR OR AND
    cmp al, OP_MOD
    je .intonly
    cmp al, OP_IDIV
    je .intonly
    cmp al, OP_DIV
    je f_binop
    cmp al, OP_POW
    je f_binop
    cmp cx, VT_INT                  ; + - *: integers unless they overflow
    jne f_binop
    cmp byte [FAC_TYPE], VT_INT
    jne f_binop
    mov [B_LEFTLO], bx
    mov dx, [FAC_I]
    movzx di, al
    shl di, 1
    jmp [cs:int_ops+di]
.intonly:
    push ax
    cmp cx, VT_INT
    je .li
    mov ax, [B_LEFTHI]
    shl eax, 16
    mov ax, bx
    call f_to_int
    mov bx, ax
.li:
    call fac_int
    mov dx, ax
    pop ax
    movzx di, al
    shl di, 1
    jmp [cs:int_ops+di]
.rel:
    cmp cx, VT_INT
    jne .frel
    cmp byte [FAC_TYPE], VT_INT
    jne .frel
    mov dx, [FAC_I]
    mov ah, 1
    cmp bx, dx
    jl .rset
    mov ah, 2
    je .rset
    mov ah, 4
.rset:
    and al, ah
    jmp fac_bool
.frel:
    push ax
    call f_operands                 ; EAX = left, EBX = right
    call f_cmp
    pop ax
    and al, dh
    jmp fac_bool

int_ops:
    dw .imp, .eqv, .xor, .or, .and, .add, .sub, .mod, .idiv, .mul, f_binop, f_binop
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
    jo .ovf
    jmp .bx
.sub:
    sub bx, dx
    jo .ovf
    jmp .bx
.mul:
    push ax
    mov ax, bx
    imul dx
    mov bx, ax
    pop ax
    jo .ovf
    jmp .bx
.ovf:                               ; integer overflow: in single precision
    mov bx, [B_LEFTLO]
    mov cx, VT_INT
    jmp f_binop
.idiv:
    call .divide
    mov bx, ax
    jmp .bx
.mod:
    call .divide
    mov bx, dx
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
.bx:
    mov [FAC_I], bx
    mov byte [FAC_TYPE], VT_INT
    ret

; Left operand (CX type, BX low, B_LEFTHI high) and FAC -> EAX, EBX singles.
f_operands:
    cmp cx, VT_INT
    jne .lf
    mov ax, bx
    call f_from_int
    jmp .r
.lf:
    mov ax, [B_LEFTHI]
    shl eax, 16
    mov ax, bx
.r:
    push eax
    call fac_sng
    mov ebx, eax
    pop eax
    ret

; FAC (number) -> EAX single.
fac_sng:
    cmp byte [FAC_TYPE], VT_INT
    jne .s
    mov ax, [FAC_I]
    jmp f_from_int
.s:
    cmp byte [FAC_TYPE], VT_STR
    je err_type
    mov eax, [FAC_I]
    ret

; FAC = EAX (single)
fac_set_sng:
    mov [FAC_I], eax
    mov byte [FAC_TYPE], VT_SNG
    ret

; + - * / ^ in single precision: AL = op, left in CX/BX/B_LEFTHI, FAC right.
f_binop:
    push ax
    call f_operands
    pop dx
    cmp dl, OP_ADD
    je .add
    cmp dl, OP_SUB
    je .sub
    cmp dl, OP_MUL
    je .mul
    cmp dl, OP_DIV
    je .div
    ; ^: integer exponents only
    push eax
    mov eax, ebx
    call f_split
    jc .bad
    test edx, edx
    jnz .bad
    cmp eax, 32767
    jg .bad
    cmp eax, -32768
    jl .bad
    mov bx, ax
    pop eax
    call f_pow_int
    jmp fac_set_sng
.bad:
    pop eax
    jmp err_feature
.add:
    call f_add
    jmp fac_set_sng
.sub:
    call f_sub
    jmp fac_set_sng
.mul:
    call f_mul
    jmp fac_set_sng
.div:
    call f_div
    jmp fac_set_sng

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
    cmp byte [FAC_TYPE], VT_INT
    jne .fneg
    mov ax, [FAC_I]
    neg ax
    jo .ineg
    mov [FAC_I], ax
    ret
.ineg:                              ; -(-32768): single 32768
    mov ax, [FAC_I]
    call f_from_int
.fneg:
    call fac_sng
    call f_neg
    jmp fac_set_sng
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
    je .sng
    cmp al, 1Fh
    je .dbl
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
    cmp al, VT_INT
    je .ivar
    cmp al, VT_DBL
    jne .svar
    mov eax, [fs:bx+4]
    jmp fac_set_sng
.svar:
    mov eax, [fs:bx]
    jmp fac_set_sng
.ivar:
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
    cmp al, T_FN
    je eval_fn
    jmp err_syntax
.sng:
    lodsd
    jmp fac_set_sng
.dbl:
    add si, 4
    lodsd                           ; high half of the double: single layout
    jmp fac_set_sng
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

; FAC must be a number: AX = its value as an integer (singles rounded).
fac_int:
    cmp byte [FAC_TYPE], VT_INT
    je .i
    cmp byte [FAC_TYPE], VT_STR
    je err_type
    mov eax, [FAC_I]
    jmp f_to_int
.i:
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

; FAC -> AX as an address or other unsigned 16-bit value (-32768..65535).
fac_uint:
    cmp byte [FAC_TYPE], VT_INT
    jne .f
    mov ax, [FAC_I]
    ret
.f:
    cmp byte [FAC_TYPE], VT_STR
    je err_type
    push edx
    mov eax, [FAC_I]
    call f_split
    jc err_overflow
    test edx, 80000000h             ; round
    jz .nr
    inc eax
.nr:
    cmp eax, 65535
    jg err_overflow
    cmp eax, -32768
    jl err_overflow
    pop edx
    ret

; Evaluate an address-like expression: AX (0-65535).
b_eval_uint:
    call b_eval
    jmp fac_uint

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
    dw fn_int
    db F_FIX
    dw fn_fix
    db F_CINT
    dw fn_cint
    db F_CSNG
    dw fn_csng
    db F_CDBL
    dw fn_csng
    db F_RND
    dw fn_rnd
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
    db F_POINT
    dw fn_point
    db F_DSKI_S
    dw fn_dski
    db F_STRING_S
    dw fn_string
    db F_INKEY_S
    dw fn_inkey
    db F_CSRLIN
    dw fn_csrlin
    db F_POS
    dw fn_pos
    db F_FRE
    dw fn_fre
    db F_CVI
    dw fn_cvi
    db F_INSTR
    dw fn_instr
    db F_INPUT_S
    dw fn_input
    db F_ERR
    dw fn_err
    db F_ERL
    dw fn_erl
    db F_MKI_S
    dw fn_mki
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

; '(' number ')' -> FAC
fn_arg_num:
    mov ah, '('
    call b_expect
    call b_eval
    cmp byte [FAC_TYPE], VT_STR
    je err_type
    mov ah, ')'
    jmp b_expect

fn_int:
    call fn_arg_num
    cmp byte [FAC_TYPE], VT_INT
    je .r
    mov eax, [FAC_I]
    call f_floor
    jmp fac_set_sng
.r:
    ret
fn_fix:
    call fn_arg_num
    cmp byte [FAC_TYPE], VT_INT
    je .r
    mov eax, [FAC_I]
    call f_fix
    jmp fac_set_sng
.r:
    ret
fn_cint:
    call fn_arg_int
    jmp fac_set_int
fn_csng:
    call fn_arg_num
    call fac_sng
    jmp fac_set_sng
; RND / RND(x)
fn_rnd:
    call b_skipsp
    cmp al, '('
    mov eax, F_ONE
    jne .go
    call fn_arg_num
    call fac_sng
.go:
    call f_rnd
    jmp fac_set_sng
fn_abs:
    call fn_arg_num
    cmp byte [FAC_TYPE], VT_INT
    jne .f
    mov ax, [FAC_I]
    test ax, ax
    jns fac_set_int
    neg ax
    jno fac_set_int
    call f_from_int
    and eax, 0FF7FFFFFh
    jmp fac_set_sng
.f:
    and dword [FAC_I], 0FF7FFFFFh
    ret
fn_sgn:
    call fn_arg_num
    call fac_sng
    xor bx, bx
    test eax, 0FF000000h
    jz .z
    inc bx
    test eax, 800000h
    jz .z
    neg bx
.z:
    mov ax, bx
    test ax, ax
    jz fac_set_int
    mov ax, 1
    jg fac_set_int
    neg ax
    jmp fac_set_int
fn_peek:
    call fn_arg_num
    call fac_uint
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
    call b_garbage
    mov ax, [B_FRETOP]
    sub ax, [B_ADEND]
    movzx eax, ax
    call f_from_int32
    jmp fac_set_sng
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
    call b_val_fac
    pop ds
    pop si
    ret

; Text at DS:SI (CX bytes, DS may be another segment) -> FAC number.
; Returns with DS = BSEG.
b_val_fac:
    push es
    push ss
    pop es
    mov di, B_VALBUF
    cmp cx, 40
    jbe .c
    mov cx, 40
.c:
    push cx
    rep movsb
    pop cx
    pop es
    push ss
    pop ds
    mov si, B_VALBUF
    ; &H / &O: the integer reader
    push si
    push cx
.sp:
    test cx, cx
    jz .dec
    mov al, [si]
    cmp al, ' '
    je .nx
    cmp al, '-'
    je .nx
    cmp al, '+'
    je .nx
    cmp al, '&'
    jne .dec
    pop cx
    pop si
    call b_val_text
    jmp fac_set_int
.nx:
    inc si
    dec cx
    jmp .sp
.dec:
    pop cx
    pop si
    jmp f_parse

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
; STRING$(n, x$ | code)
fn_string:
    mov ah, '('
    call b_expect
    call b_eval_int
    cmp ax, 255
    ja err_func
    push ax
    mov ah, ','
    call b_expect
    call b_eval
    cmp byte [FAC_TYPE], VT_STR
    jne .code
    cmp word [FAC_I], 0
    je err_func
    push es
    mov es, [FAC_SEG]
    mov bx, [FAC_P]
    mov al, [es:bx]
    pop es
    jmp .ch
.code:
    call fac_int
.ch:
    push ax
    mov ah, ')'
    call b_expect
    pop ax
    pop cx
    push ax
    call fn_newstr
    pop ax
    rep stosb
    jmp b_ds_es
fn_str:
    call fn_arg_num
    call b_fmt_fac                  ; BX, CX
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
    mov ax, [B_VSEG]
    cmp byte [B_ISARR], 0
    je .simple
    ; array element: segment of the array's data, offset within it (N88)
    mov dx, [B_ARRBASE]
    sub bx, dx
    shr dx, 4
    add ax, dx
.simple:
    push bx
    push ax
    call b_skipsp
    cmp al, ','
    jne .off
    inc si
    call b_eval_int
    test ax, ax
    jz .off
    pop ax
    pop bx
    push ax
    jmp .r
.off:
    pop ax
.r:
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
    ; A lone string variable is passed as itself (NEC: the routine gets
    ; the variable's own descriptor and may replace the string in it).
    mov word [B_USRVAR], 0
    call b_skipsp
    cmp al, 'A'
    jb .expr
    cmp al, 'Z'
    ja .expr
    push si
    call b_parse_name               ; AH = type, SI after the name
    call b_skipsp
    pop si
    cmp ah, VT_STR
    jne .expr
    cmp al, ')'
    jne .expr
    call b_getvar                   ; BX -> descriptor (VSEG)
    mov [B_USRVAR], bx
    movzx ax, byte [fs:bx]
    mov [FAC_I], ax
    mov ax, [fs:bx+2]
    mov [FAC_P], ax
    mov ax, [B_VSEG]
    mov [FAC_SEG], ax
    mov byte [FAC_TYPE], VT_STR
    jmp .close
.expr:
    call b_eval
.close:
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

; INSTR([n,] a$, b$): position of b$ in a$ from n (1-based), 0 if none.
fn_instr:
    mov ah, '('
    call b_expect
    call b_eval
    mov dx, 1
    cmp byte [FAC_TYPE], VT_STR
    je .str
    call fac_int
    test ax, ax
    jle err_func
    mov dx, ax
    push dx
    mov ah, ','
    call b_expect
    call b_eval_str
    pop dx
.str:
    push dx
    call tstk_push                  ; a$
    mov ah, ','
    call b_expect
    call b_eval_str                 ; b$ in FAC
    mov ah, ')'
    call b_expect
    pop dx                          ; start
    push si
    call tstk_top
    movzx cx, byte [bx]             ; length of a$
    mov di, [bx+2]
    mov ax, [bx+4]
    mov [B_ISEG], ax
    dec word [B_TSP]
    mov bx, [FAC_I]                 ; length of b$
    xor ax, ax
    cmp dx, cx
    ja .r
    test bx, bx
    jnz .s
    mov ax, dx                      ; empty b$: the start position
    jmp .r
.s:
    mov si, dx
    dec si                          ; position (0-based)
.pos:
    mov ax, cx
    sub ax, bx
    jl .none
    cmp si, ax
    jg .none
    push cx
    push si
    push di
    add si, di
    push ds
    mov es, [FAC_SEG]
    mov di, [FAC_P]
    mov cx, bx
    mov ds, [B_ISEG]
    repe cmpsb
    pop ds
    pop di
    pop si
    pop cx
    je .hit
    inc si
    jmp .pos
.hit:
    lea ax, [si+1]
    jmp .r
.none:
    xor ax, ax
.r:
    pop si
    push ds
    pop es
    jmp fac_set_int

; INPUT$(n): n keys, no echo.
fn_input:
    call fn_arg_int
    test ax, ax
    jle err_func
    cmp ax, 255
    ja err_func
    mov cx, ax
    push cx
    call fn_newstr                  ; ES:DI
    pop cx
.k:
    push cx
    mov ah, 0
    int 18h
    pop cx
    stosb
    loop .k
    jmp b_ds_es

fn_err:
    movzx ax, byte [B_ERRNO]
    jmp fac_set_int
fn_erl:
    mov ax, [B_ERRLINE]
    jmp fac_set_int

; ---------------------------------------------------------------- DEF FN
; Slot of the function named DX (CX bytes, type AH) in B_FNTAB: BX -> word
; holding the text pointer of its definition (a new slot when unknown).
b_find_fn:
    push si
    push di
    push cx
    mov bx, B_FNTAB
    mov di, [B_FNCNT]
.f:
    test di, di
    jz .new
    push di
    push cx
    mov si, [bx]                    ; name in the DEF statement
    push dx
    push ax
    mov al, [si]
    call b_parse_name_at            ; -> CX', AH' of the stored name
    pop ax
    pop dx
    cmp ah, [B_FNTYPE]              ; (stored by b_parse_name_at)
    pop cx
    jne .no
    cmp cx, [B_FNSIZE]
    jne .no
    push cx
    mov si, [bx]
    mov di, dx
    repe cmpsb
    pop cx
    pop di
    je .yes
    jmp .next
.no:
    pop di
.next:
    add bx, 2
    dec di
    jmp .f
.new:
    cmp word [B_FNCNT], 16
    jae err_memory
    inc word [B_FNCNT]
    mov word [bx], 0
.yes:
    pop cx
    pop di
    pop si
    ret

; Name at SI -> B_FNSIZE, B_FNTYPE (SI, DX kept).
b_parse_name_at:
    push bx
    push si
    push dx
    push ax
    push cx
    mov al, [si]
    call b_parse_name
    mov [B_FNSIZE], cx
    mov [B_FNTYPE], ah
    pop cx
    pop ax
    pop dx
    pop si
    pop bx
    ret

; FN name[(args)]: evaluate the arguments, bind them to the parameter
; variables (saving their values), evaluate the expression, restore.
eval_fn:
    push bp
    call b_skipsp
    call b_parse_name               ; DX, CX, AH; SI after the name
    push si
    call b_find_fn
    pop si
    mov di, [bx]
    test di, di
    jz .undef
    push di                         ; definition
    xor cx, cx                      ; argument count
    call b_skipsp
    cmp al, '('
    jne .args_done
    inc si
.arg:
    push cx
    call b_eval
    pop cx
    push word [FAC_SEG]
    push word [FAC_P]
    push word [FAC_I]
    movzx ax, byte [FAC_TYPE]
    push ax
    inc cx
    call b_skipsp
    inc si
    cmp al, ','
    je .arg
    cmp al, ')'
    jne err_syntax
.args_done:
    push cx
    push si                         ; caller's text
    mov bp, sp
    ; parameters: SI -> definition
    mov ax, cx
    shl ax, 3
    add ax, 4
    mov bx, bp
    add bx, ax
    mov si, [ss:bx]                 ; definition text (name)
    call b_skipsp
    call b_parse_name               ; step over the name
    xor dx, dx                      ; parameter index
    call b_skipsp
    cmp al, '('
    jne .bound
    inc si
.par:
    call b_skipsp
    cmp al, ')'
    je .pend
    cmp dx, [bp+2]
    jae err_func                    ; more parameters than arguments
    push dx
    call b_getvar                   ; BX = variable, AL = type
    pop dx
    ; save its value (8 bytes) and where it is
    push dword [fs:bx+4]
    push dword [fs:bx]
    push bx
    ; argument dx: at bp + 4 + (count-1-dx)*8
    push ax
    push dx
    mov di, [bp+2]
    dec di
    sub di, dx
    shl di, 3
    add di, bp
    add di, 4
    mov ax, [ss:di]
    mov [FAC_TYPE], al
    mov ax, [ss:di+2]
    mov [FAC_I], ax
    mov ax, [ss:di+4]
    mov [FAC_P], ax
    mov ax, [ss:di+6]
    mov [FAC_SEG], ax
    pop dx
    pop ax
    push dx
    call b_assign
    pop dx
    inc dx
    call b_skipsp
    cmp al, ','
    jne .par
    inc si
    jmp .par
.pend:
    inc si
.bound:
    push dx                         ; parameters bound
    mov ah, T_EQ
    call b_expect
    call b_eval
    pop cx
.rest:
    jcxz .restored
    pop bx
    pop dword [fs:bx]
    pop dword [fs:bx+4]
    dec cx
    jmp .rest
.restored:
    mov sp, bp
    pop si
    pop cx
    shl cx, 3
    add sp, cx
    add sp, 2                       ; definition pointer
    pop bp
    ret
.undef:
    mov al, 18                      ; Undefined user function
    jmp b_error

