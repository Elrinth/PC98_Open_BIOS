; Variables and string space, both in VSEG (FS while interpreting).
;
; Simple variables from B_VARTAB to B_VAREND: db type, db name size, name
; (as in the program text: letter, count, rest), value. Integer values take
; 2 bytes (single/double variables are kept as integers for now), string
; values are a descriptor: db length, db 0, dw pointer (VSEG) - the layout
; programs read through VARPTR, which returns the value's VSEG offset.
; String space grows down from B_STRTOP to B_FRETOP. Strings outside VSEG
; (literals in the program text, DATA) are copied when assigned.
; FAC and the temporary descriptors carry a segment; FAC_I/FAC_P form a
; descriptor of the variable layout.

; Parse a variable name at SI -> BX = value offset in VSEG, AL = type.
; Creates the variable when it does not exist yet.
b_getvar:
    call b_skipsp
    cmp al, 'A'
    jb err_syntax
    cmp al, 'Z'
    ja err_syntax
    mov dx, si                      ; DX -> name in the text
    movzx cx, byte [si+1]
    add cx, 2                       ; name size: letter, count, rest
    add si, cx
    mov al, [si]
    mov ah, VT_STR
    cmp al, '$'
    je .suffix
    mov ah, VT_INT
    cmp al, '%'
    je .suffix
    mov ah, VT_SNG
    cmp al, '!'
    je .suffix
    mov ah, VT_DBL
    cmp al, '#'
    je .suffix
    mov bx, dx
    movzx bx, byte [bx]
    mov ah, [B_DEFTBL+bx-'A']
    jmp .typed
.suffix:
    inc si
.typed:
    push si
    push es
    mov es, [B_VSEG]
    mov bx, [B_VARTAB]
.find:
    cmp bx, [B_VAREND]
    jae .new
    cmp [es:bx], ah
    jne .skip
    cmp [es:bx+1], cl
    jne .skip
    push cx
    mov si, dx
    lea di, [bx+2]
    repe cmpsb
    pop cx
    je .found
.skip:
    push cx
    call b_valsize_bx
    movzx cx, byte [es:bx+1]
    add bx, cx
    add bx, di
    add bx, 2
    pop cx
    jmp .find
.found:
    lea bx, [bx+2]
    add bx, cx
    mov al, ah
    pop es
    pop si
    ret
.new:
    mov bx, [B_VAREND]
    mov di, 2
    cmp ah, VT_STR
    jne .sz
    mov di, 4
.sz:
    push di                         ; value size
    add di, cx
    add di, 2
    lea di, [bx+di]                 ; new end
    cmp di, [B_FRETOP]
    jae err_memory
    mov [B_VAREND], di
    mov [es:bx], ah
    mov [es:bx+1], cl
    push cx
    mov si, dx
    lea di, [bx+2]
    rep movsb
    pop cx
    pop cx                          ; value size
    xor al, al
    rep stosb
    lea bx, [bx+2]
    movzx cx, byte [es:bx-1]
    add bx, cx
    mov al, ah
    pop es
    pop si
    ret

; DI = value size of the variable entry at ES:BX.
b_valsize_bx:
    mov di, 2
    cmp byte [es:bx], VT_STR
    jne .r
    mov di, 4
.r:
    ret

; ---------------------------------------------------------------- strings
; Allocate CX bytes of string space -> DI (VSEG offset); may collect garbage.
b_stralloc:
    call .try
    jnc .r
    call b_garbage
    call .try
    jc .full
.r:
    ret
.full:
    mov al, E_STRSPACE
    jmp b_error
.try:
    mov di, [B_FRETOP]
    sub di, cx
    jc .no
    cmp di, [B_VAREND]
    jb .no
    mov [B_FRETOP], di
    clc
    ret
.no:
    stc
    ret

; Compact string space: move every string still referenced (variables,
; temporaries, FAC) to the top, highest address first, and point all
; descriptors of a moved string at its new place.
b_garbage:
    pusha
    push es
    mov dx, [B_STRTOP]
    mov [B_GCLIM], dx
.pass:
    xor ax, ax                      ; highest string below B_GCLIM
    xor bx, bx                      ; its length
    mov bp, gc_find
    call gc_each
    test ax, ax
    jz .done
    mov [B_GCLIM], ax
    mov cx, bx
    mov si, ax
    add si, cx
    dec si
    mov di, dx
    dec di
    sub dx, cx
    push ds
    mov es, [B_VSEG]
    mov ds, [B_VSEG]
    std
    rep movsb
    cld
    pop ds
    mov [B_GCNEW], dx
    mov bp, gc_reloc
    call gc_each
    jmp .pass
.done:
    mov [B_FRETOP], dx
    pop es
    popa
    ret

; Call BP for every VSEG string descriptor in use (ES:DI -> descriptor).
gc_each:
    mov es, [B_VSEG]
    mov si, [B_VARTAB]
.v:
    cmp si, [B_VAREND]
    jae .t
    movzx cx, byte [es:si+1]
    lea di, [si+2]
    add di, cx
    cmp byte [es:si], VT_STR
    jne .n
    push si
    push di
    call bp
    pop di
    pop si
    add di, 2
.n:
    add di, 2
    mov si, di
    jmp .v
.t:
    push ds
    pop es
    mov si, B_TSTK
    mov cx, [B_TSP]
.tl:
    jcxz .f
    mov di, si
    mov dx, [si+4]
    cmp dx, [B_VSEG]
    jne .tn
    push cx
    push si
    call bp
    pop si
    pop cx
.tn:
    add si, 6
    dec cx
    jmp .tl
.f:
    cmp byte [FAC_TYPE], VT_STR
    jne .r
    mov dx, [FAC_SEG]
    cmp dx, [B_VSEG]
    jne .r
    mov di, FAC_I
    call bp
.r:
    ret

gc_find:
    cmp byte [es:di], 0
    je .r
    mov cx, [es:di+2]
    cmp cx, [B_FRETOP]
    jb .r
    cmp cx, [B_GCLIM]
    jae .r
    cmp cx, ax
    jb .r
    mov ax, cx
    movzx bx, byte [es:di]
.r:
    ret

gc_reloc:
    cmp byte [es:di], 0
    je .r
    cmp [es:di+2], ax
    jne .r
    mov cx, [B_GCNEW]
    mov [es:di+2], cx
.r:
    ret

; FAC string -> copy in string space when it is not in VSEG yet.
; Returns CX = length, DI = VSEG offset.
b_fac_to_vseg:
    mov cx, [FAC_I]
    mov di, [FAC_P]
    mov ax, [FAC_SEG]
    cmp ax, [B_VSEG]
    je .r
    jcxz .r
    push si
    call b_stralloc                 ; FAC is not in VSEG: not moved by GC
    push es
    push ds
    mov es, [B_VSEG]
    mov si, [FAC_P]
    mov ds, [FAC_SEG]
    push di
    push cx
    rep movsb
    pop cx
    pop di
    pop ds
    pop es
    mov [FAC_P], di
    mov ax, [B_VSEG]
    mov [FAC_SEG], ax
    pop si
.r:
    ret
