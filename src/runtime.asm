; Resident interrupt handlers shared by all services: default IRQ handlers,
; system timer (IRQ0/INT 08h) and keyboard (IRQ1/INT 09h).

; Interrupt vector table image for vectors 00h-1Fh (offsets in F800h).
vector_table:
    dw iret_stub        ; 00 divide error
    dw iret_stub        ; 01 single step
    dw nmi_handler      ; 02 NMI (parity / memory error)
    dw iret_stub        ; 03 breakpoint
    dw iret_stub        ; 04 overflow
    dw iret_stub        ; 05 COPY key (called by INT 09h)
    dw iret_stub        ; 06 STOP key
    dw iret_stub        ; 07 interval-timer user routine
    dw int08_timer      ; 08 IRQ0 timer
    dw int09_keyboard   ; 09 IRQ1 keyboard
    dw irq_master_eoi   ; 0A IRQ2 CRTV
    dw irq_master_eoi   ; 0B IRQ3 INT0
    dw irq_master_eoi   ; 0C IRQ4 RS-232C
    dw irq_master_eoi   ; 0D IRQ5 INT1
    dw irq_master_eoi   ; 0E IRQ6 INT2
    dw irq_slave_eoi    ; 0F IRQ7 slave cascade / spurious
    dw irq_slave_eoi    ; 10 IRQ8 printer
    dw irq_slave_eoi    ; 11 IRQ9 INT3 (HDD)
    dw int12_fdd_irq    ; 12 IRQ10 INT41 (640 KB FDD)
    dw int13_fdd_irq    ; 13 IRQ11 INT42 (1 MB FDD)
    dw irq_slave_eoi    ; 14 IRQ12 INT5
    dw irq_slave_eoi    ; 15 IRQ13 INT6
    dw irq_slave_eoi    ; 16 IRQ14
    dw irq_slave_eoi    ; 17 IRQ15
    dw int18_entry      ; 18 CRT / keyboard BIOS
    dw int19_rs232c     ; 19 RS-232C BIOS
    dw int1a_printer    ; 1A printer BIOS
    dw int1b_entry      ; 1B disk BIOS
    dw int1c_entry      ; 1C timer / calendar BIOS
    dw iret_stub        ; 1D graphics (none)
    dw iret_stub        ; 1E ROM BASIC (set to E800:0000 by POST)
    dw int1f_entry      ; 1F extended services
VECTOR_COUNT equ ($-vector_table)/2

iret_stub:
    iret

nmi_handler:
    iret

; Unhandled IRQs: acknowledge so the line cannot wedge the PIC.
irq_master_eoi:
    push ax
    mov al, 20h
    out PIC_M0, al
    pop ax
    iret

irq_slave_eoi:
    push ax
    mov al, 20h
    out PIC_S0, al
    out CPU_RESET_WAIT, al
    mov al, 0Bh                    ; read slave ISR
    out PIC_S0, al
    out CPU_RESET_WAIT, al
    in al, PIC_S0
    test al, al
    jnz .master_done               ; slave still busy: keep cascade in service
    mov al, 20h
    out PIC_M0, al
.master_done:
    pop ax
    iret

; ---------------------------------------------------------------- IRQ0
; The PC-98 BIOS timer is a one-shot 10 ms interval started by INT 1Ch
; AH=02h/03h. Each tick decrements CA_TIM_CNT; at zero the timer IRQ is masked
; and the user routine at vector 07h runs.
int08_timer:
    sti
    push ax
    push ds
    xor ax, ax
    mov ds, ax
    dec word [CA_TIM_CNT]
    pop ds
    cli
    jz .expired
    mov al, 20h
    out PIC_M0, al
    sti
    mov ah, 03h                    ; restart the 10 ms interval
    int 1Ch
    pop ax
    iret
.expired:
    in al, PIC_M1
    or al, 01h
    out CPU_RESET_WAIT, al
    out PIC_M1, al
    mov al, 20h
    out PIC_M0, al
    sti
    pop ax
    int 07h
    iret

; ---------------------------------------------------------------- IRQ1
int09_keyboard:
    sti
    push ax
    push ds
    xor ax, ax
    mov ds, ax
.retry:
    in al, KB_CMD
    test al, 38h                   ; parity / overrun / framing error
    jnz .error
    mov al, 16h                    ; error reset, RX enable, RTS
    out KB_CMD, al
    mov byte [KB_RETRY], 0
    in al, KB_DATA
    mov ah, al
    call key_store
.done:
    pop ds
    cli
    mov al, 20h
    out PIC_M0, al
    cmp ah, 60h
    je .stop_key
    cmp ah, 61h
    je .copy_key
    pop ax
    iret
.stop_key:
    pop ax
    int 06h
    iret
.copy_key:
    pop ax
    int 05h
    iret
.error:
    cmp byte [KB_RETRY], 3
    jae .give_up
    inc byte [KB_RETRY]
    mov al, 14h                    ; error reset, RX enable, no retry request
    out KB_CMD, al
    in al, KB_DATA
    xor ah, ah
    jmp .done
.give_up:
    mov al, 16h
    out KB_CMD, al
    in al, KB_DATA
    xor ah, ah
    jmp .done

; Translate the raw key code in AH and update the work area (DS=0).
; Behaviour follows NP2kai bios09.c (BSD-3-Clause, NP2 developer team).
key_store:
    push ax
    push bx
    push cx
    push si
    mov al, ah
    and al, 7Fh
    mov bl, al
    shr bl, 3
    xor bh, bh                      ; BX = byte index in KB_KY_STS
    mov cl, al
    and cl, 7
    mov ch, 1
    shl ch, cl                      ; CH = bit
    test ah, 80h
    jnz .release
    or [KB_KY_STS+bx], ch
    mov si, [KB_SHIFT_TBL]          ; key table offset (segment FD80h)
    mov bl, al                      ; BX = key code (BH already 0)
    cmp al, 51h
    ja .above_51
    cmp al, 51h
    je .scan_only
    cmp al, 35h
    je .scan_only
    cmp al, 3Eh
    je .scan_only
    call key_table_byte
    cmp al, 0FFh
    je .out
    mov cl, al                      ; ASCII in low byte, scan code in high
    mov ch, bl
    jmp .put
.scan_only:
    call key_table_byte
    cmp al, 0FFh
    je .out
    xor cl, cl
    mov ch, al
    jmp .put
.above_51:
    cmp al, 60h
    jae .above_60
    cmp al, 5Eh                     ; HOME/CLR
    jne .out
    mov cx, 0AE00h
    jmp .put
.above_60:
    cmp al, 62h
    jb .out                         ; STOP/COPY: handled by the caller
    cmp al, 70h
    jae .shift_keys
    sub bl, 0Ch
    call key_table_byte
    cmp al, 0FFh
    je .out
    xor cl, cl
    mov ch, al
    jmp .put
.shift_keys:
    cmp al, 70h
    je .shift
    cmp al, 7Dh
    je .shift
    cmp al, 75h
    jae .out
    or [SHIFT_STS], ch
    call update_shift_table
    jmp .out
.shift:
    or byte [SHIFT_STS], 01h
    call update_shift_table
    jmp .out
.put:
    cmp byte [KB_COUNT], 10h
    jae .out
    inc byte [KB_COUNT]
    mov bx, [KB_BUF_TAIL]
    mov [bx], cx
    add bx, 2
    cmp bx, KB_BUF_END
    jb .tail
    mov bx, KB_BUF
.tail:
    mov [KB_BUF_TAIL], bx
    jmp .out
.release:
    not ch
    and [KB_KY_STS+bx], ch
    not ch
    cmp ah, 0FDh
    je .unshift
    cmp ah, 0F0h
    je .unshift
    jb .out
    cmp ah, 0F5h
    jae .out
    not ch
    and [SHIFT_STS], ch
    call update_shift_table
    jmp .out
.unshift:
    and byte [SHIFT_STS], 0FEh
    call update_shift_table
.out:
    pop si
    pop cx
    pop bx
    pop ax
    ret

; AL = byte at FD80:SI+BX (the current key table).
key_table_byte:
    push ds
    push ax
    mov ax, SEG_FD80
    mov ds, ax
    pop ax
    mov al, [si+bx]
    pop ds
    ret

; Select the key table for the current SHIFT/CAPS/KANA/GRPH/CTRL state.
update_shift_table:
    push ax
    push bx
    mov al, [SHIFT_STS]
    mov bl, 7
    test al, 10h                    ; CTRL
    jnz .set
    mov bl, 6
    test al, 08h                    ; GRPH
    jnz .set
    mov bl, al
    and bl, 7                       ; SHIFT | CAPS | KANA
    cmp bl, 6
    jb .set
    sub bl, 2
.set:
    mov al, 60h
    mul bl
    add ax, 0E00h
    mov [KB_SHIFT_TBL], ax
    pop bx
    pop ax
    ret

; ---------------------------------------------------------------- helpers
; Wait for room in a GDC FIFO. DX = status port.
gdc_wait_room:
    push ax
    push cx
    mov cx, 0FFFFh
.wait:
    in al, dx
    test al, GDC_FIFO_FULL
    jz .ok
    loop .wait
.ok:
    pop cx
    pop ax
    ret

; Wait until a GDC FIFO is empty. DX = status port.
gdc_wait_empty:
    push ax
    push cx
    mov cx, 0FFFFh
.wait:
    in al, dx
    test al, GDC_FIFO_EMPTY
    jnz .ok
    loop .wait
.ok:
    pop cx
    pop ax
    ret

; Text GDC command AL. Preserves all registers.
tgdc_cmd:
    push dx
    mov dx, GDC_T_STAT
    call gdc_wait_room
    out GDC_T_CMD, al
    pop dx
    ret

; Text GDC parameter AL.
tgdc_param:
    push dx
    mov dx, GDC_T_STAT
    call gdc_wait_room
    out GDC_T_STAT, al
    pop dx
    ret

; Graphics GDC command / parameter.
ggdc_cmd:
    push dx
    mov dx, GDC_G_STAT
    call gdc_wait_room
    out GDC_G_CMD, al
    pop dx
    ret

ggdc_param:
    push dx
    mov dx, GDC_G_STAT
    call gdc_wait_room
    out GDC_G_STAT, al
    pop dx
    ret

; Send CX parameter bytes from CS:SI to the text (DX=60h) or graphics
; (DX=A0h) GDC.
gdc_params:
    push ax
    push cx
    push si
.next:
    call gdc_wait_room
    mov al, [cs:si]
    out dx, al
    inc si
    loop .next
    pop si
    pop cx
    pop ax
    ret

; Far entry points used by POST in the F000h bank.
far_kbd_init:
    call kbd_init
    retf
far_crt_set_mode:
    call crt_set_mode
    retf
far_text_fill:
    call text_fill
    retf
far_tgdc_cmd:
    call tgdc_cmd
    retf
far_tgdc_param:
    call tgdc_param
    retf
far_gdc_params:
    call gdc_params
    retf
far_gdc_wait_room:
    call gdc_wait_room
    retf
far_enter_unreal:
    call enter_unreal
    retf
