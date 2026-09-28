; INT 1Ch - timer and calendar BIOS.
;   AH=00h  read calendar into ES:BX (6 BCD bytes: year, month<<4|weekday,
;           day, hour, minute, second)
;   AH=01h  set calendar from ES:BX
;   AH=02h  start interval timer: CX ticks of 10 ms, then call ES:BX
;   AH=03h  continue interval timer (restart one 10 ms period)
; The uPD4990A is driven through port 20h (bits 0-2 command, 3 STB, 4 CLK,
; 5 DATA IN) and its serial output is read from port 33h bit 0.

RTC_STB         equ 08h
RTC_CLK         equ 10h
RTC_DIN         equ 20h
RTC_CMD_SHIFT   equ 01h
RTC_CMD_SET     equ 02h
RTC_CMD_READ    equ 03h

int1c_entry:
    sti
    cld
    push ds
    push es
    pusha
    mov bp, sp
    xor bx, bx
    mov ds, bx
    mov al, [bp+F_AH]
    cmp al, 00h
    je .read
    cmp al, 01h
    je .write
    cmp al, 02h
    je .start
    cmp al, 03h
    je .continue
    jmp .done
.read:
    mov es, [bp+F_ES]
    mov di, [bp+F_BX]
    call rtc_read
    jmp .done
.write:
    mov es, [bp+F_ES]
    mov si, [bp+F_BX]
    call rtc_write
    jmp .done
.start:
    cli
    mov ax, [bp+F_BX]
    mov [07h*4], ax
    mov ax, [bp+F_ES]
    mov [07h*4+2], ax
    mov ax, [bp+F_CX]
    mov [CA_TIM_CNT], ax
    mov al, 36h                    ; counter 0, LSB+MSB, mode 3
    out PIT_MODE, al
    sti
.continue:
    cli
    call pit_ten_ms
    out PIT_C0, al
    out CPU_RESET_WAIT, al
    mov al, ah
    out PIT_C0, al
    in al, PIC_M1
    and al, 0FEh                   ; unmask IRQ0
    out CPU_RESET_WAIT, al
    out PIC_M1, al
    sti
.done:
    popa
    pop es
    pop ds
    iret

; AX = PIT count for 10 ms (4E00h at 1.9968 MHz, 6000h at 2.4576 MHz).
pit_ten_ms:
    mov ax, 6000h
    test byte [BIOS_FLAG1], 80h
    jz .done
    mov ax, 4E00h
.done:
    ret

; Issue command AL to the uPD4990 (with a strobe pulse).
rtc_command:
    out RTC_OUT, al
    out CPU_RESET_WAIT, al
    or al, RTC_STB
    out RTC_OUT, al
    out CPU_RESET_WAIT, al
    and al, ~RTC_STB
    out RTC_OUT, al
    out CPU_RESET_WAIT, al
    ret

; Read 48 bits (LSB first: second, minute, hour, day, month|weekday, year)
; and store them at ES:DI in INT 1Ch order.
rtc_read:
    pushf
    cli
    mov al, RTC_CMD_READ
    call rtc_command
    mov al, RTC_CMD_SHIFT
    call rtc_command
    add di, 5                      ; seconds first -> last byte
    mov dx, 6
.byte:
    xor bl, bl
    mov cx, 8
.bit:
    in al, SYS_B
    shr al, 1                      ; CDAT -> CF
    rcr bl, 1
    mov al, RTC_CMD_SHIFT | RTC_CLK
    out RTC_OUT, al
    out CPU_RESET_WAIT, al
    mov al, RTC_CMD_SHIFT
    out RTC_OUT, al
    out CPU_RESET_WAIT, al
    loop .bit
    mov [es:di], bl
    dec di
    dec dx
    jnz .byte
    mov al, 0                      ; register hold
    call rtc_command
    popf
    ret

; Write the 6 INT 1Ch bytes at ES:SI to the calendar.
rtc_write:
    pushf
    cli
    mov al, [es:si]
    push ds
    push ax
    mov ax, MSW_SEG
    mov ds, ax
    mov al, 0Dh                    ; memory-switch write enable
    out MODE_FF1, al
    pop ax
    mov [MSW8], al                 ; year is also kept in memory switch 8
    mov al, 0Ch
    out MODE_FF1, al
    pop ds
    mov al, RTC_CMD_SHIFT
    call rtc_command
    add si, 5
    mov dx, 6
.byte:
    mov bl, [es:si]
    mov cx, 8
.bit:
    mov al, RTC_CMD_SHIFT
    shr bl, 1
    jnc .zero
    or al, RTC_DIN
.zero:
    out RTC_OUT, al
    out CPU_RESET_WAIT, al
    or al, RTC_CLK
    out RTC_OUT, al
    out CPU_RESET_WAIT, al
    and al, ~RTC_CLK
    out RTC_OUT, al
    loop .bit
    dec si
    dec dx
    jnz .byte
    mov al, RTC_CMD_SET
    call rtc_command
    mov al, 0
    call rtc_command
    popf
    ret
