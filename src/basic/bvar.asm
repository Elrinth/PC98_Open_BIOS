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
    call b_parse_name
    jmp b_getvar_named

; Name at SI -> DX = name (letter, count, rest), CX = its size, AH = type
; (suffix or DEFxxx), SI after the name and suffix.
b_parse_name:
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
    ret
.suffix:
    inc si
    ret

b_getvar_named:
    cmp byte [si], '('
    jne b_getsimple
    jmp b_getarr                    ; DX = name, CX = name size, AH = type
b_getsimple:
    mov byte [B_ISARR], 0
    ; Entries in NEC's sizes (machine code computes variable addresses from
    ; [VSEG:0002]): db first letter, db 0 (NEC: chain link), db type,
    ; db count, rest of the name, a pad byte when count is odd, value.
    push si
    push es
    mov es, [B_VSEG]
    mov bx, [B_VARTAB]
.find:
    cmp bx, [B_VAREND]
    jae .new
    cmp [es:bx+2], ah
    jne .skip
    mov si, dx
    mov al, [si]
    cmp [es:bx], al
    jne .skip
    mov al, [si+1]
    cmp [es:bx+3], al
    jne .skip
    push cx
    movzx cx, al
    lea si, [si+2]                  ; (keep ZF: CX may be 0)
    lea di, [bx+4]
    repe cmpsb
    pop cx
    je .found
.skip:
    call b_var_next_bx
    jmp .find
.found:
    call b_var_hdr_bx               ; DI = header size
    add bx, di
    mov al, ah
    pop es
    pop si
    ret
.new:
    push ax                         ; AH = type
    mov bx, [B_VAREND]
    mov al, ah
    call b_typesize
    movzx di, al
.sz:
    mov si, dx
    movzx ax, byte [si+1]           ; count
    inc ax
    and al, 0FEh
    add di, ax
    add di, 4                       ; entry size
    push cx
    push si
    call b_insert                   ; array headers follow: move them up
    add di, bx
    mov [B_VAREND], di
    mov [es:0004h], di              ; NEC: end of the simple variables
    pop si
    pop cx
    mov di, bx
    push cx
    mov cx, [B_VAREND]
    sub cx, bx
    xor al, al
    rep stosb
    pop cx
    pop ax
    push ax
    mov al, [si]
    mov [es:bx], al
    mov [es:bx+2], ah
    push cx
    movzx cx, byte [si+1]
    mov [es:bx+3], cl
    add si, 2
    lea di, [bx+4]
    rep movsb
    pop cx
    call b_var_hdr_bx
    add bx, di
    pop ax
    mov al, ah
    pop es
    pop si
    ret

; DI = header size of the simple variable entry at ES:BX.
b_var_hdr_bx:
    movzx di, byte [es:bx+3]
    inc di
    and di, 0FFFEh
    add di, 4
    ret

; BX = next simple variable entry after ES:BX.
b_var_next_bx:
    push di
    push ax
    call b_var_hdr_bx
    add bx, di
    mov al, [es:bx-0]               ; (type is in the header: reload)
    sub bx, di
    mov al, [es:bx+2]
    call b_typesize
    movzx ax, al
    add bx, di
    add bx, ax
    pop ax
    pop di
    ret

; AL = value size of type AL: integer 2, single 4, double 8, string 4.
b_typesize:
    cmp al, VT_STR
    jne .r
    mov al, 4
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
    cmp di, [B_ADEND]
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
    mov dx, [B_FBUF]
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
    push dx                         ; (b_garbage's packing pointer)
    mov es, [B_VSEG]
    mov si, [B_VARTAB]
.v:
    cmp si, [B_VAREND]
    jae .t
    push bx
    mov bx, si
    call b_var_hdr_bx
    add di, si                      ; value
    call b_var_next_bx
    mov cx, bx                      ; next entry
    pop bx
    cmp byte [es:si+2], VT_STR
    jne .n
    push cx
    push si
    call bp
    pop si
    pop cx
.n:
    mov si, cx
    jmp .v
.t:
    ; arrays: [type][size][name][dw entry size][db dims][dw counts]
    ; [dw data offset][dw data bytes]; the data is in the array region
    mov si, [B_VAREND]
.a:
    cmp si, [B_ARYEND]
    jae .tstk
    movzx cx, byte [es:si+1]
    lea di, [si+2]
    add di, cx                      ; -> entry size word
    mov dx, si
    add dx, [es:di]                 ; next entry
    cmp byte [es:si], VT_STR
    jne .anext
    movzx cx, byte [es:di+2]        ; dims
    lea di, [di+3]
    shl cx, 1
    add di, cx                      ; -> data offset, data bytes
    mov cx, [es:di+2]
    mov di, [es:di]
    add di, [B_ADATA]
    add cx, di                      ; end of the data
.ael:
    cmp di, cx
    jae .anext
    push cx
    push dx
    push di
    call bp
    pop di
    pop dx
    pop cx
    add di, 4
    jmp .ael
.anext:
    mov si, dx
    jmp .a
.tstk:
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
    pop dx
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

; ---------------------------------------------------------------- arrays
; Array element: name at DX (CX bytes: letter, count, rest), AH = type, SI at
; '('. -> BX = element offset in VSEG, AL = type. An array used without DIM
; gets 11 elements (0-10) per subscript. Subscripts may contain array
; references themselves: they are kept on the stack until ')'.
b_getarr:
    push bp
    inc si                          ; '('
    push ax
    push cx
    push dx
    xor bp, bp
.sub:
    push bp
    call b_eval_int
    pop bp
    test ax, ax
    js b_err_subscript
    push ax
    inc bp
    cmp bp, 8
    ja b_err_subscript
    call b_skipsp
    inc si
    cmp al, ','
    je .sub
    cmp al, ')'
    jne err_syntax
    mov cx, bp
    mov di, bp
.pop:
    dec di
    pop ax
    mov bx, di
    shl bx, 1
    mov [B_SUBS+bx], ax
    loop .pop
    pop dx
    pop cx
    pop ax
    push si
    call b_find_array
    jnc .have
    push cx
    mov cx, bp
    xor bx, bx
.ten:
    mov word [B_DIMS+bx], 10
    add bx, 2
    loop .ten
    pop cx
    call b_make_array
.have:
    ; BX -> entry (text pointer still on the stack): element index = s1 + c1*(s2 + c2*(...))
    push es
    mov es, [B_VSEG]
    movzx di, byte [es:bx+1]
    lea di, [bx+di+2]               ; -> entry size
    movzx cx, byte [es:di+2]
    cmp cx, bp
    jne .bad
    add di, 3                       ; -> counts
    xor dx, dx                      ; index
    mov si, cx
    dec si
    shl si, 1                       ; last subscript first
    push bx
.idx:
    mov bx, di
    add bx, si                      ; -> count of this dimension
    mov ax, dx
    mul word [es:bx]
    test dx, dx
    jnz .bad1
    mov dx, [B_SUBS+si]
    cmp dx, [es:bx]
    jae .bad1
    add dx, ax
    sub si, 2
    jns .idx
    pop bx
    shl cx, 1
    add di, cx
    mov di, [es:di]                 ; data offset in the array region
    add di, [B_ADATA]
    mov [B_ARRBASE], di
    mov byte [B_ISARR], 1
    mov al, [es:bx]
    call b_typesize
    movzx cx, al
    mov ax, dx
    mul cx
    add di, ax
    mov al, [es:bx]
    mov bx, di
    pop es
    pop si
    pop bp
    ret
.bad1:
    pop bx
.bad:
    pop es
b_err_subscript:
    mov al, E_SUBSCRIPT
    jmp b_error

; Find array DX/CX (name) of type AH -> BX = entry, CF if none.
b_find_array:
    push si
    push di
    push es
    mov es, [B_VSEG]
    mov bx, [B_VAREND]
.f:
    cmp bx, [B_ARYEND]
    jae .no
    cmp [es:bx], ah
    jne .skip
    cmp [es:bx+1], cl
    jne .skip
    push cx
    mov si, dx
    lea di, [bx+2]
    repe cmpsb
    pop cx
    je .yes
.skip:
    movzx di, byte [es:bx+1]
    lea di, [bx+di+2]
    add bx, [es:di]
    jmp .f
.yes:
    pop es
    pop di
    pop si
    clc
    ret
.no:
    pop es
    pop di
    pop si
    stc
    ret

; New array: name DX (CX bytes), type AH, BP dimensions with upper bounds
; in B_DIMS -> BX = entry, data zero-filled. As in N88-BASIC(86), the data
; of all arrays forms one region in DIM order, each array starting on a
; paragraph (programs BLOAD one file over several arrays from
; VARPTR(first(0),1):0). The headers stay with the variables:
; [type][name size][name][dw entry size][db dims][dw counts]
; [dw data offset from B_ADATA][dw data bytes].
b_make_array:
    push si
    push di
    push cx
    push dx
    push ax
    mov [B_MKNAME], dx
    mov [B_MKTYPE], ah
    mov al, ah
    call b_typesize
    movzx ax, al
    xor di, di
.cnt:
    mov bx, di
    shl bx, 1
    mov si, [B_DIMS+bx]
    inc si                          ; count = bound + 1
    jz .mem
    mov [B_DIMS+bx], si
    mul si
    test dx, dx
    jnz .mem
    inc di
    cmp di, bp
    jb .cnt
    push ax                         ; data bytes
    mov ax, bp
    shl ax, 1
    add ax, 2+2+1+4
    add ax, cx
    mov di, ax                      ; header size
    mov bx, [B_ARYEND]
    call b_insert
    pop si
    mov ax, [B_ADEND]
    mov dx, ax                      ; data start
    add ax, si
    jc .mem
    add ax, 15
    jc .mem
    and al, 0F0h
    cmp ax, [B_FRETOP]
    jbe .room
    call b_garbage
    cmp ax, [B_FRETOP]
    ja .mem
.room:
    mov [B_ADEND], ax
    push es
    mov es, [B_VSEG]
    push cx
    mov di, dx
    mov cx, si
    xor al, al
    rep stosb
    pop cx
    sub dx, [B_ADATA]
    mov di, bx
    mov al, [B_MKTYPE]
    stosb
    mov al, cl
    stosb
    push si
    mov si, [B_MKNAME]
    push cx
    rep movsb
    pop cx
    pop si
    mov ax, bp
    shl ax, 1
    add ax, 2+2+1+4
    add ax, cx
    stosw                           ; entry size
    mov ax, bp
    stosb
    push bx
    push cx
    mov cx, bp
    xor bx, bx
.c2:
    mov ax, [B_DIMS+bx]
    stosw
    add bx, 2
    loop .c2
    pop cx
    pop bx
    mov ax, dx
    stosw
    mov ax, si
    stosw
    pop es
    pop ax
    pop dx
    pop cx
    pop di
    pop si
    ret
.mem:
    jmp err_memory

; Insert DI bytes at VSEG:BX (VAREND..ARYEND): the array headers from BX
; move up, and the array data region (16-aligned) when they would reach it.
b_insert:
    pusha
    push es
    push ds
    mov es, [B_VSEG]
    mov ax, [B_ARYEND]
    add ax, di
    jc .mem
    cmp ax, [B_ADATA]
    jbe .hdr
    add ax, 15
    jc .mem
    and al, 0F0h
    sub ax, [B_ADATA]               ; distance, a multiple of 16
    mov dx, [B_ADEND]
    add dx, ax
    jc .mem
    cmp dx, [B_FRETOP]
    jbe .mv
    call b_garbage
    cmp dx, [B_FRETOP]
    ja .mem
.mv:
    mov cx, [B_ADEND]
    sub cx, [B_ADATA]
    mov si, [B_ADEND]
    dec si
    push di
    mov di, si
    add di, ax
    add [B_ADATA], ax
    add [B_ADEND], ax
    mov ds, [ss:B_VSEG]
    std
    rep movsb
    cld
    pop di
    push ss
    pop ds
.hdr:
    mov cx, [B_ARYEND]
    sub cx, bx
    mov si, [B_ARYEND]
    dec si
    add [B_ARYEND], di
    add di, si
    mov ds, [ss:B_VSEG]
    std
    rep movsb
    cld
    pop ds
    pop es
    popa
    ret
.mem:
    pop ds
    pop es
    popa
    jmp err_memory

; DIM name(bounds)[, name(bounds) ...]
stmt_dim:
    call b_skipsp
    call b_parse_name               ; DX, CX, AH; SI after the name
    cmp byte [si], '('
    jne err_syntax
    inc si
    push ax
    push cx
    push dx
    xor bp, bp
.b:
    push bp
    call b_eval_int
    pop bp
    test ax, ax
    js b_err_subscript
    push ax
    inc bp
    cmp bp, 8
    ja b_err_subscript
    call b_skipsp
    inc si
    cmp al, ','
    je .b
    cmp al, ')'
    jne err_syntax
    mov cx, bp
    mov di, bp
.p:
    dec di
    pop ax
    mov bx, di
    shl bx, 1
    mov [B_DIMS+bx], ax
    loop .p
    pop dx
    pop cx
    pop ax
    call b_find_array
    jnc .dup
    call b_make_array
    call b_skipsp
    cmp al, ','
    jne stmt_end
    inc si
    jmp stmt_dim
.dup:
    mov al, 10                      ; Duplicate Definition
    jmp b_error

; ERASE: not needed by the programs measured; arrays go with CLEAR/RUN.
