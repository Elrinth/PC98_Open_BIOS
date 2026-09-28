; Power-on self test and machine initialisation (F000h bank).
; Entered from the reset vector with the CPU in real mode.

post_entry:
    cli
    cld
    ; Shutdown resume: software that resets the CPU to leave protected mode
    ; clears SHUT0 (port 35h bit 7) and leaves SS:SP at 0404h. It expects a
    ; far return through that stack.
    in al, SYS_C
    test al, 80h
    jnz cold_start
    ; The core resets only the CPU on F0h: PICs, PIT, RAM and the program's
    ; interrupt masks are intact and must not be touched here.
    xor ax, ax
    mov ds, ax
    mov ss, [SHUT_SS]
    mov sp, [SHUT_SP]
    retf

cold_start:
    ; Leave the ITF bank: F8000h-FFFFFh becomes the BIOS bank (identical
    ; contents in this BIOS). The core decodes the odd byte port 43Dh.
    mov dx, ITF_BANK
    mov al, 12h
    out dx, al
    xor ax, ax
    mov ss, ax
    mov sp, 0600h                  ; interim stack inside the vector area
    mov ds, ax
    mov es, ax

    call init_chips
    call init_memory_clear
    mov sp, 7C00h
    call init_vectors
    call kbd_init_far
    call init_memory_switches
    call init_workarea
    call count_extended_memory
    call init_screen

    ; SHUT0 = SHUT1 = 1: later resets are ordinary resets.
    mov al, 0Fh
    out SYS_CTRL, al
    mov al, 0Bh
    out SYS_CTRL, al

    call post_banner
    call extrom_scan
    sti
    jmp boot_restart

; ---------------------------------------------------------------- chips
iodata:
    ; DMA: bank registers, mask all channels, command
    db 29h,00h, 29h,01h, 29h,02h, 29h,03h
    db 27h,00h, 21h,00h, 23h,00h, 25h,00h
    ; hold, then release the byte flip-flops; the core needs command bit 6
    ; (DACK active high) or its FDC sees a permanent DACK
    db 11h,44h, 11h,40h
    ; 1 MB floppy interface, 2HD rate; drive ready from the drive, motors on
    db 0BEh,03h, 94h,48h
    ; PIT: counter 0 mode 0 (stopped), counter 1 beep 2 kHz, counter 2 RS-232C
    db 77h,30h, 71h,00h, 71h,00h
    db 77h,76h, 73h,0CDh, 73h,04h
    db 77h,0B6h
    ; beep off, printer strobe high
    db 37h,07h
IODATA_COUNT equ ($-iodata)/2

init_chips:
    mov si, iodata
    mov cx, IODATA_COUNT
.next:
    mov dl, [cs:si]
    xor dh, dh
    mov al, [cs:si+1]
    out dx, al
    out CPU_RESET_WAIT, al
    add si, 2
    loop .next
    call init_pics
    call init_gdcs
    ret

; 8259 pair: master base 08h (cascade on IR7), slave base 10h.
init_pics:
    mov al, 11h
    out PIC_M0, al
    out CPU_RESET_WAIT, al
    mov al, 08h
    out PIC_M1, al
    out CPU_RESET_WAIT, al
    mov al, 80h
    out PIC_M1, al
    out CPU_RESET_WAIT, al
    mov al, 1Dh                    ; special fully nested, buffered master
    out PIC_M1, al
    out CPU_RESET_WAIT, al
    mov al, 11h
    out PIC_S0, al
    out CPU_RESET_WAIT, al
    mov al, 10h
    out PIC_S1, al
    out CPU_RESET_WAIT, al
    mov al, 07h
    out PIC_S1, al
    out CPU_RESET_WAIT, al
    mov al, 09h                    ; buffered slave
    out PIC_S1, al
    out CPU_RESET_WAIT, al
    mov al, 7Dh                    ; enable IRQ1 (keyboard) and IRQ7 (cascade)
    out PIC_M1, al
    out CPU_RESET_WAIT, al
    mov al, 0F7h                   ; enable IRQ11 (1 MB FDC)
    out PIC_S1, al
    ret

; uPD7220 SYNC parameters for 24 kHz: text 640x400, graphics 200-line.
sync_text24:  db 10h, 4Eh, 07h, 25h, 07h, 07h, 90h, 65h
sync_graph24: db 06h, 26h, 03h, 11h, 83h, 07h, 90h, 65h
text_scroll:  db 00h, 00h, 00h, 19h       ; SAD 0, 400 lines
graph_scroll: db 00h, 00h, 0F0h, 3Fh      ; SAD 0, full length

init_gdcs:
    ; text GDC
    mov al, GDC_RESET
    out GDC_T_CMD, al
    mov dx, GDC_T_STAT
    mov si, sync_text24
    mov cx, 8
    call gdc_params_far
    mov al, GDC_PITCH
    call tgdc_cmd_far
    mov al, 80
    call tgdc_param_far
    mov al, GDC_SCROLL
    call tgdc_cmd_far
    mov si, text_scroll
    mov cx, 4
    call gdc_params_far
    mov al, GDC_CSRW
    call tgdc_cmd_far
    xor al, al
    call tgdc_param_far
    call tgdc_param_far
    call tgdc_param_far
    ; graphics GDC
    mov al, GDC_RESET
    out GDC_G_CMD, al
    mov dx, GDC_G_STAT
    mov si, sync_graph24
    mov cx, 8
    call gdc_params_far
    mov al, GDC_PITCH
    out GDC_G_CMD, al
    mov al, 40
    call gdc_param_g
    mov al, GDC_SCROLL
    out GDC_G_CMD, al
    mov si, graph_scroll
    mov cx, 4
    call gdc_params_far
    ; Two raster lines per graphics row: the 200-line picture is shown
    ; line-doubled on the 400-line screen (INT 18h AH=42h switches it).
    mov al, GDC_CSRFORM
    out GDC_G_CMD, al
    mov al, 01h
    call gdc_param_g
    xor al, al
    call gdc_param_g
    call gdc_param_g
    mov al, GDC_STOP
    out GDC_G_CMD, al
    ; Mode flip-flop 1: display off while programming, 7x13 font,
    ; 200-line graphics, KCG code access, memory switches write-protected.
    mov al, 0Eh
    out MODE_FF1, al
    mov al, 07h
    out MODE_FF1, al
    mov al, 09h
    out MODE_FF1, al
    mov al, 0Ah
    out MODE_FF1, al
    mov al, 0Ch
    out MODE_FF1, al
    mov al, 00h
    out MODE_FF1, al
    mov al, 02h                    ; monochrome graphics until INT 18h 42h
    out MODE_FF1, al
    mov al, 04h                    ; 80 columns
    out MODE_FF1, al
    ; (after the GDC resets, which clear the flip-flops)
    ; CRTC for 25-line 400-line text
    mov al, 00h
    out CRTC_PL, al
    mov al, 0Fh
    out CRTC_BL, al
    mov al, 10h
    out CRTC_CL, al
    xor al, al
    out CRTC_SSL, al
    out CRTC_SUR, al
    out CRTC_SDR, al
    ; digital palette defaults (colour n = n)
    mov al, 04h
    out PAL_AE, al
    mov al, 15h
    out PAL_AA, al
    mov al, 26h
    out PAL_AC, al
    mov al, 37h
    out PAL_A8, al
    ; graphics pages 0/0
    xor al, al
    out GR_DISP_PAGE, al
    out GR_DRAW_PAGE, al
    ret

gdc_param_g:
    push dx
    mov dx, GDC_G_STAT
    call gdc_wait_room_far
    out dx, al
    pop dx
    ret

; ---------------------------------------------------------------- memory
; Clear conventional memory above the interim stack page, text VRAM codes
; and attributes (not the memory switches) and graphics VRAM.
init_memory_clear:
    push es
    xor eax, eax
    ; 0000:0000-0000:05FF is cleared later by init_vectors/init_workarea.
    mov bx, 0060h
.para64k:
    mov es, bx
    xor di, di
    mov cx, 4000h
    rep stosd
    add bx, 1000h
    cmp bx, 0A060h
    jb .para64k
    ; graphics planes: A8000-BFFFF and E0000-E7FFF
    mov bx, 0A800h
.gvram:
    mov es, bx
    xor di, di
    mov cx, 2000h
    rep stosd
    add bx, 0800h
    cmp bx, 0C000h
    jb .gvram
    mov ax, 0E000h
    mov es, ax
    xor di, di
    xor eax, eax
    mov cx, 2000h
    rep stosd
    pop es
    ret

; Vectors 00h-1Fh from the resident table, 20h-FFh to IRET, 1Eh to the
; BASIC stub. Clears the work area 0400h-05FFh.
init_vectors:
    push ds
    push es
    xor ax, ax
    mov es, ax
    xor di, di
    mov cx, 100h
.fill:
    mov ax, iret_stub
    stosw
    mov ax, SEG_F800
    stosw
    loop .fill
    mov ax, SEG_F800
    mov ds, ax
    mov si, vector_table
    xor di, di
    mov cx, VECTOR_COUNT
.set:
    movsw
    add di, 2
    loop .set
    mov word [es:1Eh*4], basic_entry
    mov word [es:1Eh*4+2], SEG_E800
    ; INT A0h-AFh: LIO graphics BIOS in the E800h bank
    mov ax, SEG_E800
    mov ds, ax
    mov si, lio_vectors
    mov di, 0A0h*4
    mov cx, 16
.lio:
    movsw
    mov [es:di], ax
    add di, 2
    loop .lio
    mov di, 0400h
    xor ax, ax
    mov cx, 100h
    rep stosw
    pop es
    pop ds
    ret

; Count RAM above 1 MB in 1 MB steps with unreal-mode accesses. The PC-98
; map has a 1 MB aperture at 15-16 MB; RAM above it is reported at 0594h.
count_extended_memory:
    push es
    pushf
    cli
    in al, A20_ON                  ; bit 0 = 1: A20 masked
    push ax
    out A20_ON, al                 ; enable A20
    call enter_unreal_far
    mov ebx, 1                     ; megabyte index
    xor si, si                     ; MB found below 16 MB
    xor di, di                     ; MB found above 16 MB
.probe:
    mov edx, ebx
    shl edx, 20
    add edx, 0FFCh
    mov eax, edx
    xor eax, 5A9836C7h
    mov ecx, [fs:edx]              ; keep original contents
    mov [fs:edx], eax
    mov dword [fs:0FFCh], 0        ; a write to low RAM breaks bus echo
    cmp [fs:edx], eax
    mov [fs:edx], ecx
    jne .stop
    cmp ebx, 15
    jae .high
    inc si
    jmp .next
.high:
    inc di
.next:
    inc ebx
    cmp ebx, 15
    jne .limit
    inc ebx                        ; skip the 15-16 MB aperture
.limit:
    cmp ebx, 4096
    jb .probe
.stop:
    xor ax, ax
    mov es, ax
    mov ax, si
    shl ax, 3                      ; 128 KiB units
    mov [es:EXPMMSZ], al
    cmp si, 14
    jb .no_high
    mov [es:EXPMMSZ16], di
.no_high:
    pop ax
    test al, 1
    jz .a20_done
    mov al, 03h
    out A20_CTRL, al               ; restore A20 masking
.a20_done:
    popf
    pop es
    ret

; ---------------------------------------------------------------- work area
init_workarea:
    xor ax, ax
    mov ds, ax
    mov byte [SYS_TYPE], 03h       ; 386 or later
    mov byte [BIOS_FLAG0], 03h     ; bit 1: 1 MB floppy interface
    ; BIOS_FLAG1: bit 7 = 8 MHz lineage (port 42h bit 5), bit 5 = always,
    ; bits 2-0 = memory switch 3 (RS-232C / printer settings). Never V30.
    mov bl, 20h
    in al, PORT_42
    test al, 20h
    jz .clock
    or bl, 80h
.clock:
    push es
    mov ax, MSW_SEG
    mov es, ax
    mov al, [es:MSW3]
    pop es
    and al, 07h
    or bl, al
    mov [BIOS_FLAG1], bl
    ; 40h 400-line display, 08h, 04h 16 colours (analog palette),
    ; 02h GRCG, 01h 16-colour LIO
    mov byte [PRXCRT], 40h | 08h | 04h | 02h | 01h
    mov al, 18h | 40h                    ; EGC present
    push ax
    in al, SYS_A
    test al, 80h                         ; DIP 2-8 off: GDC at 2.5 MHz
    pop ax
    jnz .gdc_clock
    or al, 20h                           ; GDC at 5 MHz
.gdc_clock:
    mov [PRXDUPD], al
    mov byte [CRT_RASTER], 0Fh
    ; 04h: PC-9821 CRT BIOS. 80h: 31 kHz / 480-line modes, only when the
    ; core decodes port 09A8h (an undecoded port reads FFh).
    mov byte [CRT_BIOS], 04h
    mov dx, 09A8h
    in al, dx
    cmp al, 0FFh
    je .no31k
    or byte [CRT_BIOS], 80h
.no31k:
    mov byte [DISK_EQUIP_EXT], 40h       ; PC-9821 extended modes
    mov word [F2HD_POINTER], fd_units_2hd
    mov word [F2HD_POINTER+2], SEG_F800
    mov word [F2DD_POINTER], fd_units_2dd
    mov word [F2DD_POINTER+2], SEG_F800
    mov word [DISK_EQUIP], 0003h         ; two 1 MB-interface drives
    mov byte [F2HD_MODE], 0FFh
    mov byte [F2DD_MODE], 0FFh
    or byte [045Bh], 80h                  ; OUT 5Fh wait supported
    ret

; Memory switches live in text-VRAM attribute space and survive resets on
; real machines. Install defaults when they look uninitialised.
msw_defaults: db 48h, 05h, 04h, 00h, 01h, 00h, 00h, 6Eh

init_memory_switches:
    push es
    mov ax, MSW_SEG
    mov es, ax
    ; The core initialises the switches when it loads; only repair values
    ; that are clearly blank.
    mov al, [es:MSW1]
    test al, al
    jz .install
    cmp al, 0FFh
    jne .done
.install:
    mov al, 0Dh                    ; memory-switch write enable
    out MODE_FF1, al
    mov si, msw_defaults
    mov di, MSW1
    mov cx, 8
.next:
    mov al, [cs:si]
    mov [es:di], al
    inc si
    add di, 4
    loop .next
    mov al, 0Ch
    out MODE_FF1, al
.done:
    pop es
    ret

; ---------------------------------------------------------------- screen
init_screen:
    xor al, al                     ; 25 lines, 80 columns, vertical lines
    call crt_set_mode_far
    mov dx, 0E120h                 ; blank, white
    call text_fill_far
    mov al, GDC_START
    call tgdc_cmd_far
    mov al, 0Fh                    ; display enable
    out MODE_FF1, al
    ret

post_banner:
    push ds
    push cs
    pop ds
    mov si, banner
    xor di, di
    mov ax, 0A000h
    mov es, ax
.next:
    lodsb
    test al, al
    jz .done
    xor ah, ah
    stosw
    jmp .next
.done:
    pop ds
    push ds
    pop es
    ret

banner: db 'Open PC-98 BIOS (Zet98-486)', 0

; ---------------------------------------------------------------- far thunks
; POST runs in the F000h bank; the resident helpers live in F800h. These
; thunks call them through small far-return trampolines in the F800h bank.
%macro FAR_THUNK 2
%1:
    call SEG_F800:%2
    ret
%endmacro
FAR_THUNK kbd_init_far,       far_kbd_init
FAR_THUNK crt_set_mode_far,   far_crt_set_mode
FAR_THUNK text_fill_far,      far_text_fill
FAR_THUNK tgdc_cmd_far,       far_tgdc_cmd
FAR_THUNK tgdc_param_far,     far_tgdc_param
FAR_THUNK gdc_params_far,     far_gdc_params
FAR_THUNK gdc_wait_room_far,  far_gdc_wait_room
FAR_THUNK enter_unreal_far,   far_enter_unreal
