; Single-precision arithmetic in Microsoft binary format (MBF), as N88-BASIC
; stores it: dword, bytes 0-2 = mantissa (bit 23 of the 24 implied; that
; bit of byte 2 is the sign), byte 3 = exponent; value = 0.1mmm(binary) x
; 2^(exponent-128), exponent 0 = zero. Double precision values are kept to
; single precision here (their high 4 bytes have the same layout).
;
; Working form (f_unpack/f_pack): EDX = mantissa with bit 31 set (8 bits
; below single precision for rounding), CX = exponent (may leave 1-255
; before packing), BL = sign (80h negative).

; EAX (MBF4) -> EDX, CX, BL. Zero: EDX = 0, CX = 0.
f_unpack:
    xor edx, edx
    xor cx, cx
    xor bl, bl
    test eax, 0FF000000h
    jz .r
    mov edx, eax
    shl edx, 8
    or edx, 80000000h
    mov ecx, eax
    shr ecx, 24
    test eax, 800000h
    jz .r
    mov bl, 80h
.r:
    ret

; EDX, CX, BL -> EAX (MBF4), rounded to nearest. Overflow -> error, too
; small -> 0. EDX need not be normalised.
f_pack:
    test edx, edx
    jz .zero
.norm:
    test edx, 80000000h
    jnz .round
    shl edx, 1
    dec cx
    jmp .norm
.round:
    add edx, 80h
    jnc .nc
    rcr edx, 1
    inc cx
.nc:
    cmp cx, 0
    jle .zero
    cmp cx, 255
    jg err_overflow
    mov eax, edx
    shr eax, 8
    and eax, 7FFFFFh
    test bl, bl
    jz .pos
    or eax, 800000h
.pos:
    movzx ecx, cl
    shl ecx, 24
    or eax, ecx
    ret
.zero:
    xor eax, eax
    ret

; AX (signed integer) -> EAX (MBF4)
f_from_int:
    movsx eax, ax
; EAX (signed 32-bit integer) -> EAX (MBF4)
f_from_int32:
    push ebx
    push ecx
    push edx
    xor bl, bl
    test eax, eax
    jns .p
    neg eax
    mov bl, 80h
.p:
    mov edx, eax
    mov cx, 128+32
    call f_pack
    pop edx
    pop ecx
    pop ebx
    ret

; EAX (MBF4) -> EAX = integer part (signed, toward zero), EDX = fraction
; bits of |x| (bit 31 = 1/2); CF set when |x| >= 2^31.
f_split:
    push ebx
    push ecx
    call f_unpack
    test edx, edx
    jz .zero
    mov ax, 128+32
    sub ax, cx                      ; right shift that leaves the integer
    jle .big
    cmp ax, 32
    jb .sh
    mov cx, ax
    sub cx, 32
    cmp cx, 32
    jae .tiny
    shr edx, cl
    xor eax, eax
    jmp .sign
.tiny:
    xor edx, edx
    xor eax, eax
    jmp .sign
.sh:
    mov cl, al
    mov eax, edx
    shr eax, cl
    neg cl
    and cl, 31
    shl edx, cl
.sign:
    test eax, eax
    js .big
    test bl, bl
    jz .ok
    neg eax
.ok:
    pop ecx
    pop ebx
    clc
    ret
.zero:
    xor eax, eax
    xor edx, edx
    jmp .ok
.big:
    pop ecx
    pop ebx
    stc
    ret

; EAX (MBF4) -> AX rounded to the nearest integer (halves away from zero),
; "Overflow" outside -32768..32767.
f_to_int:
    push edx
    push ebx
    mov ebx, eax
    call f_split
    jc err_overflow
    test edx, 80000000h
    jz .nr
    test ebx, 800000h
    jz .up
    dec eax
    jmp .nr
.up:
    inc eax
.nr:
    cmp eax, 32767
    jg err_overflow
    cmp eax, -32768
    jl err_overflow
    pop ebx
    pop edx
    ret

; EAX = INT(x) (floor), MBF4.
f_floor:
    push ebx
    push ecx
    push edx
    mov ebx, eax
    test eax, 0FF000000h
    jz .r
    mov ecx, eax
    shr ecx, 24
    cmp cx, 128+24
    jae .r
    call f_split
    test edx, edx
    jz .int
    test ebx, 800000h
    jz .int
    dec eax
.int:
    call f_from_int32
.r:
    pop edx
    pop ecx
    pop ebx
    ret

; EAX = FIX(x) (toward zero), MBF4.
f_fix:
    push ecx
    push edx
    mov ecx, eax
    shr ecx, 24
    cmp cx, 128+24
    jae .r
    call f_split
    call f_from_int32
.r:
    pop edx
    pop ecx
    ret

; EAX = -EAX
f_neg:
    test eax, 0FF000000h
    jz .r
    xor eax, 800000h
.r:
    ret

; EAX = EAX - EBX / EAX + EBX
f_sub:
    xchg eax, ebx
    call f_neg
    xchg eax, ebx
f_add:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    test ebx, 0FF000000h
    jz .done
    test eax, 0FF000000h
    jnz .both
    mov eax, ebx
    jmp .done
.both:
    mov ecx, eax
    shr ecx, 24
    mov edx, ebx
    shr edx, 24
    cmp cl, dl
    jae .ord
    xchg eax, ebx                   ; A = the one with the larger exponent
.ord:
    push ebx
    call f_unpack
    mov esi, edx
    mov di, cx
    mov [F_SA], bl
    pop eax
    call f_unpack
    mov ax, di
    sub ax, cx
    cmp ax, 32
    jae .anly
    mov cl, al
    shr edx, cl
    mov cx, di
    cmp bl, [F_SA]
    jne .diff
    add esi, edx
    jnc .pk
    rcr esi, 1
    inc cx
    jmp .pk
.diff:
    cmp esi, edx
    jae .ab
    xchg esi, edx
    mov [F_SA], bl
.ab:
    sub esi, edx
.pk:
    mov edx, esi
    mov bl, [F_SA]
    call f_pack
    jmp .done
.anly:
    mov edx, esi
    mov cx, di
    mov bl, [F_SA]
    call f_pack
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; EAX = EAX * EBX
f_mul:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    test eax, 0FF000000h
    jz .zero
    test ebx, 0FF000000h
    jz .zero
    push ebx
    call f_unpack
    mov esi, edx
    mov di, cx
    mov [F_SA], bl
    pop eax
    call f_unpack
    xor bl, [F_SA]
    mov eax, esi
    mul edx
    add cx, di
    sub cx, 128
    test edx, 80000000h
    jnz .n
    shl eax, 1
    rcl edx, 1
    dec cx
.n:
    call f_pack
    jmp .done
.zero:
    xor eax, eax
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; EAX = EAX / EBX ("Division by zero" when EBX = 0)
f_div:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    test ebx, 0FF000000h
    jz err_div0
    test eax, 0FF000000h
    jz .done
    push ebx
    call f_unpack
    mov esi, edx
    mov di, cx
    mov [F_SA], bl
    pop eax
    call f_unpack
    xor bl, [F_SA]
    mov [F_SA], bl
    mov ebx, edx
    mov edx, esi
    shr edx, 1
    mov eax, esi
    shl eax, 31
    div ebx                         ; A/B * 2^31
    mov edx, eax
    mov ax, di
    sub ax, cx
    add ax, 128+1
    mov cx, ax
    mov bl, [F_SA]
    call f_pack
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; Compare EAX with EBX: DH = 1 (<), 2 (=), 4 (>); other registers kept.
f_cmp:
    push eax
    push ebx
    call .key
    xchg eax, ebx
    call .key
    xchg eax, ebx
    cmp eax, ebx
    pop ebx
    pop eax
    mov dh, 1
    jl .r
    mov dh, 2
    je .r
    mov dh, 4
.r:
    ret
.key:                               ; EAX -> a signed integer in value order
    test eax, 0FF000000h
    jnz .nz
    xor eax, eax
    ret
.nz:
    push ecx
    mov ecx, eax
    and ecx, 7FFFFFh
    test eax, 800000h
    pushf
    shr eax, 24
    shl eax, 23
    or eax, ecx
    popf
    jz .pos
    neg eax
.pos:
    pop ecx
    ret

F_ONE           equ 81000000h       ; 1.0
F_TEN           equ 84200000h       ; 10.0

; EAX = EAX ^ BX (integer exponent)
f_pow_int:
    push ecx
    push edx
    push esi
    mov esi, eax                    ; base
    movsx edx, bx
    test edx, edx
    jns .p
    neg edx
.p:
    mov eax, F_ONE
.l:
    test edx, edx
    jz .sgn
    test dl, 1
    jz .sq
    push ebx
    mov ebx, esi
    call f_mul
    pop ebx
.sq:
    shr edx, 1
    jz .sgn
    push eax
    push ebx
    mov eax, esi
    mov ebx, esi
    call f_mul
    mov esi, eax
    pop ebx
    pop eax
    jmp .l
.sgn:
    test bx, bx
    jns .r
    push ebx
    mov ebx, eax
    mov eax, F_ONE
    call f_div
    pop ebx
.r:
    pop esi
    pop edx
    pop ecx
    ret

; RND: next value in [0,1) (x > 0 or no argument), the last one (x = 0),
; or reseed (x < 0). EAX = x (MBF4) in, result out.
f_rnd:
    test eax, 0FF000000h
    jz .last
    test eax, 800000h
    jz .next
    mov [F_SEED], eax               ; negative: a new sequence from x
.next:
    mov eax, [F_SEED]
    imul eax, eax, 214013
    add eax, 2531011
    mov [F_SEED], eax
    push ebx
    push ecx
    push edx
    mov edx, eax
    shr edx, 8                      ; 24 random bits
    xor bl, bl
    mov cx, 128+8                   ; value = bits / 2^24
    call f_pack
    pop edx
    pop ecx
    pop ebx
    mov [F_LAST], eax
    ret
.last:
    mov eax, [F_LAST]
    ret

; ---------------------------------------------------------------- text
; Format EAX (MBF4) like PRINT does, without the sign position: digits to
; B_NUMBUF; BX = start, CX = length. A leading '-' for negatives.
f_format:
    push si
    push di
    push dx
    mov di, F_OUT+24
    mov byte [di], 0
    mov si, F_OUT                   ; output pointer
    test eax, 0FF000000h
    jnz .nz
    mov byte [si], '0'
    inc si
    jmp .out
.nz:
    test eax, 800000h
    jz .pos
    mov byte [si], '-'
    inc si
    and eax, 0FF7FFFFFh
.pos:
    ; integral and below 10^7: plain digits
    push eax
    call f_split
    pop ebx
    jc .sci
    test edx, edx
    jnz .sci
    cmp eax, 10000000
    jae .sci
    call .digits32                  ; EAX -> digits at SI
    jmp .out
.sci:
    mov eax, ebx
    ; scale to 1e6 <= v < 1e7, K = decimal exponent of the first digit
    mov word [F_K], 6
.down:
    mov ebx, 98189680h              ; 1e7
    call f_cmp
    cmp dh, 4
    jb .up
    mov ebx, F_TEN
    call f_div
    inc word [F_K]
    jmp .down
.up:
    mov ebx, 94742400h              ; 1e6
    call f_cmp
    cmp dh, 1
    jne .scaled
    mov ebx, F_TEN
    call f_mul
    dec word [F_K]
    jmp .up
.scaled:
    push eax
    call f_to_int32_round
    pop ebx
    cmp eax, 10000000
    jb .n7
    mov eax, 1000000
    inc word [F_K]
.n7:
    ; 7 digits into F_DIG, then drop trailing zeros
    push si
    mov si, F_DIG
    call .digits32
    mov cx, si
    sub cx, F_DIG                   ; 7
    pop si
.trim:
    cmp cx, 1
    jbe .trimmed
    mov bx, F_DIG
    add bx, cx
    cmp byte [bx-1], '0'
    jne .trimmed
    dec cx
    jmp .trim
.trimmed:
    mov ax, [F_K]
    cmp ax, 6
    jg .enot
    cmp ax, -3
    jl .enot
    test ax, ax
    js .frac
    ; fixed: K+1 integer digits, then the rest after a point
    mov bx, F_DIG
    mov dx, ax
    inc dx                          ; integer digits
.ip:
    test dx, dx
    jz .ipdone
    mov al, '0'
    cmp cx, 0
    je .ipz
    mov al, [bx]
    inc bx
    dec cx
.ipz:
    mov [si], al
    inc si
    dec dx
    jmp .ip
.ipdone:
    test cx, cx
    jz .out
    mov byte [si], '.'
    inc si
.fd:
    mov al, [bx]
    mov [si], al
    inc si
    inc bx
    loop .fd
    jmp .out
.frac:                              ; .000ddd
    mov byte [si], '.'
    inc si
    mov dx, ax
    not dx                          ; -K-1 zeros
.fz:
    test dx, dx
    jz .fdig
    mov byte [si], '0'
    inc si
    dec dx
    jmp .fz
.fdig:
    mov bx, F_DIG
.fd2:
    mov al, [bx]
    mov [si], al
    inc si
    inc bx
    loop .fd2
    jmp .out
.enot:                              ; d.dddE+xx
    mov bx, F_DIG
    mov al, [bx]
    mov [si], al
    inc si
    inc bx
    dec cx
    jz .exp
    mov byte [si], '.'
    inc si
.ed:
    mov al, [bx]
    mov [si], al
    inc si
    inc bx
    loop .ed
.exp:
    mov byte [si], 'E'
    inc si
    mov ax, [F_K]
    mov byte [si], '+'
    test ax, ax
    jns .ep
    mov byte [si], '-'
    neg ax
.ep:
    inc si
    mov dl, 10
    div dl
    add ax, '00'
    mov [si], ax
    add si, 2
.out:
    mov bx, F_OUT
    mov cx, si
    sub cx, bx
    pop dx
    pop di
    pop si
    ret
.digits32:                          ; EAX (unsigned) -> decimal at SI
    push ebx
    push ecx
    push edx
    xor cx, cx
    mov ebx, 10
.dv:
    xor edx, edx
    div ebx
    push dx
    inc cx
    test eax, eax
    jnz .dv
.dw:
    pop ax
    add al, '0'
    mov [si], al
    inc si
    loop .dw
    pop edx
    pop ecx
    pop ebx
    ret

; EAX (MBF4, >= 0) -> EAX = nearest 32-bit integer.
f_to_int32_round:
    push edx
    call f_split
    test edx, 80000000h
    jz .r
    inc eax
.r:
    pop edx
    ret

; Text at DS:SI, CX bytes: a decimal number (sign, digits, '.', digits,
; E/D exponent) or &H/&O -> FAC (integer when it fits and has no point or
; exponent, else single). SI, CX advanced.
f_parse:
    push bx
    push dx
    push di
    xor eax, eax
    mov [F_MANT], eax
    mov word [F_EXP10], 0
    mov byte [F_NEG], 0
    mov byte [F_ISF], 0
    xor di, di                      ; digits stored
.sp:
    test cx, cx
    jz .done
    cmp byte [si], ' '
    jne .sg
    inc si
    dec cx
    jmp .sp
.sg:
    cmp byte [si], '-'
    jne .pl
    mov byte [F_NEG], 1
    jmp .s1
.pl:
    cmp byte [si], '+'
    jne .int
.s1:
    inc si
    dec cx
.int:
    test cx, cx
    jz .done
    mov al, [si]
    cmp al, '.'
    je .point
    sub al, '0'
    cmp al, 9
    ja .expo
    call .digit
    inc si
    dec cx
    jmp .int
.point:
    mov byte [F_ISF], 1
    inc si
    dec cx
.fr:
    test cx, cx
    jz .done
    mov al, [si]
    sub al, '0'
    cmp al, 9
    ja .expo
    call .digit
    dec word [F_EXP10]
    inc si
    dec cx
    jmp .fr
.expo:
    mov al, [si]
    or al, 20h
    cmp al, 'e'
    je .e
    cmp al, 'd'
    jne .done
.e:
    mov byte [F_ISF], 1
    inc si
    dec cx
    xor dx, dx                      ; exponent
    xor bx, bx                      ; sign
    test cx, cx
    jz .eend
    cmp byte [si], '-'
    jne .ep
    inc bx
    jmp .es
.ep:
    cmp byte [si], '+'
    jne .ed
.es:
    inc si
    dec cx
.ed:
    test cx, cx
    jz .eend
    mov al, [si]
    sub al, '0'
    cmp al, 9
    ja .eend
    imul dx, dx, 10
    movzx ax, al
    add dx, ax
    inc si
    dec cx
    jmp .ed
.eend:
    test bx, bx
    jz .ea
    neg dx
.ea:
    add [F_EXP10], dx
.done:
    mov eax, [F_MANT]
    cmp byte [F_ISF], 0
    jne .float
    cmp word [F_EXP10], 0
    jne .float
    cmp eax, 32768
    ja .float
    jb .smallint
    cmp byte [F_NEG], 0
    je .float
.smallint:
    cmp byte [F_NEG], 0
    je .ipos
    neg eax
.ipos:
    mov [FAC_I], ax
    mov byte [FAC_TYPE], VT_INT
    jmp .r
.float:
    call f_from_int32
.sc:
    cmp word [F_EXP10], 0
    je .sgn
    jg .mul
    mov ebx, F_TEN
    call f_div
    inc word [F_EXP10]
    jmp .sc
.mul:
    mov ebx, F_TEN
    call f_mul
    dec word [F_EXP10]
    jmp .sc
.sgn:
    cmp byte [F_NEG], 0
    je .st
    call f_neg
.st:
    mov [FAC_I], eax
    mov byte [FAC_TYPE], VT_SNG
.r:
    pop di
    pop dx
    pop bx
    ret
.digit:                             ; AL = digit
    cmp di, 9
    jb .take
    inc word [F_EXP10]              ; beyond 9 digits: only the scale
    ret
.take:
    inc di
    push edx
    push ebx
    movzx ebx, al
    mov eax, [F_MANT]
    mov edx, 10
    mul edx
    add eax, ebx
    mov [F_MANT], eax
    pop ebx
    pop edx
    ret
