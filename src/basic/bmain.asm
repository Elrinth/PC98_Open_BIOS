; Open N88-BASIC(86)-compatible runtime - entry points, start-up, statement loop.
;
; Written from observed behaviour and interfaces (docs/N88BASIC.md); no NEC
; code. Registers while interpreting: DS = ES = SS = BSEG, SI = text pointer.
; Statement handlers are jump targets: they end with "jmp stmt_end" (SI at
; the end of the statement) or "jmp stmt_next" (SI at a statement start).

; ---------------------------------------------------------------- entries
; E800:0000  INT 1Eh / no system disk: the open BIOS "no bootable disk" screen
; E800:0002  disk BASIC: the system disk's IPL loaded the disk BASIC module to
;            1000:0000 and jumps here (0060:0505h = 1)
; E800:000A  INT 1Eh once BASIC runs: back to direct mode
basic_entries:
    jmp short basic_rom_entry
    jmp near basic_disk_entry
    times 0Ah-($-basic_entries) db 90h
    jmp near basic_warm_entry

basic_rom_entry:
%include "basic_stub.asm"

basic_disk_entry:
    cli
    cld
    mov ax, BSEG
    mov ss, ax
    mov sp, B_STACK
    mov ds, ax
    mov es, ax
    sti
    call b_init
    call b_disk_init                ; CX = length of the autostart command
    jcxz basic_ready
    mov si, [KBUFPTR]
    call b_crunch_direct            ; KBUF (CX chars) -> DIRLINE
    jmp b_run_direct

basic_warm_entry:
    cli
    cld
    mov ax, BSEG
    mov ss, ax
    mov sp, B_STACK
    mov ds, ax
    mov es, ax
    mov fs, [B_VSEG]
    sti
    ; fall through

; ---------------------------------------------------------------- direct mode
basic_ready:
    mov sp, B_STACK
    mov word [CURLIN], 0FFFFh
    mov word [B_TSP], 0
    call b_newline_if_needed
    mov si, msg_ok
    call b_puts_cs
    call b_newline
.line:
    call b_readline                 ; KBUF, CX = length
    jcxz .line
    mov si, KBUF
    call b_crunch_direct
    jc .line                        ; numbered line: not stored yet
    jmp b_run_direct

; Execute the tokenised direct line in DIRLINE.
b_run_direct:
    mov sp, B_STACK
    call b_cursor_hide
    mov word [CURLIN], 0FFFFh
    mov word [B_CURLINE], DIRLINE
    mov si, DIRLINE+4
    jmp stmt_next

; ---------------------------------------------------------------- start-up
b_init:
    xor ax, ax
    mov di, W
    mov cx, (W_END-W)/2
    rep stosw
    mov word [RAMTOP], 0A000h      ; conventional RAM ends before text VRAM
    mov word [KBUFPTR], KBUF
    mov word [B_VSEG], 1000h        ; without a disk module
    mov word [B_STRTOP], STR_TOP_DEFAULT
    call b_set_fbuf
    call fs_init
    call b_set_vseg
    mov word [TXTTAB], TXT_DEFAULT
    mov word [CURLIN], 0FFFFh
    mov word [B_DEFSEG], BSEG
    mov di, B_DEFTBL
    mov al, VT_SNG
    mov cx, 26
    rep stosb
    mov di, USRTAB
    mov cx, 10
.usr:
    mov ax, b_usr_unset
    stosw
    mov ax, cs
    stosw
    loop .usr
    ; vectors: BASIC entry, USR/CALL gate, services
    push es
    xor ax, ax
    mov es, ax
    mov word [es:1Eh*4], basic_entries+0Ah
    mov [es:1Eh*4+2], cs
    mov word [es:9Eh*4], b_int9e
    mov [es:9Eh*4+2], cs
    mov word [es:0C4h*4], b_intc4
    mov [es:0C4h*4+2], cs
    mov word [es:87h*4], b_int87
    mov [es:87h*4+2], cs
    pop es
    ; LIO state at BSEG:0620h, text console
    mov dword [0434h], 0            ; NEC console fields (words)
    mov dword [0438h], 0
    mov word [043Ch], 0
    mov byte [B_TATTR], 0E1h
    mov byte [B_WIDTH], 80
    mov byte [B_LINES], 25
    mov byte [B_SCRTOP], 0
    mov byte [B_SCRBOT], 25
    mov byte [B_CURSW], 1
    xor bx, bx
    mov ah, 0
    int 0A0h                        ; LIO GINIT (DS = BSEG)
    xor ax, ax
    mov [G_LX], ax
    mov [G_LY], ax
    mov [G_OX], ax
    mov [G_OY], ax
    call b_cls_text
    call b_new
    ret

; File buffers just below the string top, 256-byte aligned (no DMA
; boundary inside one: VSEG is a multiple of 10h).
b_set_fbuf:
    mov ax, [B_STRTOP]
    sub ax, FS_NFILES*256
    xor al, al
    mov [B_FBUF], ax
    ret

; VSEG = [B_VSEG]: publish it, load FS.
b_set_vseg:
    mov ax, [B_VSEG]
    mov [VARSEG], ax
    mov fs, ax
    ret

; Program memory empty: text at TXTTAB holds only the end marker.
b_new:
    mov bx, [TXTTAB]
    mov word [bx], 0
    lea ax, [bx+2]
    mov [PRGEND], ax
    ; fall through
b_clear_vars:
    mov word [B_VARTAB], VAR_START
    mov word [B_VAREND], VAR_START
    mov word [B_ARYEND], VAR_START
    mov word [B_ADATA], VAR_START
    mov word [B_ADEND], VAR_START
    mov word [fs:0000h], VAR_START  ; NEC's VSEG header: variables start
    mov word [fs:0002h], VAR_START  ; and end ([0002h] is read by programs)
    mov word [fs:0004h], VAR_START
    mov word [B_ONERR], 0
    mov byte [B_INERR], 0
    mov word [B_FNCNT], 0
    mov ax, [B_FBUF]
    mov [B_FRETOP], ax
    mov word [B_TSP], 0
    mov word [B_DATPTR], 0
    ret

; Disk BASIC: install the module's vectors and run its start-up services.
; Returns CX = length of the autostart command the module put into KBUF.
b_disk_init:
    xor cx, cx
    cmp byte [DISKMODE], 0
    je .ret
    ; Module blocks at 1000h, 1200h, 1400h, 1600h (8 KiB each) start with a
    ; vector directory: dw count, dw flags, {db INT, db 0, dw offset} x count.
    mov dx, 1000h
.blk:
    push ds
    mov ds, dx
    mov cx, [0]
    jcxz .nextblk
    cmp cx, 16
    ja .nextblk
    lea ax, [edx+200h]
    mov [ss:B_VSEG], ax             ; variables after the last module block
    mov si, 4
.ent:
    lodsw
    test ah, ah
    jnz .nextblk
    movzx di, al
    shl di, 2
    lodsw
    push es
    xor bx, bx
    mov es, bx
    mov [es:di], ax
    mov [es:di+2], dx
    pop es
    loop .ent
.nextblk:
    pop ds
    add dx, 200h
    cmp dx, 1800h
    jb .blk
    call b_set_vseg
    ; Start-up services, registers as BASIC passes them.
    xor ax, ax
    mov bx, 1
    xor cx, cx
    xor dx, dx
    mov si, 0C36h
    mov di, 2Dh
    mov bp, BSEG
    int 0C6h                        ; 2Dh: drive initialisation
    call b_ds_es
    mov bp, [TXTTAB]
    int 0B4h                        ; module start-up: BP = new text start
    call b_ds_es
    mov [TXTTAB], bp
    call b_new
    mov ax, 1200h
    mov es, ax
    cmp word [es:2], 0FFFFh         ; the 1200h block exports the disk services
    jne .no34
    mov bx, 18A0h
    xor cx, cx
    mov dx, 6
    mov si, 0C65h
    mov bp, 6
    mov di, 34h
    int 0C6h
.no34:
    call b_ds_es
    xor ax, ax
    mov es, ax
    mov di, 2Eh
    int 0C6h                        ; 2Eh: autostart command -> KBUF, CX = length
    call b_ds_es
.ret:
    ret

; DS = ES = BSEG, flags and other registers preserved.
b_ds_es:
    push ax
    mov ax, BSEG
    mov ds, ax
    mov es, ax
    mov fs, [B_VSEG]
    pop ax
    ret

; ---------------------------------------------------------------- statement loop
stmt_next:
    mov [B_STMT], si
    mov [B_STMTSP], sp
.skip:
    mov al, [si]
    inc si
    cmp al, ' '
    je .skip
    cmp al, 01h
    jb .notblank
    cmp al, 0Ah
    jbe .skip
.notblank:
    cmp al, ':'
    je stmt_next
    test al, al
    jz stmt_eol
    cmp al, '*'
    je .label
    cmp al, 80h
    jb .let
    cmp al, 0FFh
    jne .tok
    cmp byte [si], F_MID_S|80h      ; FFh 81h: the MID$ statement
    je stmt_midassign
    cmp byte [si], F_POINT|80h      ; FFh 82h: POINT (x,y)
    je stmt_point
    cmp byte [si], F_VIEW|80h       ; FFh 85h: VIEW
    je stmt_view
    cmp byte [si], F_WINDOW|80h
    je err_feature
    jmp stmt_eol                    ; FFh at a statement start: REM
.tok:
    movzx bx, al
    sub bx, 80h
    shl bx, 1
    jmp [cs:stmt_table+bx]
.let:
    dec si
    jmp stmt_let
.label:                             ; *NAME: a jump target, nothing to do
    movzx ax, byte [si+1]
    add si, ax
    add si, 2
    jmp stmt_next

; SI after a statement: ':' or end of line (or ELSE after a THEN branch).
stmt_end:
    call b_skipsp
    cmp al, ':'
    jne .not
    inc si
    jmp stmt_next
.not:
    test al, al
    jz .eol
    cmp al, T_ELSE
    je .eol
    jmp err_syntax
.eol:
    ; fall through

stmt_eol:
    mov bx, [B_CURLINE]
    cmp word [bx+2], 0FFFFh
    je basic_ready                  ; direct line done
    add bx, [bx]
    cmp word [bx], 0
    je stmt_end_program
    mov [B_CURLINE], bx
    mov ax, [bx+2]
    mov [CURLIN], ax
    lea si, [bx+4]
    jmp stmt_next

stmt_end_program:
    jmp basic_ready

; Jump to line AX: B_CURLINE/CURLIN/SI set, continue there.
b_goto_line:
    call b_find_line
    jc err_line
b_goto_bx:
    mov [B_CURLINE], bx
    mov ax, [bx+2]
    mov [CURLIN], ax
    lea si, [bx+4]
    jmp stmt_next

; Jump target at SI: line number (0Eh nnnn) or label (*NAME) -> BX = line
; header; SI after it. Undefined line number error when not found.
b_get_target:
    call b_skipsp
    cmp al, '*'
    je .label
    cmp al, 0Eh
    jne err_syntax
    inc si
    lodsw
    call b_find_line
    jc err_line
    ret
.label:
    inc si
    call b_find_label
    jc err_line
    ret

; Label name at SI (letter, count, rest) -> BX = header of the line that
; starts with *NAME, CF if none; SI after the name.
b_find_label:
    push cx
    push dx
    push di
    mov dx, si
    movzx cx, byte [si+1]
    add cx, 2
    add si, cx
    push si
    mov bx, [TXTTAB]
.l:
    cmp word [bx], 0
    je .no
    lea di, [bx+4]
.sp:
    mov al, [di]
    cmp al, ' '
    je .b
    cmp al, 01h
    jb .chk
    cmp al, 0Ah
    ja .chk
.b:
    inc di
    jmp .sp
.chk:
    cmp al, '*'
    jne .next
    inc di
    push cx
    mov si, dx
    repe cmpsb
    pop cx
    je .yes
.next:
    add bx, [bx]
    jmp .l
.no:
    pop si
    pop di
    pop dx
    pop cx
    stc
    ret
.yes:
    pop si
    pop di
    pop dx
    pop cx
    clc
    ret

; AX = line number -> BX = line header, CF set if there is no such line.
b_find_line:
    mov bx, [TXTTAB]
.l:
    cmp word [bx], 0
    je .no
    cmp [bx+2], ax
    je .yes
    add bx, [bx]
    jmp .l
.no:
    stc
    ret
.yes:
    clc
    ret

; ---------------------------------------------------------------- text helpers
; Skip blanks (01h, 20h); AL = next byte, SI points to it.
b_skipsp:
    mov al, [si]
    cmp al, ' '
    je .s
    cmp al, 01h                     ; 01h-0Ah: that many blanks
    jb .r
    cmp al, 0Ah
    ja .r
.s:
    inc si
    jmp b_skipsp
.r:
    ret

; Expect byte AH next (after blanks) and step over it, else Syntax error.
b_expect:
    call b_skipsp
    cmp al, ah
    jne err_syntax
    inc si
    ret

; At end of statement? ZF set when ':' / 0 / ELSE follows.
b_at_end:
    call b_skipsp
    cmp al, ':'
    je .r
    test al, al
    je .r
    cmp al, T_ELSE
.r:
    ret

; Skip to the end of the statement, token by token: SI at ':' / 0 / ELSE.
b_skip_stmt:
    push ax
.l:
    mov al, [si]
    test al, al
    jz .r
    cmp al, ':'
    je .r
    cmp al, T_ELSE
    je .r
    call b_tok_skip
    jmp .l
.r:
    pop ax
    ret

; ---------------------------------------------------------------- errors
err_syntax:
    mov al, E_SYNTAX
    jmp b_error
err_func:
    mov al, E_FUNC
    jmp b_error
err_type:
    mov al, E_TYPE
    jmp b_error
err_overflow:
    mov al, E_OVERFLOW
    jmp b_error
err_line:
    mov al, E_LINE
    jmp b_error
err_memory:
    mov al, E_MEMORY
    jmp b_error
err_feature:
    mov al, E_FEATURE
    jmp b_error
err_div0:
    mov al, E_DIV0
    jmp b_error

; AL = error code: to the ON ERROR handler, or print the message and the
; line and go back to direct mode.
b_error:
    cld
    mov bx, BSEG
    mov ds, bx
    mov es, bx
    mov ss, bx
    mov fs, [B_VSEG]
    cmp word [B_ONERR], 0
    je .report
    cmp byte [B_INERR], 0
    jne .report
    cmp word [CURLIN], 0FFFFh
    je .report
    mov [B_ERRNO], al
    mov bx, [CURLIN]
    mov [B_ERRLINE], bx
    mov bx, [B_CURLINE]
    mov [B_ERRHDR], bx
    mov bx, [B_STMT]
    mov [B_ERRSTMT], bx
    mov byte [B_INERR], 1
    mov sp, [B_STMTSP]
    mov word [B_TSP], 0
    mov bx, [B_ONERR]
    jmp b_goto_bx
.report:
    mov sp, B_STACK
    push ax
    call b_newline_if_needed
    pop ax
    mov si, err_texts
.find:
    mov ah, [cs:si]
    test ah, ah
    jz .unknown
    cmp ah, al
    je .found
.skipmsg:
    inc si
    cmp byte [cs:si], 0
    jne .skipmsg
    inc si
    jmp .find
.found:
    inc si
    call b_puts_cs
    jmp .line
.unknown:
    mov si, msg_error
    call b_puts_cs
.line:
    cmp word [CURLIN], 0FFFFh
    je .done
    mov si, msg_in
    call b_puts_cs
    mov ax, [CURLIN]
    call b_print_uint
.done:
    call b_newline
    jmp basic_ready

msg_ok:     db 'Ok', 0
msg_in:     db ' in ', 0
msg_error:  db 'Error', 0
msg_break:  db 'Break', 0
err_texts:
    db E_NEXT, 'NEXT without FOR', 0
    db E_SYNTAX, 'Syntax error', 0
    db E_RETURN, 'RETURN without GOSUB', 0
    db E_DATA, 'Out of DATA', 0
    db E_FUNC, 'Illegal function call', 0
    db E_OVERFLOW, 'Overflow', 0
    db E_MEMORY, 'Out of memory', 0
    db E_LINE, 'Undefined line number', 0
    db E_SUBSCRIPT, 'Subscript out of range', 0
    db E_DIV0, 'Division by zero', 0
    db E_TYPE, 'Type mismatch', 0
    db E_STRSPACE, 'Out of string space', 0
    db E_STRLONG, 'String too long', 0
    db E_COMPLEX, 'String formula too complex', 0
    db E_FEATURE, 'Feature not available', 0
    db 10, 'Duplicate Definition', 0
    db 18, 'Undefined user function', 0
    db 19, 'No RESUME', 0
    db 20, 'RESUME without error', 0
    db 50, 'FIELD overflow', 0
    db 52, 'Bad file number', 0
    db 53, 'File not found', 0
    db 54, 'File already open', 0
    db 55, 'Input past end', 0
    db 56, 'Bad file name', 0
    db 60, 'File not OPEN', 0
    db 61, 'Disk full', 0
    db 63, 'Bad record number', 0
    db 64, 'Disk I/O error', 0
    db 26, 'WHILE without WEND', 0
    db 30, 'WEND without WHILE', 0
    db 0

; ---------------------------------------------------------------- line input
; Read a line into KBUF with echo; CX = length (KBUF is 0-terminated).
b_readline:
    mov di, KBUF
    xor cx, cx
.key:
    call b_cursor_show
    mov ah, 0
    int 18h                         ; AL = character
    cmp al, 0Dh
    je .done
    cmp al, 08h
    je .bs
    cmp al, ' '
    jb .key
    cmp cx, KBUF_LEN-1
    jae .key
    stosb
    inc cx
    call b_putc
    jmp .key
.bs:
    jcxz .key
    dec di
    dec cx
    call b_backspace
    jmp .key
.done:
    mov byte [di], 0
    call b_newline
    ret
