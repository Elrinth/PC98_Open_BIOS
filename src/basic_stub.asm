; E800:0000 - INT 1Eh target. Real machines enter N88-BASIC here when no
; system disk boots. This BIOS has no BASIC: show a message and wait for a
; key, then restart the boot sequence.

basic_entry:
    cli
    cld
    xor ax, ax
    mov ss, ax
    mov sp, 7C00h
    mov ds, ax
    sti
    mov dx, 0E120h                 ; space, white attribute
    mov ah, 16h
    int 18h
    push cs
    pop ds
    mov si, basic_msg
    mov di, 160*10 + 2*14
    call e800_print
    mov si, basic_msg2
    mov di, 160*12 + 2*14
    call e800_print
    mov ah, 00h
    int 18h                        ; wait for any key
    jmp SEG_F000:boot_restart

; DS:SI = ASCIIZ, DI = text VRAM offset.
e800_print:
    push es
    mov ax, 0A000h
    mov es, ax
.next:
    lodsb
    test al, al
    jz .done
    xor ah, ah
    mov [es:di], ax
    mov byte [es:di+2000h], 0E1h
    add di, 2
    jmp .next
.done:
    pop es
    ret

basic_msg:  db 'No bootable disk found (open PC-98 BIOS).', 0
basic_msg2: db 'Insert a system disk and press any key.', 0
