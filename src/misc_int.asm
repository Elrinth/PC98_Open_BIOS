; INT 19h (RS-232C), INT 1Ah (printer), INT 1Fh (extended services).

; INT 19h: RS-232C BIOS (channel 0, 8251 at 30h/32h). The core's 8251 has
; no line behind it, so reception never delivers data; the calls keep the
; documented interface (NP2kai bios19.c, BSD-3-Clause, as reference).
;   AH=00h/01h  initialise: AL speed, CH mode, CL command, BH/BL timeouts,
;               ES:DI -> control block + DX-byte receive buffer
;   AH=02h      CX = received count     AH=03h  send AL
;   AH=04h      receive into CX         AH=05h  command AL
;   AH=06h      CH = 8251 status, CL = system port B
RS_FLAG_INIT    equ 80h
RS_FLAG_BOVF    equ 20h
RS_CMD_IR       equ 40h
rs_divisors:    dw 0800h, 0400h, 0200h, 0100h, 0080h, 0040h, 0020h, 0010h

int19_rs232c:
    sti
    push ds
    push es
    pusha
    mov bp, sp
    xor bx, bx
    mov ds, bx
    mov al, [bp+F_AH]
    cmp al, 2
    jb .init
    cmp al, 7
    jae .ok
    ; control block from RS_CH0_OFST/SEG
    les di, [RS_CH0_OFST]
    mov ax, es
    or ax, di
    jz .not_init
    mov bl, [es:di+2]              ; flag
    test bl, RS_FLAG_INIT
    jz .not_init
    mov al, [bp+F_AH]
    cmp al, 2
    je .count
    cmp al, 3
    je .send
    cmp al, 4
    je .receive
    cmp al, 5
    je .command
    ; 06h: status
    in al, 32h
    mov [bp+F_CH], al
    in al, SYS_B
    mov [bp+F_CL], al
    jmp .status
.count:
    mov ax, [es:di+0Eh]
    mov [bp+F_CX], ax
    jmp .status
.send:
    mov al, [bp+F_AL]
    out 30h, al
    jmp .status
.receive:
    mov ax, [es:di+0Eh]
    test ax, ax
    jz .empty
    dec ax
    mov [es:di+0Eh], ax
    mov si, [es:di+12h]            ; get pointer
    mov ax, [es:si]
    mov [bp+F_CX], ax
    add si, 2
    cmp si, [es:di+0Ch]
    jb .getp
    mov si, [es:di+0Ah]
.getp:
    mov [es:di+12h], si
    and byte [es:di+2], ~RS_FLAG_BOVF
    jmp .ok
.empty:
    mov byte [bp+F_AH], 3
    jmp .done
.command:
    mov al, [bp+F_AL]
    out 32h, al
    mov [es:di+3], al
    test al, RS_CMD_IR
    jz .status
    and byte [es:di+2], ~RS_FLAG_INIT
.status:
    mov byte [bp+F_AH], 0
    test byte [es:di+2], RS_FLAG_BOVF
    jz .done
    and byte [es:di+2], ~RS_FLAG_BOVF
    mov byte [bp+F_AH], 2
    jmp .done
.not_init:
    mov byte [bp+F_AH], 1
    jmp .done
.init:
    ; baud rate: PIT counter 2 (2.4576 MHz timer family)
    movzx bx, byte [bp+F_AL]
    cmp bx, 8
    jb .speed
    mov bx, 4                      ; 1200 bps
.speed:
    add bx, bx
    mov al, 0B6h
    out PIT_MODE, al
    mov ax, [cs:rs_divisors+bx]
    out PIT_C2, al
    mov al, ah
    out PIT_C2, al
    ; 8251: reset, mode, command
    xor al, al
    out 32h, al
    out 32h, al
    out 32h, al
    mov al, 40h
    out 32h, al
    mov al, [bp+F_CH]
    or al, 02h
    and al, 0FEh
    out 32h, al
    mov al, [bp+F_CL]
    out 32h, al
    ; control block at ES:DI, buffer of DX bytes behind it
    mov es, [bp+F_ES]
    mov di, [bp+F_DI]
    mov [RS_CH0_OFST], di
    mov [RS_CH0_SEG], es
    push di
    mov cx, 14h
    xor al, al
    rep stosb
    pop di
    mov al, [bp+F_AH]
    shl al, 4
    mov cl, [bp+F_CL]
    test cl, RS_CMD_IR
    jnz .noinit
    or al, RS_FLAG_INIT
.noinit:
    mov [es:di+2], al
    mov [es:di+3], cl
    mov al, [bp+F_BH]
    test al, al
    jnz .stime
    mov al, 4
.stime:
    mov [es:di+4], al
    mov al, [bp+F_BL]
    test al, al
    jnz .rtime
    mov al, 40h
.rtime:
    mov [es:di+5], al
    lea ax, [di+14h]
    mov [es:di+0Ah], ax            ; head
    mov [es:di+10h], ax            ; put
    mov [es:di+12h], ax            ; get
    add ax, [bp+F_DX]
    mov [es:di+0Ch], ax            ; tail
    mov ax, [bp+F_DX]
    shr ax, 3
    mov [es:di+6], ax              ; XOFF threshold
    mov bx, [bp+F_DX]
    shr bx, 2
    add ax, bx
    mov [es:di+8], ax              ; XON threshold
.ok:
    mov byte [bp+F_AH], 0
.done:
    popa
    pop es
    pop ds
    iret

; INT 1Ah: cassette (AH=0xh) and printer (AH=1xh, 30h) BIOS.
; Layout matters: MS-DOS's IO.SYS hooks INT 1Ah by jumping to the original
; vector + 19h after doing "sti; push ds; push dx" itself, so the printer
; body must start exactly at +19h with DS and DX on the stack (the layout of
; NEC's BIOS, which NP2kai reproduces too).
;   AH=10h initialise, AH=11h print AL, AH=12h status, AH=30h print CX
;   bytes from ES:BX. AH=01h means done/ready, 02h busy/time-out.
int1a_printer:
    sti
    push ds
    push dx
    test ah, 10h
    jnz int1a_body
    mov ah, 01h                    ; cassette: not present
    jmp int1a_done
    times 19h-($-int1a_printer) db 90h
int1a_body:                        ; = vector + 19h
    call printer_bios
int1a_done:
    pop dx
    pop ds
    iret

printer_bios:
    mov dl, ah
    and dl, 0Fh
    cmp ah, 30h
    je .block
    cmp dl, 0
    je .init
    cmp dl, 1
    je printer_byte
    cmp dl, 2
    je .status
    xor ah, ah
    ret
.init:
    mov al, 0Dh
    out SYS_CTRL, al               ; printer strobe flip-flop
    mov al, 82h
    out 46h, al                    ; 8255 mode
    mov al, 0Fh
    out 46h, al                    ; strobe inactive
    mov al, 0Ch
    out SYS_CTRL, al
.status:
    in al, PORT_42
    shr al, 2
    and al, 1
    mov ah, al
    ret
.block:
    push bx
    push cx
    mov ah, 02h
    jcxz .block_done
.next:
    mov al, [es:bx]
    call printer_byte
    test ah, 02h
    jnz .block_done
    inc bx
    loop .next
    xor ah, ah
.block_done:
    pop cx
    pop bx
    ret

printer_byte:                      ; AL = character
    push ax
    in al, PORT_42
    test al, 04h
    pop ax
    jz .busy
    out 40h, al
    mov ah, 01h
    ret
.busy:
    mov ah, 02h
    ret

; INT 1Fh: extended services. AH=90h is the protected-mode block move used by
; DOS RAM disks and memory managers; other AH >= 80h calls without bit 4
; succeed without doing anything (as on NEC machines, per NP2kai bios1f.c).
int1f_entry:
    test ah, 80h
    jz .unchanged
    cmp ah, 90h
    je int1f_block_move
    cmp ah, 91h
    je int1f_protected
    test ah, 10h
    jnz .unchanged
    clc
    retf 2
.unchanged:
    iret

; ES:BX -> descriptor table: +10h source, +18h destination (limit word,
; 24-bit base). CX bytes (0 = 65536), SI source offset, DI destination
; offset, both bounded by their limits. A20 is left disabled afterwards.
int1f_block_move:
    push eax
    push ecx
    push edx
    push esi
    push edi
    push fs
    push gs
    movzx ecx, cx
    dec cx
    inc ecx                        ; 0 -> 65536
    ; both ranges must fit inside their descriptor limits
    movzx eax, word [es:bx+10h]
    inc eax
    movzx edx, si
    add edx, ecx
    cmp edx, eax
    ja .error
    movzx eax, word [es:bx+18h]
    inc eax
    movzx edx, di
    add edx, ecx
    cmp edx, eax
    ja .error
    mov eax, [es:bx+10h+2]
    and eax, 00FFFFFFh
    movzx esi, si
    add esi, eax
    mov eax, [es:bx+18h+2]
    and eax, 00FFFFFFh
    movzx edi, di
    add edi, eax
    cli
    call enter_unreal              ; FS/GS = 4 GiB flat
    mov al, 02h
    out A20_CTRL, al               ; enable A20
.copy:
    mov al, [fs:esi]
    mov [gs:edi], al
    inc esi
    inc edi
    dec ecx
    jnz .copy
    mov al, 03h
    out A20_CTRL, al               ; disable A20
    pop gs
    pop fs
    pop edi
    pop esi
    pop edx
    pop ecx
    pop eax
    xor ah, ah
    clc
    retf 2
.error:
    pop gs
    pop fs
    pop edi
    pop esi
    pop edx
    pop ecx
    pop eax
    stc
    retf 2

; AH=91h: switch to protected mode. ES:BX -> descriptor table: +08h GDT,
; +10h IDT pseudo-descriptors, +18h/+20h/+28h data/extra/stack segments,
; +30h the caller's code segment, +38h filled in here for the BIOS code.
; DH/DL = master/slave PIC vector bases. Returns in protected mode with
; CS = 30h, DS = 18h, ES = 20h, SS = 28h, interrupts disabled.
; Semantics follow NP2kai's BIOS stub (BSD-3-Clause).
int1f_protected:
    cli
    lgdt [es:bx+08h]
    lidt [es:bx+10h]
    ; re-base the PICs
    mov al, 11h
    out PIC_M0, al
    out CPU_RESET_WAIT, al
    mov al, dh
    out PIC_M1, al
    out CPU_RESET_WAIT, al
    mov al, 80h
    out PIC_M1, al
    out CPU_RESET_WAIT, al
    mov al, 1Dh
    out PIC_M1, al
    out CPU_RESET_WAIT, al
    mov al, 11h
    out PIC_S0, al
    out CPU_RESET_WAIT, al
    mov al, dl
    out PIC_S1, al
    out CPU_RESET_WAIT, al
    mov al, 07h
    out PIC_S1, al
    out CPU_RESET_WAIT, al
    mov al, 09h
    out PIC_S1, al
    out CPU_RESET_WAIT, al
    ; 38h: this code segment (base F8000h, 64 KiB, execute/read, accessed)
    mov word [es:bx+38h], 0FFFFh
    mov word [es:bx+3Ah], 8000h
    mov word [es:bx+3Ch], 9B0Fh
    mov word [es:bx+3Eh], 0
    xor al, al
    out A20_ON, al                 ; A20 on
    mov ax, 1
    lmsw ax
    jmp 38h:.pm
.pm:
    mov ax, 18h
    mov ds, ax
    mov ax, 20h
    mov es, ax
    mov ax, 28h
    mov ss, ax
    pop bx                         ; caller IP
    add sp, 4                      ; drop CS and FLAGS
    push word 30h
    push bx
    retf

; Load FS and GS with 4 GiB flat data descriptors and return to real mode
; ("unreal" mode). Interrupts must be disabled by the caller.
enter_unreal:
    push eax
    lgdt [cs:unreal_gdtr]
    mov eax, cr0
    or al, 1
    mov cr0, eax
    jmp short .pm
.pm:
    mov ax, 08h
    mov fs, ax
    mov gs, ax
    mov eax, cr0
    and al, 0FEh
    mov cr0, eax
    jmp short .rm
.rm:
    xor ax, ax
    mov fs, ax
    mov gs, ax
    pop eax
    ret

align 8
unreal_gdt:
    dq 0
    dq 00CF93000000FFFFh           ; 08h: flat 4 GiB data (accessed: GDT is in ROM)
unreal_gdtr:
    dw 15
    dd SEG_F800*16 + unreal_gdt
