; Extension-ROM scan and boot dispatch (runs from the F000h bank).
;
; PC-98 extension ROMs live in 4 KiB slots D000h-DF00h. A ROM has 55h AAh at
; offset 09h and far entry points at 0Ch (claim: BX -> its byte in the
; 04D0h table, the ROM writes an ID there), 0Fh (initialise), 12h (late
; initialise) and 15h (boot: AL = boot device code, returns if it does not
; boot). The core's disk ROM uses exactly this protocol.

EXTROM_SLOTS    equ 16

; Call entry point AX of every slot. DS=0. With AX=0Ch only unclaimed slots
; that carry a ROM signature are called; with other entries only slots whose
; claim byte has bit 6 set.
extrom_call_all:
    push bx
    push cx
    mov [EXTROM_ENTRY], ax
    mov word [EXTROM_SEG], 0D000h
    mov bx, EXTROM_TABLE
    mov cx, EXTROM_SLOTS
.slot:
    cmp word [EXTROM_ENTRY], 0Ch
    jne .claimed
    push es
    mov es, [EXTROM_SEG]
    cmp word [es:09h], 0AA55h
    pop es
    jne .next
    cmp byte [bx], 0
    jne .next
    jmp .call
.claimed:
    test byte [bx], 40h
    jz .next
.call:
    push ax
    push bx
    push cx
    push ds
    push es
    call far [EXTROM_ENTRY]
    pop es
    pop ds
    pop cx
    pop bx
    pop ax
.next:
    inc bx
    add word [EXTROM_SEG], 100h
    loop .slot
    pop cx
    pop bx
    ret

extrom_scan:
    mov di, EXTROM_TABLE
    xor ax, ax
    mov cx, EXTROM_SLOTS/2
    push ds
    pop es
    rep stosw
    mov ax, 0Ch
    call extrom_call_all
    mov ax, 0Fh
    call extrom_call_all
    mov ax, 12h
    call extrom_call_all
    ret

; Boot sequence. Entered from POST and from the ROM-BASIC stub.
boot_restart:
    cli
    xor eax, eax                   ; POST leaves junk in the upper halves;
    xor ebx, ebx                   ; EMM386 indexes with ECX after mov cx
    xor ecx, ecx
    xor edx, edx
    xor esi, esi
    xor edi, edi
    xor ebp, ebp
    xor ax, ax
    mov ds, ax
    mov ss, ax
    mov sp, 7C00h
    sti
    ; Automatic order: extension ROMs first pass (the disk ROM boots a valid
    ; hard disk here), then floppies, then an explicit hard-disk request.
    mov al, 01h
    call extrom_boot_rom
    call floppy_boot
    mov al, 0Ah
    call extrom_boot_rom
    int 1Eh                        ; no system: ROM-BASIC stub
    jmp boot_restart

; Offer boot device code AL to every claimed extension ROM (entry 15h).
; Returns only if none of them booted. DS=0.
extrom_boot_rom:
    push bx
    push cx
    mov ah, al
    mov word [EXTROM_ENTRY], 15h
    mov word [EXTROM_SEG], 0D000h
    mov bx, EXTROM_TABLE
    mov cx, EXTROM_SLOTS
.slot:
    test byte [bx], 40h
    jz .next
    push ax
    push bx
    push cx
    mov al, ah
    call far [EXTROM_ENTRY]
    xor bx, bx
    mov ds, bx
    pop cx
    pop bx
    pop ax
.next:
    inc bx
    add word [EXTROM_SEG], 100h
    loop .slot
    pop cx
    pop bx
    ret

; Try floppy drives 0 and 1: 2HD first, then 2DD. The IPL goes to
; 1FC0:0000 (1 KiB, 1024-byte MFM sectors) or 1FE0:0000 (512 bytes
; otherwise), as on NEC machines. Returns if no floppy boots. DS=0.
floppy_boot:
    mov si, floppy_boot_devices
.device:
    mov al, [cs:si]
    test al, al
    jz .none
    push si
    call floppy_try
    pop si
    inc si
    jmp .device
.none:
    ret

floppy_boot_devices: db 90h, 91h, 70h, 71h, 0

; Try to boot from DA/UA AL. Returns on failure.
floppy_try:
    mov [DISK_BOOT], al
    mov ah, 03h                    ; initialise the interface
    int 1Bh
    mov al, [DISK_BOOT]
    mov ah, 07h                    ; recalibrate
    int 1Bh
    jc .fail
    xor bl, bl                     ; FM first, then MFM, as NEC machines do:
.density:                          ; the core's FDC can report an MFM ID on
    mov al, [DISK_BOOT]            ; an FM track (N88-BASIC disks)
    mov ah, 0Ah
    or ah, bl
    xor cx, cx
    xor dx, dx
    int 1Bh                        ; READ ID: CH = N
    jnc .found
    xor bl, 40h
    jnz .density
    jmp .fail
.found:
    movzx si, bl                   ; SI = MFM flag (40h) for the read
    mov di, 1FC0h
    mov ax, 400h
    cmp ch, 3
    jne .small
    test bl, bl
    jnz .load
.small:
    mov di, 1FE0h
    mov ax, 200h
.load:
    push di
    mov es, di
    mov bx, ax
    xor bp, bp
    xor cl, cl                     ; C = 0 (CH keeps N)
    xor dh, dh
    mov dl, 1
    mov ax, si
    mov ah, 16h                    ; read data, seek
    or ah, al                      ; MFM as detected
    mov al, [DISK_BOOT]
    int 1Bh
    pop di
    jc .fail
    ; publish the interface that booted
    mov ax, [DISK_EQUIP]
    test byte [DISK_BOOT], 80h
    jnz .hd
    and ax, 0FFFh
    or ax, 3000h
    jmp .equip
.hd:
    and ax, 0FFF0h
    or ax, 0003h
.equip:
    mov [DISK_EQUIP], ax
    push di
    push word 0
    mov al, [DISK_BOOT]
    sti
    retf                           ; jump to the IPL
.fail:
    ret
