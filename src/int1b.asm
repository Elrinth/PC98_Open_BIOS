; INT 1Bh - disk BIOS, floppy part.
;
; The hard disk is served by the core's disk extension ROM, which hooks this
; vector and chains every other device here.
;
; Floppy requests drive the core's uPD765 through the 8237 (see
; docs/CORE_HARDWARE.md, "Floppy"). Completion is detected from the FDC
; interrupt's IRR bit with CPU interrupts disabled, not by taking the
; interrupt: the core's 8259 never nests, so an interrupt-driven wait would
; deadlock when INT 1Bh is called from an ISR, and the FDC main status
; register looks like a result phase whenever a DMA byte is pending.
;
; AL = DA/UA: bits 7-4 device, bits 1-0 unit
;   90h  1 MB interface, 2HD         10h  1 MB interface, 2DD media
;   30h/B0h 1.44 MB mode (as 90h)    70h  640 KB interface, 2DD
;   F0h  640 KB interface, 2HD       50h  640 KB interface, 2D (double step)
; AH bits 3-0 command; bit 4 seek first, bit 5 skip deleted (SK),
; bit 6 MFM, bit 7 multi-track. CL=C, DH=H, DL=R, CH=N, BX=bytes, ES:BP=buffer.
; Returns AH = status (>= 20h is an error, CF set).
; Status codes and parameter tables follow NP2kai bios1b.c (BSD-3-Clause).

DISK_NOT_READY  equ 60h
FDC_TIMEOUT     equ 0FFFFh

; local frame (below the int18.asm-style register frame)
L_TYPE          equ -2          ; bit 0: 1 MB interface, bit 1: HD, bit 2: 2D
L_BASE          equ -4          ; FDC status port (90h / C8h)
L_CHAN          equ -6          ; DMA channel (2 / 3)
L_UNIT          equ -8          ; unit | head << 2
L_IMR           equ -10         ; saved slave IMR
L_ST            equ -18         ; 7 result bytes (ST0 ST1 ST2 C H R N)
L_DMA           equ -19         ; 1 armed, 2 stopped at terminal count
L_SEEK          equ -20         ; 1 while waiting for a seek
L_SIZE          equ 20

; Loaders call the disk BIOS on whatever stack they have, and some have very
; little: Metal Orange's PRECO-IPL keeps its sector table 58 bytes below its
; SS:SP, while a floppy request needs about 74 bytes (register frame, locals,
; nested calls) and overwrote the table's sector count. Requests therefore run
; on a private stack in this bank (boot.rom is writable SDRAM on the core,
; docs/CORE_HARDWARE.md); the caller's stack holds only its IRET frame and a
; word. A call made while already on it, from an interrupt during a request,
; runs in place.
int1b_entry:
    push ax
    mov ax, ss
    cmp ax, SEG_F800
    pop ax
    je int1b_body
    cli
    mov [cs:int1b_caller_sp], sp
    mov [cs:int1b_caller_ss], ss
    push cs
    pop ss
    mov sp, int1b_stack_top
    mov [cs:int1b_scratch], si
    mov [cs:int1b_scratch+2], ds
    lds si, [cs:int1b_caller_sp]
    push word [si+4]                ; the caller's FLAGS (result CF is set in it)
    push cs
    push word int1b_exit
    lds si, [cs:int1b_scratch]
    jmp int1b_body

; The body's IRET lands here with the result flags; copy CF into the caller's
; frame and return on its own stack.
int1b_exit:
    cli
    mov ss, [cs:int1b_caller_ss]
    mov sp, [cs:int1b_caller_sp]
    push bp
    mov bp, sp
    jc .error
    and byte [bp+6], 0FEh
    pop bp
    iret
.error:
    or byte [bp+6], 01h
    pop bp
    iret

int1b_body:
    sti
    cld
    push ds
    push es
    pusha
    mov bp, sp
    sub sp, L_SIZE
    xor bx, bx
    mov ds, bx
    mov al, [bp+F_AL]
    and al, 0F0h
    mov ah, 03h
    cmp al, 90h
    je .floppy
    cmp al, 30h
    je .floppy
    cmp al, 0B0h
    je .floppy
    mov ah, 01h
    cmp al, 10h
    je .floppy
    mov ah, 00h
    cmp al, 70h
    je .floppy
    mov ah, 02h
    cmp al, 0F0h
    je .floppy
    mov ah, 04h
    cmp al, 50h
    je .floppy
    mov al, DISK_NOT_READY        ; hard disk without the disk ROM, SCSI ...
    cmp byte [bp+F_AL], 80h
    je .status
    test byte [bp+F_AL], 0F0h
    jz .status
    mov al, 40h                    ; equipment check: no such device
    jmp .status
.floppy:
    mov [bp+L_TYPE], ah
    mov word [bp+L_SEEK], 0        ; L_SEEK and L_DMA
    mov al, DISK_NOT_READY
    test byte [bp+F_AL], 02h       ; only units 0 and 1 exist; commands on
    jnz .status                    ; units 2/3 can wedge the core's FDC
    call fd_select_interface
    call fd_mask_irq
    mov bl, [bp+F_AH]
    and bx, 0Fh
    add bx, bx
    call [cs:fd_table+bx]
    call fd_restore_irq
.status:
    mov [bp+F_AH], al
    and byte [bp+F_FLAGS], 0FEh
    cmp al, 20h
    jb .done
    or byte [bp+F_FLAGS], 01h
.done:
    mov sp, bp
    popa
    pop es
    pop ds
    iret

fd_table:
    dw fd_seek          ; 0 seek
    dw fd_verify        ; 1 verify
    dw fd_read_diag     ; 2 read diagnostic (read track)
    dw fd_init          ; 3 initialise
    dw fd_sense         ; 4 sense
    dw fd_write         ; 5 write data
    dw fd_read          ; 6 read data
    dw fd_recalibrate   ; 7 recalibrate
    dw fd_bad           ; 8
    dw fd_write_deleted ; 9 write deleted data
    dw fd_read_id       ; A read ID
    dw fd_bad           ; B
    dw fd_read_deleted  ; C read deleted data
    dw fd_format        ; D format track
    dw fd_mode          ; E set density / sides mode
    dw fd_bad           ; F

fd_bad:
    mov al, 40h
    ret

; ---------------------------------------------------------------- setup
; Select the interface and density (port BEh) for L_TYPE and set the port
; base, DMA channel and unit/head byte.
fd_select_interface:
    mov al, [bp+L_TYPE]
    and al, 03h
    out 0BEh, al
    mov word [bp+L_BASE], 90h
    mov word [bp+L_CHAN], 2
    test al, 1
    jnz .unit
    mov word [bp+L_BASE], 0C8h
    mov word [bp+L_CHAN], 3
.unit:
    ; head = (DH ^ (AL >> 2)) & 1, as on NEC machines
    mov al, [bp+F_AL]
    mov ah, al
    shr ah, 2
    xor ah, [bp+F_DH]
    and ah, 1
    shl ah, 2
    and al, 3
    or al, ah
    mov [bp+L_UNIT], al
    ; drive ready (FRY), motor on
    mov dx, [bp+L_BASE]
    add dx, 4
    mov al, 48h
    out dx, al
    ret

; Keep the FDC interrupt line unmasked (so its IRR bit is visible) but run
; with CPU interrupts disabled; the saved slave IMR is restored at the end.
fd_mask_irq:
    in al, PIC_S1
    mov [bp+L_IMR], al
    mov ah, 0F7h                   ; IRQ11 (1 MB interface)
    test byte [bp+L_TYPE], 01h
    jnz .unmask
    mov ah, 0FBh                   ; IRQ10 (640 KB interface)
.unmask:
    and al, ah
    out CPU_RESET_WAIT, al
    out PIC_S1, al
    ret

fd_restore_irq:
    push ax
    mov al, [bp+L_IMR]
    out PIC_S1, al
    pop ax
    ret

; AH = IRR bit of the FDC line on the slave PIC.
fd_irq_bit:
    mov ah, 08h
    test byte [bp+L_TYPE], 01h
    jnz .done
    mov ah, 04h
.done:
    ret

; Let an already latched FDC interrupt be taken (and acknowledged by
; int13_fdd_irq) before a new command, so its IRR bit starts clear. In an
; ISR context the 8259 cannot deliver it; fd_wait_irq then also checks the
; FDC status.
fd_flush_irq:
    push cx
    sti
    mov cx, 200
.pause:
    out CPU_RESET_WAIT, al
    loop .pause
    cli
    pop cx
    ret

; AX = timestamp (3.26 us units, low 16 bits of port 5Ch).
fd_now:
    in ax, 5Ch
    ret

; Wait for the FDC interrupt (end of command or seek). With DMA active,
; stop the channel as soon as it reaches terminal count so that a partial
; last sector cannot run past the buffer. CF=1 after about 3 s.
fd_wait_irq:
    push bx
    push cx
    push dx
    push si
    call fd_irq_bit
    mov dl, ah
    mov si, 16                     ; 16 windows of ~200 ms
    call fd_now
    mov bx, ax
.poll:
    cmp byte [bp+L_DMA], 0
    je .irr
    in al, 11h
    mov cl, [bp+L_CHAN]
    mov ah, 1
    shl ah, cl
    test al, ah
    jz .irr
    mov al, cl
    or al, 04h
    out 15h, al                    ; TC: stop the channel
    mov byte [bp+L_DMA], 2         ; 2: stopped at terminal count
.irr:
    mov al, 0Ah                    ; OCW3: read IRR
    out PIC_S0, al
    out CPU_RESET_WAIT, al
    in al, PIC_S0
    test al, dl
    jz .time
    ; A data command must also be in its result phase (RQM, DIO, CB);
    ; seeks have no result phase.
    cmp byte [bp+L_SEEK], 0
    jne .ok
    push dx
    mov dx, [bp+L_BASE]
    in al, dx
    pop dx
    and al, 0D0h
    cmp al, 0D0h
    je .ok
.time:
    call fd_now
    sub ax, bx
    cmp ax, 0F000h
    jb .poll
    call fd_now
    mov bx, ax
    dec si
    jnz .poll
    stc
    jmp .done
.ok:
    clc
.done:
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ---------------------------------------------------------------- FDC I/O
; Send AL to the FDC. CF=1 on timeout.
fd_out:
    push cx
    push dx
    push ax
    mov dx, [bp+L_BASE]
    mov cx, FDC_TIMEOUT
.wait:
    in al, dx
    and al, 0C0h
    cmp al, 80h                    ; RQM, CPU -> FDC
    je .send
    out CPU_RESET_WAIT, al
    loop .wait
    pop ax
    stc
    jmp .done
.send:
    pop ax
    add dx, 2
    out dx, al
    clc
.done:
    pop dx
    pop cx
    ret

; Read one result byte into AL. CF=1 when the FDC does not offer one.
fd_in:
    push cx
    push dx
    mov dx, [bp+L_BASE]
    mov cx, FDC_TIMEOUT
.wait:
    in al, dx
    and al, 0C0h
    cmp al, 0C0h                   ; RQM, FDC -> CPU
    je .get
    cmp al, 80h                    ; RQM, CPU -> FDC: nothing more
    je .none
    out CPU_RESET_WAIT, al
    loop .wait
.none:
    stc
    jmp .done
.get:
    add dx, 2
    in al, dx
    clc
.done:
    pop dx
    pop cx
    ret

; Wait for the end of a data command. CF=1 on timeout.
fd_wait_result:
    mov byte [bp+L_SEEK], 0
    jmp fd_wait_irq

; Read up to 7 result bytes into L_ST.
fd_results:
    push cx
    push di
    lea di, [bp+L_ST]
    mov cx, 7
.next:
    call fd_in
    jc .end
    mov [ss:di], al
    inc di
    loop .next
.end:
    pop di
    pop cx
    ret

; Wait for the seek/recalibrate of this unit to end, then SENSE INTERRUPT.
; No command is sent while the drive steps: the core drops a seek-end
; interrupt that coincides with another command. Without an interrupt (ISR
; context with a stale latch) the sense follows the timeout, when any seek
; has long finished. Returns AL = ST0, AH = PCN, CF on error.
fd_wait_seek:
    push cx
    push si
    mov byte [bp+L_SEEK], 1
    call fd_wait_irq
    mov byte [bp+L_SEEK], 0
    mov si, 4
.again:
    mov al, 08h
    call fd_out
    jc .fail
    call fd_in
    jc .fail
    mov cl, al
    cmp al, 80h                    ; no interrupt pending
    je .retry
    call fd_in
    mov ah, al
    mov al, cl
    mov ch, [bp+L_UNIT]
    xor ch, al
    test ch, 03h
    jnz .retry                     ; another unit
    test al, 20h                   ; SE
    jz .retry                      ; status of an earlier command
    clc
    jmp .done
.retry:
    dec si
    jnz .again
.fail:
    stc
.done:
    pop si
    pop cx
    ret

; Drain pending interrupt status (after a reset or a stray seek).
fd_drain:
    push cx
    mov cx, 8
.next:
    mov al, 08h
    call fd_out
    jc .done
    call fd_in
    jc .done
    cmp al, 80h
    je .done
    call fd_in
    loop .next
.done:
    pop cx
    ret

; Seek to the cylinder in CL (doubled for 2D media). AL = status.
fd_do_seek:
    call fd_flush_irq
    mov al, 0Fh
    call fd_out
    jc .timeout
    mov al, [bp+L_UNIT]
    call fd_out
    mov al, [bp+F_CL]
    test byte [bp+L_TYPE], 04h
    jz .cyl
    add al, al
.cyl:
    call fd_out
    call fd_wait_seek
    jc .timeout
    test al, 0C0h
    jnz .error
    xor al, al
    ret
.error:
    test al, 08h                   ; NR
    jnz .not_ready
    mov al, 0E0h
    ret
.not_ready:
    mov al, DISK_NOT_READY
    ret
.timeout:
    mov al, 90h
    ret

; ZF=1 if the drive reports ready. Leaves ST3 in AL.
fd_drive_status:
    mov al, 04h
    call fd_out
    jc .nr
    mov al, [bp+L_UNIT]
    call fd_out
    call fd_in
    jc .nr
    test al, 20h
    jz .nr
    cmp al, al
    ret
.nr:
    or al, 0FFh                    ; ZF=0
    ret

; ---------------------------------------------------------------- DMA
; Program the DMA channel for ES:BP, BX bytes. AL = mode bits (44h write
; to memory, 48h read from memory, 40h verify). AL = 20h on a 64 KiB
; boundary crossing, else 0.
fd_setup_dma:
    push eax                       ; keep the caller's upper halves
    push ebx
    push ecx
    push edx
    push edi
    mov ah, al
    movzx edi, word [bp+F_ES]
    shl edi, 4
    movzx ecx, word [bp+F_BP]
    add edi, ecx                   ; physical buffer address
    movzx ecx, word [bp+F_BX]
    test ecx, ecx
    jnz .size
    mov ecx, 10000h
.size:
    mov edx, edi
    and edx, 0FFFFh
    add edx, ecx
    cmp edx, 10000h
    ja .boundary
    mov bx, [bp+L_CHAN]
    mov al, bl
    or al, 04h
    out 15h, al                    ; mask the channel
    out CPU_RESET_WAIT, al
    mov al, 44h                    ; hold the byte flip-flops cleared;
    out 11h, al                    ; bit 6 (DACK active high) must stay set
    out CPU_RESET_WAIT, al
    mov al, 40h
    out 11h, al
    out CPU_RESET_WAIT, al
    mov al, ah
    or al, bl
    out 17h, al                    ; mode
    ; address port 01h + 4n, count port 03h + 4n, bank 27h/21h/23h/25h
    mov dx, bx
    shl dx, 2
    inc dx
    mov ax, di
    out dx, al
    out CPU_RESET_WAIT, al
    mov al, ah
    out dx, al
    add dx, 2
    dec cx
    mov al, cl
    out dx, al
    out CPU_RESET_WAIT, al
    mov al, ch
    out dx, al
    mov dx, 21h
    cmp bx, 2
    jb .bank
    mov dx, 23h
    je .bank
    mov dx, 25h
.bank:
    mov eax, edi
    shr eax, 16
    out dx, al
    mov al, bl
    out 15h, al                    ; unmask
    mov byte [bp+L_DMA], 1
    xor al, al
    jmp .done
.boundary:
    mov al, 20h
.done:
    pop edi
    pop edx
    pop ecx
    pop ebx
    push bx
    mov bx, sp
    mov [ss:bx+2], al              ; AL = result, rest of EAX restored
    pop bx
    pop eax
    ret

fd_stop_dma:
    push ax
    mov al, [bp+L_CHAN]
    or al, 04h
    out 15h, al
    pop ax
    ret

; ---------------------------------------------------------------- tables
; AL = EOT (or SC when fd_param_fmt), AH = GPL for the current N/MF.
; Uses the far pointer at 05F8h (2HD) or 05CCh (2DD) so that software which
; installs its own tables is honoured. Table: 4 unit words -> 32-byte table,
; rows by N (0-3) of MFM(EOT,GPL,SC,GPL) FM(EOT,GPL,SC,GPL).
fd_param:
    xor si, si
    jmp fd_param_common
fd_param_fmt:
    mov si, 2
fd_param_common:
    push bx
    push es
    mov bx, F2DD_POINTER
    test byte [bp+L_TYPE], 02h
    jz .ptr
    mov bx, F2HD_POINTER
.ptr:
    les bx, [bx]
    mov al, [bp+F_AL]
    and ax, 3
    add ax, ax
    add bx, ax
    mov bx, [es:bx]
    mov al, [bp+F_CH]
    cmp al, 3
    jbe .n
    mov al, 3
.n:
    xor ah, ah
    shl ax, 3
    add bx, ax
    test byte [bp+F_AH], 40h
    jnz .mfm
    add bx, 4
.mfm:
    add bx, si
    mov ax, [es:bx]
    pop es
    pop bx
    ret

fd_units_2hd: dw fdfmt_2hd, fdfmt_2hd, fdfmt_2hd, fdfmt_2hd
fd_units_2dd: dw fdfmt_2dd, fdfmt_2dd, fdfmt_2dd, fdfmt_2dd
fdfmt_2hd:
    db 00h,00h, 00h,00h,  1Ah,07h, 1Ah,1Bh    ; N=0
    db 1Ah,0Eh, 1Ah,36h,  0Fh,0Eh, 0Fh,2Ah    ; N=1
    db 0Fh,1Bh, 0Fh,50h,  08h,1Bh, 08h,3Ah    ; N=2
    db 08h,35h, 08h,74h,  00h,00h, 00h,00h    ; N=3
fdfmt_2dd:
    db 00h,00h, 00h,00h,  10h,07h, 10h,1Bh
    db 10h,0Eh, 10h,36h,  09h,0Eh, 09h,2Ah
    db 09h,2Ah, 09h,50h,  05h,1Bh, 05h,3Ah
    db 05h,35h, 05h,74h,  00h,00h, 00h,00h

; ---------------------------------------------------------------- results
; Map the result bytes in L_ST to a BIOS status in AL. DMA TC (all bytes
; moved) turns an end-of-cylinder termination into success.
fd_map_result:
    mov al, [bp+L_ST]              ; ST0
    mov ah, al
    and ah, 0C0h
    jz .ok
    test al, 08h                   ; NR
    jnz .not_ready
    cmp ah, 40h
    jne .not_ready                 ; invalid command / ready change
    mov ah, [bp+L_ST+1]            ; ST1
    test ah, 80h                   ; EN: ran past EOT
    jz .st1
    test ah, 7Fh
    jnz .st1
    cmp byte [bp+L_DMA], 2
    je .ok
    mov al, [bp+L_CHAN]
    call fd_tc_reached
    jnz .ok
    mov al, 30h
    ret
.st1:
    test ah, 02h
    jnz .protect
    test ah, 10h
    jz .no_overrun
    cmp byte [bp+L_DMA], 2         ; overrun after terminal count stopped the
    je .ok                         ; channel (partial last sector): complete
    jmp .overrun
.no_overrun:
    test ah, 20h
    jnz .crc
    test ah, 04h
    jnz .no_data
    test ah, 01h
    jnz .missing_am
    mov ah, [bp+L_ST+2]            ; ST2
    test ah, 12h                   ; WC / BC
    jnz .bad_cyl
    test ah, 40h                   ; CM: deleted data encountered
    jnz .ok
    mov al, 80h
    ret
.ok:
    xor al, al
    ret
.not_ready:
    mov al, DISK_NOT_READY
    ret
.protect:
    mov al, 70h
    ret
.overrun:
    mov al, 50h
    ret
.crc:
    mov al, 0A0h
    test byte [bp+L_ST+2], 20h     ; DD: data field CRC
    jz .crc_done
    mov al, 0B0h
.crc_done:
    ret
.no_data:
    mov al, 0C0h
    ret
.bad_cyl:
    mov al, 0D0h
    ret
.missing_am:
    mov al, 0E0h
    test byte [bp+L_ST+2], 01h     ; MD
    jz .am_done
    mov al, 0F0h
.am_done:
    ret

; ZF=0 if DMA channel AL reached terminal count.
fd_tc_reached:
    push cx
    mov cl, al
    in al, 11h
    mov ah, 1
    shl ah, cl
    test al, ah
    pop cx
    ret

; Save results (ST0..N, NCN) at 0564h + unit * 8.
fd_store_results:
    push ax
    push bx
    push cx
    push si
    movzx bx, byte [bp+F_AL]
    and bx, 3
    shl bx, 3
    lea si, [bp+L_ST]
    mov cx, 7
.copy:
    mov al, [ss:si]
    mov [DISK_RESULT+bx], al
    inc si
    inc bx
    loop .copy
    pop si
    pop cx
    pop bx
    pop ax
    ret

; ---------------------------------------------------------------- commands
; Common front end for data commands: optional seek, returns CF=1 with AL
; set on failure.
fd_prologue:
    call fd_drive_status
    jz .ready
    mov al, DISK_NOT_READY
    stc
    ret
.ready:
    test byte [bp+F_AH], 10h
    jz .ok
    call fd_do_seek
    test al, al
    jz .ok
    stc
    ret
.ok:
    clc
    ret

; Issue a data command. AL = FDC opcode (low 5 bits), DL = DMA mode.
fd_transfer:
    push dx
    push ax
    call fd_prologue
    pop dx                         ; DL = opcode
    jc .fail
    mov ah, dl
    pop dx
    mov al, ah
    push ax
    mov al, dl
    call fd_setup_dma
    mov dl, al
    pop ax
    test dl, dl
    jz .go
    mov al, dl                     ; DMA boundary
    ret
.go:
    call fd_flush_irq
    mov ah, [bp+F_AH]
    and ah, 0E0h                   ; MT, MF, SK
    or al, ah
    call fd_out
    jc .timeout
    mov al, [bp+L_UNIT]
    call fd_out
    mov al, [bp+F_CL]              ; C
    call fd_out
    mov al, [bp+F_DH]              ; H
    call fd_out
    mov al, [bp+F_DL]              ; R
    call fd_out
    mov al, [bp+F_CH]              ; N
    call fd_out
    call fd_param                  ; AL = EOT, AH = GPL
    push ax
    call fd_out
    pop ax
    mov al, ah
    call fd_out
    mov al, 0FFh                   ; DTL
    cmp byte [bp+F_CH], 0
    jne .dtl
    mov al, 80h
.dtl:
    call fd_out
    jc .timeout
    call fd_wait_result
    jc .timeout
    call fd_results
    call fd_stop_dma
    call fd_store_results
    jmp fd_map_result
.timeout:
    call fd_stop_dma
    mov al, 90h
    ret
.fail:
    pop dx
    ret

fd_read:
    mov al, 06h
    mov dl, 44h                    ; single mode, write to memory
    jmp fd_transfer

fd_read_deleted:
    mov al, 0Ch
    mov dl, 44h
    jmp fd_transfer

fd_read_diag:
    mov al, 02h
    mov dl, 44h
    call fd_transfer
    cmp al, 0C0h                   ; diagnostic reads report data as found
    jne .done
    xor al, al
.done:
    ret

; Verify: the core's DMA verify mode does not work, so read the sectors one
; at a time into a scratch buffer at A600:0000 (RAM that nothing else uses on
; this core) and discard them. Caller registers are restored afterwards.
VERIFY_SEG      equ 0A600h
fd_verify:
    push word [bp+F_ES]
    push word [bp+F_BP]
    push word [bp+F_BX]
    push word [bp+F_CX]
    push word [bp+F_DX]
    push word [bp+F_AX]
    mov si, [bp+F_BX]              ; bytes left
    mov cl, [bp+F_CH]
    and cl, 07h
    mov di, 128
    shl di, cl                     ; sector size
    mov word [bp+F_ES], VERIFY_SEG
    mov word [bp+F_BP], 0
.sector:
    test si, si
    jz .ok
    mov [bp+F_BX], di
    push si
    push di
    mov al, 06h
    mov dl, 44h
    call fd_transfer
    pop di
    pop si
    test al, al
    jnz .done
    and byte [bp+F_AH], 0EFh       ; seek only before the first sector
    sub si, di
    jbe .ok
    ; next sector: R + 1; after EOT continue on head 1 (MT) or stop
    call fd_param
    cmp [bp+F_DL], al
    jae .end_of_track
    inc byte [bp+F_DL]
    jmp .sector
.end_of_track:
    test byte [bp+F_AH], 80h
    jz .past_end
    test byte [bp+L_UNIT], 04h
    jnz .past_end
    mov byte [bp+F_DL], 1
    or byte [bp+F_DH], 1
    or byte [bp+L_UNIT], 04h
    jmp .sector
.past_end:
    mov al, 30h                    ; end of cylinder
    jmp .done
.ok:
    xor al, al
.done:
    pop word [bp+F_AX]
    pop word [bp+F_DX]
    pop word [bp+F_CX]
    pop word [bp+F_BX]
    pop word [bp+F_BP]
    pop word [bp+F_ES]
    ret

fd_write:
    mov al, 05h
    mov dl, 48h                    ; single mode, read from memory
    jmp fd_transfer

fd_write_deleted:
    mov al, 09h
    mov dl, 48h
    jmp fd_transfer

fd_seek:
    call fd_drive_status
    jnz .nr
    test byte [bp+F_AH], 10h
    jz .ok
    jmp fd_do_seek
.ok:
    xor al, al
    ret
.nr:
    mov al, DISK_NOT_READY
    ret

fd_recalibrate:
    call fd_drive_status
    jnz fd_recal_nr
fd_recal_unit:
    call fd_flush_irq
    mov al, 07h
    call fd_out
    mov al, [bp+L_UNIT]
    and al, 03h
    call fd_out
    call fd_wait_seek
    jc .timeout
    test al, 0C0h
    jnz .error
    xor al, al
    ret
.error:
    mov al, 0E0h
    ret
.timeout:
    mov al, 90h
    ret
fd_recal_nr:
    mov al, DISK_NOT_READY
    ret

fd_read_id:
    call fd_prologue
    jc .ret
    call fd_flush_irq
    mov al, 0Ah
    mov ah, [bp+F_AH]
    and ah, 40h
    or al, ah
    call fd_out
    mov al, [bp+L_UNIT]
    call fd_out
    jc .timeout
    call fd_wait_result
    jc .timeout
    call fd_results
    call fd_store_results
    call fd_map_result
    test al, al
    jnz .ret
    mov ah, [bp+L_ST+3]
    mov [bp+F_CL], ah
    mov ah, [bp+L_ST+4]
    mov [bp+F_DH], ah
    mov ah, [bp+L_ST+5]
    mov [bp+F_DL], ah
    mov ah, [bp+L_ST+6]
    mov [bp+F_CH], ah
.ret:
    ret
.timeout:
    mov al, 90h
    ret

; Format one track: ES:BP -> C,H,R,N per sector, CH = N, DL = fill byte.
fd_format:
    call fd_prologue
    jc .ret
    call fd_param_fmt              ; AL = SC, AH = GPL
    test al, al
    jz .bad
    push ax
    movzx cx, al
    shl cx, 2
    push word [bp+F_BX]
    mov [bp+F_BX], cx
    mov al, 48h
    call fd_setup_dma
    pop word [bp+F_BX]
    mov dl, al
    pop cx                         ; CL = SC, CH = GPL
    test dl, dl
    jnz .dma_error
    call fd_flush_irq
    mov al, 0Dh
    mov ah, [bp+F_AH]
    and ah, 40h
    or al, ah
    call fd_out
    mov al, [bp+L_UNIT]
    call fd_out
    mov al, [bp+F_CH]
    call fd_out
    mov al, cl
    call fd_out
    mov al, ch
    call fd_out
    mov al, [bp+F_DL]
    call fd_out
    jc .timeout
    call fd_wait_result
    jc .timeout
    call fd_results
    call fd_stop_dma
    call fd_store_results
    jmp fd_map_result
.dma_error:
    mov al, dl
    ret
.bad:
    mov al, 0D0h
.ret:
    ret
.timeout:
    call fd_stop_dma
    mov al, 90h
    ret

; Sense: AH = 10h write protected | 01h 2HD capable | 08h dual-mode drive.
fd_sense:
    call fd_drive_status
    jz .ready
    mov al, DISK_NOT_READY
    jmp .dual
.ready:
    mov ah, al                     ; ST3
    xor al, al
    test ah, 40h                   ; WP
    jz .wp
    mov al, 10h
.wp:
    test byte [bp+F_AL], 80h
    jz .dd
    or al, 01h
    jmp .dual
.dd:
    mov bx, F2DD_MODE
    mov cl, [bp+F_AL]
    and cl, 3
    mov ah, 01h
    shl ah, cl
    test [bx], ah
    jz .dd_sides
    or al, 01h
.dd_sides:
    shl ah, 4
    test [bx], ah
    jz .dual
    or al, 04h
.dual:
    mov ah, [bp+F_AH]
    and ah, 8Fh
    cmp ah, 84h                    ; AH=84h asks for drive capabilities
    jne .done
    test byte [bp+F_AL], 40h
    jnz .done
    or al, 08h
.done:
    ret

; Initialise: specify, recalibrate units 0 and 1 (the emulated drives
; start at an unknown cylinder), publish the drives in DISK_EQUIP.
fd_init:
    call fd_reset_controller
    mov al, [bp+L_UNIT]
    push ax
    mov byte [bp+L_UNIT], 0
    call fd_recal_unit
    mov byte [bp+L_UNIT], 1
    call fd_recal_unit
    pop ax
    mov [bp+L_UNIT], al
    mov ax, [DISK_EQUIP]
    test byte [bp+L_TYPE], 01h
    jz .low
    and ax, 0FFF0h
    or ax, 0003h
    jmp .set
.low:
    and ax, 0FFFh
    or ax, 3000h
.set:
    mov [DISK_EQUIP], ax
    xor al, al
    ret

; The core's FDC cannot be reset by software (94h bit 7 only resets its
; timing tick). Drain pending status, then program step rate and DMA mode.
fd_reset_controller:
    call fd_flush_irq
    call fd_drain
    mov al, 03h                    ; SPECIFY
    call fd_out
    mov al, 0F1h                   ; SRT = Fh (fastest), HUT = 1
    call fd_out
    mov al, 1Ah                    ; HLT = 0Dh, DMA mode
    call fd_out
    ret

; E: AH bit 7 = 1 sets density bits (upper nibble), else sides (lower).
fd_mode:
    mov bx, F2DD_MODE
    test byte [bp+L_TYPE], 01h
    jz .table
    mov bx, F2HD_MODE
.table:
    mov ah, [bp+F_AH]
    mov al, [bx]
    test ah, 80h
    jz .sides
    and al, 0Fh
    shl ah, 4
    or al, ah
    jmp .store
.sides:
    and al, 0F0h
    and ah, 0Fh
    or al, ah
.store:
    mov [bx], al
    xor al, al
    ret

; ---------------------------------------------------------------- IRQ
; IRQ11 (INT 13h, 1 MB interface) / IRQ10 (INT 12h, 640 KB interface):
; the BIOS polls, so only record the event for software that checks the
; DISK_INTL/DISK_INTH flags, then acknowledge.
int13_fdd_irq:
    push ax
    push ds
    xor ax, ax
    mov ds, ax
    or byte [DISK_INTL], 0Fh
    pop ds
    pop ax
    jmp irq_slave_eoi

int12_fdd_irq:
    push ax
    push ds
    xor ax, ax
    mov ds, ax
    or byte [DISK_INTH], 0F0h
    pop ds
    pop ax
    jmp irq_slave_eoi
