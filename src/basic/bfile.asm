; Disk files: this runtime's own reader/writer of the N88-BASIC(86) floppy
; format, through INT 1Bh (the disk BASIC module's file services are not
; used). The format, as measured on N88 disks:
;
;   2HD: 77 cylinders x 2 heads x 26 sectors x 256 bytes (track 0: FM, 128)
;   2DD: 80 cylinders x 2 heads x 16 sectors x 256 bytes
;   A cluster is one track: cluster n = cylinder n/2, head n&1.
;   The system track (70 on 2HD, 80 on 2DD) holds the directory (sectors
;   1-22 / 1-12, 16-byte entries: name 6, extension 3, attribute, start
;   cluster, 5 x FFh; FFh in the first byte = free, 00h = deleted), the ID
;   sector (23 / 13: autostart command) and three FAT copies (24-26 / 14-16).
;   FAT byte n: next cluster, C0h+k = last cluster with k sectors used,
;   FEh = reserved, FFh = free.
;   Attribute: 80h tokenised BASIC program (with 20h: saved protected, every
;   byte rotated right by one bit), 01h binary (BSAVE: dw start, dw end,
;   data), 00h data / ASCII text; 10h write-protected.
;
; Files #1-#4: a control block in BSEG and a 256-byte buffer in VSEG (so a
; FIELD variable's descriptor can point into it), just below B_STRTOP. A
; random-access record is one 256-byte sector of the file.

FS_FAT          equ 0D00h           ; 256: FAT of unit [FS_FATU]
FS_SEC          equ 0E00h           ; 256: sector buffer
FS_FCB          equ 0F00h           ; file control blocks #1-#4
FCB_SIZE        equ 20h
FS_NFILES       equ 4
FS_GEOM         equ 0F80h           ; unit 0/1, 8 bytes each (see fs_geom)
G_DA            equ 0
G_SPT           equ 1
G_DIRTRK        equ 2
G_NDIR          equ 3
G_IDSEC         equ 4
G_FATSEC        equ 5
G_NCLUS         equ 6               ; clusters on the disk
G_VALID         equ 7
FS_FATU         equ 0F90h           ; unit whose FAT is in FS_FAT, FFh none
FS_UNIT         equ 0F91h           ; unit of the current operation
FS_NAME         equ 0F92h           ; 9: name 6 + extension 3
FS_ENTSEC       equ 0F9Ch           ; directory sector of the found entry
FS_ENTOFF       equ 0F9Eh           ; entry offset in that sector
FS_ATTR         equ 0FA0h
FS_START        equ 0FA1h           ; start cluster
FS_DST          equ 0FA2h           ; load: destination offset, segment
FS_LEFT         equ 0FA6h           ; load: bytes that may still be stored
FS_SKIP         equ 0FA8h           ; load: bytes to skip (BSAVE header)
FS_DONE         equ 0FAAh           ; load: bytes stored
FS_TRIES        equ 0FACh
FS_RUNFLAG      equ 0FADh           ; RUN/LOAD: 1 = run after loading
FS_KEEP         equ 0FAEh           ; RUN/LOAD ,R: files stay open

FCB_MODE        equ 0               ; 0 closed, 'R' random, 'I' input, 'O' output
FCB_UNIT        equ 1
FCB_START       equ 2               ; start cluster
FCB_ATTR        equ 3
FCB_NSEC        equ 4               ; sectors in the file (FAT chain)
FCB_SECIX       equ 6               ; sector of the file in the buffer, FFFFh none
FCB_REC         equ 8               ; last random record (1-based)
FCB_FLEN        equ 10              ; FIELD total length
FCB_BUF         equ 12              ; buffer: VSEG offset
FCB_POS         equ 14              ; sequential: byte in the buffer
FCB_CLUS        equ 16              ; output: current cluster
FCB_CSEC        equ 17              ; output: sectors written in it
FCB_ENTSEC      equ 18              ; output: directory sector, entry offset
FCB_ENTOFF      equ 20

E_FIELD         equ 50              ; FIELD overflow
E_BADFNUM       equ 52              ; Bad file number
E_NOFILE        equ 53              ; File not found
E_OPEN          equ 54              ; File already open
E_PASTEND       equ 55              ; Input past end
E_BADNAME       equ 56              ; Bad file name
E_NOTOPEN       equ 60              ; File not open
E_DISKIO        equ 64              ; Disk I/O error
E_DISKFULL      equ 61
E_RECNUM        equ 63              ; Bad record number

; ---------------------------------------------------------------- set-up
; Called from b_init: no units known, files closed.
fs_init:
    push di
    mov di, FS_GEOM
    mov cx, 16
    xor al, al
    rep stosb
    mov byte [FS_FATU], 0FFh
    call fs_close_all_nowrite
    pop di
    ret

; Mark every file closed without writing buffers (start-up, NEW).
fs_close_all_nowrite:
    push di
    push cx
    mov di, FS_FCB
    mov cx, FS_NFILES*FCB_SIZE
    xor al, al
    rep stosb
    pop cx
    pop di
    ret

; ---------------------------------------------------------------- INT 1Bh
; AH = 56h read / 55h write (MFM, seek). CL = cylinder, DH = head, DL =
; sector, BX = bytes, ES:BP = buffer, unit [FS_UNIT] (geometry known).
; CF set on error after retries.
fs_io:
    pusha
    mov byte [FS_TRIES], 3
.try:
    popa
    pusha
    movzx di, byte [FS_UNIT]
    shl di, 3
    mov al, [FS_GEOM+di+G_DA]
    or al, [FS_UNIT]
    mov ch, 1                       ; N = 256 bytes
    int 1Bh
    jnc .ok
    dec byte [FS_TRIES]
    jz .fail
    movzx di, byte [FS_UNIT]
    shl di, 3
    mov al, [FS_GEOM+di+G_DA]
    or al, [FS_UNIT]
    mov ah, 07h                     ; recalibrate
    int 1Bh
    jmp .try
.fail:
    popa
    stc
    ret
.ok:
    popa
    clc
    ret

; Read one sector of cluster/track AX, sector DL (1-based) of unit
; [FS_UNIT] into BSEG:BX... general form: ES:BP buffer, AH command.
; AX = track, DL = sector, BX = bytes, ES:BP buffer, CH = command.
fs_track_io:
    push ax
    push cx
    push dx
    mov cl, al
    shr cl, 1                       ; cylinder
    mov dh, al
    and dh, 1                       ; head
    mov ah, ch
    call fs_io
    pop dx
    pop cx
    pop ax
    ret

; Make sure the geometry of unit [FS_UNIT] is known: a 2HD (DA 90h) or
; 2DD (DA 70h) N88 disk, recognised by reading its FAT sector.
fs_geom:
    pusha
    movzx di, byte [FS_UNIT]
    shl di, 3
    add di, FS_GEOM
    cmp byte [di+G_VALID], 0
    jne .ok
    push es
    xor ax, ax
    mov es, ax
    mov al, [es:0584h]
    pop es
    and al, 0F0h
    mov si, fs_geom_2hd
    mov bx, fs_geom_2dd
    cmp al, 70h
    je .dd
    cmp al, 10h
    jne .order
.dd:
    xchg si, bx
.order:
    push bx
    call .tryformat
    pop si
    jnc .ok
    call .tryformat
    jnc .ok
    popa
    mov al, E_DISKIO
    jmp b_error
.ok:
    popa
    ret
.tryformat:                         ; SI -> 6 geometry bytes
    push si
    push di
    mov cx, 7
.cp:
    mov al, [cs:si]
    mov [di], al
    inc si
    inc di
    loop .cp
    pop di
    pop si
    movzx ax, byte [di+G_DIRTRK]
    mov dl, [di+G_FATSEC]
    mov bx, 256
    mov bp, FS_SEC
    push ds
    pop es
    mov ch, 56h
    call fs_track_io
    jc .no
    mov byte [di+G_VALID], 1
    clc
    ret
.no:
    stc
    ret

fs_geom_2hd:    db 90h, 26, 70, 22, 23, 24, 154
fs_geom_2dd:    db 70h, 16, 80, 12, 13, 14, 160

; DI -> geometry of [FS_UNIT].
fs_gptr:
    movzx di, byte [FS_UNIT]
    shl di, 3
    add di, FS_GEOM
    ret

; Load the FAT of [FS_UNIT] into FS_FAT (always re-read: the disk may have
; been changed).
fs_read_fat:
    pusha
    call fs_geom
    call fs_gptr
    movzx ax, byte [di+G_DIRTRK]
    mov dl, [di+G_FATSEC]
    mov bx, 256
    mov bp, FS_FAT
    push ds
    pop es
    mov ch, 56h
    call fs_track_io
    jc .err
    mov al, [FS_UNIT]
    mov [FS_FATU], al
    popa
    ret
.err:
    mov al, E_DISKIO
    jmp b_error

; Write FS_FAT back to all three FAT copies of [FS_UNIT].
fs_write_fat:
    pusha
    call fs_gptr
    movzx ax, byte [di+G_DIRTRK]
    mov dl, [di+G_FATSEC]
    mov cx, 3
.w:
    push cx
    mov bx, 256
    mov bp, FS_FAT
    push ds
    pop es
    mov ch, 55h
    call fs_track_io
    pop cx
    jc .err
    inc dl
    loop .w
    popa
    ret
.err:
    mov al, E_DISKIO
    jmp b_error

; ---------------------------------------------------------------- names
; File name string (FAC: CX bytes at FAC_SEG:BX) -> FS_UNIT, FS_NAME.
; "[d:]name[.ext]": d = 1/2 (unit 0/1), else the unit BASIC started from.
; Up to 6 name characters; without a '.', characters 7-9 are the extension.
fs_parse_name:
    push si
    push ds
    call fs_boot_unit
    mov [FS_UNIT], al
    mov di, FS_NAME
    push cx
    mov cx, 9
    mov al, ' '
    rep stosb
    pop cx
    mov si, bx
    mov ds, [FAC_SEG]
    cmp cx, 2
    jb .name
    cmp byte [si+1], ':'
    jne .name
    mov al, [si]
    sub al, '1'
    cmp al, 1
    ja .bad
    mov [ss:FS_UNIT], al
    add si, 2
    sub cx, 2
.name:
    test cx, cx
    jz .bad
    mov di, FS_NAME
    xor dx, dx                      ; characters stored
.c:
    test cx, cx
    jz .done
    lodsb
    dec cx
    cmp al, '.'
    je .ext
    cmp dx, 9
    jae .c
    mov [es:di], al
    inc di
    inc dx
    jmp .c
.ext:
    mov di, FS_NAME+6
    mov dx, 6
.e:
    test cx, cx
    jz .done
    lodsb
    dec cx
    cmp dx, 9
    jae .e
    mov [es:di], al
    inc di
    inc dx
    jmp .e
.done:
    pop ds
    pop si
    ret
.bad:
    pop ds
    pop si
    mov al, E_BADNAME
    jmp b_error

; AL = unit BASIC was started from (0000:0584h, the boot DA/UA), 0 or 1.
fs_boot_unit:
    push es
    xor ax, ax
    mov es, ax
    mov al, [es:0584h]
    pop es
    and al, 1
    ret

; Evaluate a file name expression at SI and parse it.
fs_eval_name:
    call b_eval_str
    jmp fs_parse_name

; ---------------------------------------------------------------- directory
; Find FS_NAME on [FS_UNIT]: CF clear and FS_ATTR, FS_START, FS_ENTSEC,
; FS_ENTOFF set, else CF set. Reads the FAT too.
fs_find:
    pusha
    call fs_read_fat
    call fs_gptr
    mov dl, 1                       ; directory sector
.sec:
    cmp dl, [di+G_NDIR]
    ja .no
    push di
    movzx ax, byte [di+G_DIRTRK]
    mov bx, 256
    mov bp, FS_SEC
    push ds
    pop es
    mov ch, 56h
    call fs_track_io
    pop di
    jc .ioerr
    mov bx, FS_SEC
.ent:
    cmp byte [bx], 0FFh
    je .no                          ; first free entry: end of the directory
    cmp byte [bx], 0
    je .next
    push di
    mov si, bx
    mov di, FS_NAME
    mov cx, 9
    repe cmpsb
    pop di
    je .found
.next:
    add bx, 16
    cmp bx, FS_SEC+256
    jb .ent
    inc dl
    jmp .sec
.found:
    mov al, [bx+9]
    mov [FS_ATTR], al
    mov al, [bx+10]
    mov [FS_START], al
    movzx ax, dl
    mov [FS_ENTSEC], ax
    sub bx, FS_SEC
    mov [FS_ENTOFF], bx
    popa
    clc
    ret
.no:
    popa
    stc
    ret
.ioerr:
    mov al, E_DISKIO
    jmp b_error

; Find FS_NAME or stop with "File not found".
fs_find_or_err:
    call fs_find
    jnc .r
    mov al, E_NOFILE
    jmp b_error
.r:
    ret

; Sectors used by cluster AL (FAT in FS_FAT): CX; AL = next cluster or FFh
; at the end.
fs_cluster_len:
    push bx
    push di
    movzx bx, al
    mov bl, [FS_FAT+bx]
    call fs_gptr
    movzx cx, byte [di+G_SPT]
    cmp bl, 0C0h
    jb .mid
    cmp bl, 0FEh
    jb .last
    xor cx, cx                      ; free/reserved: broken chain, stop
    mov al, 0FFh
    jmp .r
.last:
    movzx cx, bl
    sub cx, 0C0h
    mov al, 0FFh
    jmp .r
.mid:
    mov al, bl
.r:
    pop di
    pop bx
    ret

; Total sectors of the file starting at cluster AL -> CX.
fs_file_sectors:
    push ax
    push dx
    xor dx, dx
.l:
    push dx
    call fs_cluster_len
    pop dx
    add dx, cx
    cmp al, 0FFh
    jne .l
    mov cx, dx
    pop dx
    pop ax
    ret

; Sector index BX (0-based) of the file starting at cluster AL -> AX =
; track, DL = sector (1-based); CF set when past the end.
fs_locate:
    push cx
    push si
.l:
    movzx si, al                    ; this cluster
    call fs_cluster_len             ; CX sectors, AL = next
    cmp bx, cx
    jb .here
    sub bx, cx
    cmp al, 0FFh
    jne .l
    pop si
    pop cx
    stc
    ret
.here:
    mov ax, si
    mov dl, bl
    inc dl
    pop si
    pop cx
    clc
    ret

; ---------------------------------------------------------------- loading
; Load the file found by fs_find (cluster FS_START) to FS_DST: the first
; FS_SKIP bytes are dropped, at most FS_LEFT bytes stored. FS_DONE = count.
fs_load:
    pusha
    mov word [FS_DONE], 0
    mov al, [FS_START]
.cl:
    push ax
    call fs_cluster_len             ; CX sectors, AL = next
    mov dl, al
    pop ax
    push dx                         ; next cluster
    mov dl, 1                       ; first sector
.sec:
    test cx, cx
    jz .clend
    cmp word [FS_LEFT], 0
    je .stop
    ; read whole sectors straight to the destination when possible
    cmp word [FS_SKIP], 0
    jne .viabuf
    cmp word [FS_LEFT], 256
    jb .viabuf
    push cx
    ; sectors that fit: min(CX, LEFT/256), and no 64 KiB DMA boundary
    mov bx, [FS_LEFT]
    shr bx, 8
    cmp bx, cx
    jbe .n1
    mov bx, cx
.n1:
    push ax
    mov ax, [FS_DST+2]              ; linear address of the destination
    shl ax, 4
    add ax, [FS_DST]                ; low 16 bits of the linear address
    neg ax                          ; bytes to the next 64 KiB boundary
    jz .nb                          ; exactly on one: a full 64 KiB is free
    shr ax, 8
    jz .nb0                         ; less than one sector: use the buffer
    cmp bx, ax
    jbe .nb
    mov bx, ax
    jmp .nb
.nb0:
    pop ax
    pop cx
    jmp .viabuf
.nb:
    pop ax
    push bx                         ; sectors in this transfer
    shl bx, 8
    les bp, [FS_DST]
    mov ch, 56h
    call fs_track_io
    push ds
    pop es
    jc .ioerr
    pop bx
    add dl, bl
    shl bx, 8
    add [FS_DST], bx
    jnc .nc
    add word [FS_DST+2], 1000h
.nc:
    add [FS_DONE], bx
    sub [FS_LEFT], bx
    shr bx, 8
    pop cx
    sub cx, bx
    jmp .sec
.viabuf:
    push cx
    push ax
    mov bx, 256
    mov bp, FS_SEC
    push ds
    pop es
    mov ch, 56h
    call fs_track_io
    jc .ioerr
    pop ax
    push ax
    push dx
    mov si, FS_SEC
    mov cx, 256
    mov bx, [FS_SKIP]
    cmp bx, cx
    jbe .sk
    mov bx, cx
.sk:
    sub [FS_SKIP], bx
    add si, bx
    sub cx, bx
    cmp cx, [FS_LEFT]
    jbe .lim
    mov cx, [FS_LEFT]
.lim:
    sub [FS_LEFT], cx
    add [FS_DONE], cx
    les di, [FS_DST]
    rep movsb
    push ds
    pop es
    mov [FS_DST], di
    pop dx
    pop ax
    pop cx
    inc dl
    dec cx
    jmp .sec
.clend:
    pop ax                          ; next cluster
    cmp al, 0FFh
    jne .cl
    popa
    ret
.stop:
    pop ax
    popa
    ret
.ioerr:
    mov al, E_DISKIO
    jmp b_error

; ---------------------------------------------------------------- RUN/LOAD
; RUN "file"[,R] / LOAD "file"[,R]: a tokenised BASIC program to [TXTTAB].
; (Called with SI at the name; AL = 1 for RUN.)
fs_load_program:
    mov [FS_RUNFLAG], al
    call fs_eval_name
    mov byte [FS_KEEP], 0
    call b_skipsp
    cmp al, ','
    jne .noopt
    inc si
    call b_skipsp
    cmp word [si], 0052h            ; R as a variable name: 'R', count 0
    jne err_syntax
    add si, 2
    mov byte [FS_KEEP], 1
    mov byte [FS_RUNFLAG], 1
.noopt:
    call b_at_end
    jne err_syntax
    call fs_find_or_err
    test byte [FS_ATTR], 80h
    jz .ascii
    cmp byte [FS_KEEP], 0
    jne .keep
    call fs_close_all
.keep:
    mov ax, [TXTTAB]
    mov [FS_DST], ax
    mov [FS_DST+2], ds
    mov bx, TEXT_LIMIT
    sub bx, ax
    mov [FS_LEFT], bx
    mov word [FS_SKIP], 0
    call fs_load
    ; protected program: every byte was rotated right by one when saved
    test byte [FS_ATTR], 20h
    jz .plain
    mov bx, [TXTTAB]
    mov cx, [FS_DONE]
.rol:
    test cx, cx
    jz .plain
    rol byte [bx], 1
    inc bx
    dec cx
    jmp .rol
.plain:
    ; end of the program: a zero link, or the first link that leaves the
    ; loaded data or does not lead to a higher line number (protected files
    ; carry no end marker); a zero link is written there.
    mov bx, [TXTTAB]
    mov dx, bx
    add dx, [FS_DONE]
    xor di, di                      ; previous line number + 1
.end:
    lea ax, [bx+5]
    cmp ax, dx
    ja .stop
    mov ax, [bx]
    test ax, ax
    jz .found
    cmp ax, 5
    jb .stop
    mov cx, [bx+2]
    cmp cx, di
    jb .stop
    cmp cx, 0FFFFh
    je .stop
    inc cx
    mov di, cx
    add ax, bx
    jc .stop
    cmp ax, dx
    ja .stop
    mov bx, ax
    jmp .end
.stop:
    mov word [bx], 0
.found:
    lea ax, [bx+2]
    mov [PRGEND], ax
    call b_clear_vars
    mov sp, B_STACK
    cmp byte [FS_RUNFLAG], 0
    je basic_ready
    mov bx, [TXTTAB]
    cmp word [bx], 0
    je basic_ready
    jmp b_goto_bx
.bad:
    call b_new
    mov al, E_BADNAME
    jmp b_error
.ascii:
    jmp err_feature                 ; ASCII programs: not yet

stmt_load:
    xor al, al
    jmp fs_load_program

; BLOAD "file"[,offset][,R]: binary file to DEF SEG:offset (default: the
; start address saved in the file).
stmt_bload:
    call fs_eval_name
    mov word [B_ARGS], 0FFFFh
    mov byte [B_ARGN], 0
    call b_skipsp
    cmp al, ','
    jne .go
    inc si
    call b_skipsp
    cmp al, ','
    je .go
    call b_eval_uint
    mov [B_ARGS], ax
    mov byte [B_ARGN], 1
.go:
    call b_skip_stmt                ; ,R: not supported (ignored)
    call fs_find_or_err
    ; header: start, end
    mov word [FS_DST], FS_SEC+0F0h  ; first read just the header
    mov [FS_DST+2], ds
    mov word [FS_LEFT], 4
    mov word [FS_SKIP], 0
    call fs_load
    mov ax, [FS_SEC+0F0h]
    mov cx, [FS_SEC+0F2h]
    sub cx, ax                      ; length
    cmp byte [B_ARGN], 0
    je .start
    mov ax, [B_ARGS]
.start:
    mov [FS_DST], ax
    mov ax, [B_DEFSEG]
    mov [FS_DST+2], ax
    mov [FS_LEFT], cx
    mov word [FS_SKIP], 4
    call fs_load
    jmp stmt_end

; ---------------------------------------------------------------- files
; '#'? integer -> BX = control block of file 1..4 (CF clear), else error.
fs_filenum:
    call b_skipsp
    cmp al, '#'
    jne .n
    inc si
.n:
    call b_eval_int
fs_fcb_ax:
    dec ax
    cmp ax, FS_NFILES
    jae .bad
    imul bx, ax, FCB_SIZE
    add bx, FS_FCB
    ret
.bad:
    mov al, E_BADFNUM
    jmp b_error

; Open file BX must be open for random access.
fs_need_random:
    cmp byte [bx+FCB_MODE], 'R'
    je .r
    cmp byte [bx+FCB_MODE], 0
    jne .mode
    mov al, E_NOTOPEN
    jmp b_error
.mode:
    mov al, E_OPEN
    jmp b_error
.r:
    ret

; OPEN "file" [FOR mode] AS [#]n   (N88 form; random access without FOR)
stmt_open:
    call fs_eval_name
    mov dl, 'R'
    call b_skipsp
    cmp al, T_FOR
    jne .as
    inc si
    call b_skipsp
    inc si
    mov dl, 'I'
    cmp al, T_INPUT
    je .mode
    mov dl, 'O'
    cmp al, T_OUT                   ; typed here: OUT PUT
    jne .o
    cmp byte [si], T_PUT
    jne err_syntax
    inc si
    jmp .mode
.o:
    cmp al, 'O'                     ; OUTPUT: stored as a variable name
    jne err_feature                 ; (APPEND: not here)
    cmp byte [si], 5
    jne err_syntax
    add si, 6
.mode:
    call b_skipsp
.as:
    ; AS: stored as a variable name "AS" (A, count 1, 'S')
    cmp al, 'A'
    jne err_syntax
    cmp word [si+1], 'S'*256+1
    jne err_syntax
    add si, 3
    push dx
    call fs_filenum                 ; BX = control block
    pop dx
    cmp byte [bx+FCB_MODE], 0
    jne .already
    cmp dl, 'O'
    jne .find
    call fs_create                  ; output: a new, empty file
    jmp stmt_end
.find:
    push bx
    call fs_find_or_err
    pop bx
    mov [bx+FCB_MODE], dl
    mov al, [FS_UNIT]
    mov [bx+FCB_UNIT], al
    mov al, [FS_START]
    mov [bx+FCB_START], al
    mov al, [FS_ATTR]
    mov [bx+FCB_ATTR], al
    mov al, [FS_START]
    call fs_file_sectors
    mov [bx+FCB_NSEC], cx
    mov word [bx+FCB_SECIX], 0FFFFh
    mov word [bx+FCB_REC], 0
    mov word [bx+FCB_FLEN], 0
    mov word [bx+FCB_POS], 256
    mov ax, bx
    sub ax, FS_FCB
    shl ax, 3                       ; (n-1)*32 -> (n-1)*256
    add ax, [B_FBUF]
    mov [bx+FCB_BUF], ax
    call b_skip_stmt                ; LEN=: records are always 256 bytes
    jmp stmt_end
.already:
    mov al, E_OPEN
    jmp b_error

; CLOSE [[#]n[,[#]n...]]
stmt_close:
    call b_at_end
    jne .list
    call fs_close_all
    jmp stmt_end
.list:
    call fs_filenum
    call fs_close_bx
    call b_skipsp
    cmp al, ','
    jne stmt_end
    inc si
    jmp .list

fs_close_all:
    push bx
    mov bx, FS_FCB
.l:
    call fs_close_bx
    add bx, FCB_SIZE
    cmp bx, FS_FCB+FS_NFILES*FCB_SIZE
    jb .l
    pop bx
    ret

fs_close_bx:
    cmp byte [bx+FCB_MODE], 'O'
    jne .c
    call fs_out_close
.c:
    mov byte [bx+FCB_MODE], 0
    ret

; FIELD [#]n, width AS var$ [, width AS var$ ...]
stmt_field:
    call fs_filenum
    call fs_need_random
    xor dx, dx                      ; offset in the record
.item:
    call b_skipsp
    cmp al, ','
    jne stmt_end
    inc si
    push bx
    push dx
    call b_eval_int                 ; width
    pop dx
    pop bx
    push ax
    call b_skipsp
    cmp al, 'A'
    jne err_syntax
    cmp word [si+1], 'S'*256+1
    jne err_syntax
    add si, 3
    push bx
    push dx
    call b_getvar
    pop dx
    pop di                          ; control block
    cmp al, VT_STR
    jne err_type
    pop cx                          ; width
    mov ax, dx
    add ax, cx
    cmp ax, 256
    ja .over
    mov [fs:bx], cl
    mov byte [fs:bx+1], 0
    mov ax, [di+FCB_BUF]
    add ax, dx
    mov [fs:bx+2], ax
    add dx, cx
    mov [di+FCB_FLEN], dx
    mov bx, di
    jmp .item
.over:
    mov al, E_FIELD
    jmp b_error

; GET [#]n[,record] / PUT [#]n[,record]
stmt_get:
    mov ch, 56h
    jmp fs_getput
stmt_put:
    mov ch, 55h
fs_getput:
    push cx
    call fs_filenum
    call fs_need_random
    mov ax, [bx+FCB_REC]
    inc ax
    push ax
    call b_skipsp
    cmp al, ','
    pop ax
    jne .rec
    inc si
    push bx
    call b_eval_int
    pop bx
.rec:
    pop cx
    test ax, ax
    jz .badrec
    mov [bx+FCB_REC], ax
    dec ax
    cmp ax, [bx+FCB_NSEC]
    jae .badrec                     ; extending a random file: not yet
    push bx
    push cx
    mov dl, [bx+FCB_UNIT]
    mov [FS_UNIT], dl
    call fs_read_fat
    mov dx, ax
    mov al, [bx+FCB_START]
    mov bx, dx
    call fs_locate                  ; AX = track, DL = sector
    pop cx
    pop bx
    jc .badrec
    push bx
    mov bp, [bx+FCB_BUF]
    mov es, [B_VSEG]
    mov bx, 256
    call fs_track_io
    push ds
    pop es
    pop bx
    jc .ioerr
    jmp stmt_end
.badrec:
    mov al, E_RECNUM
    jmp b_error
.ioerr:
    mov al, E_DISKIO
    jmp b_error

; LSET var$ = expr / RSET var$ = expr: store into a FIELD variable.
stmt_lset:
    xor dl, dl
    jmp fs_lrset
stmt_rset:
    mov dl, 1
fs_lrset:
    push dx
    call b_getvar
    cmp al, VT_STR
    jne err_type
    push bx
    mov ah, T_EQ
    call b_expect
    call b_eval_str                 ; CX, BX (FAC_SEG)
    pop di                          ; descriptor of the target
    pop dx
    movzx ax, byte [fs:di]          ; field width
    mov di, [fs:di+2]               ; field data (VSEG)
    push si
    push es
    mov es, [B_VSEG]
    ; fill with blanks, then copy min(CX, width) at the left or right
    push di
    push cx
    mov cx, ax
    push ax
    mov al, ' '
    rep stosb
    pop ax
    pop cx
    pop di
    cmp cx, ax
    jbe .fit
    mov cx, ax
.fit:
    test dl, dl
    jz .copy
    add di, ax
    sub di, cx
.copy:
    mov si, bx
    push ds
    mov ds, [FAC_SEG]
    rep movsb
    pop ds
    pop es
    pop si
    jmp stmt_end

; CVI(2-byte string) -> integer;  MKI$(integer) -> 2-byte string
fn_cvi:
    call fn_arg_str
    cmp cx, 2
    jb err_func
    push es
    mov es, [FAC_SEG]
    mov ax, [es:bx]
    pop es
    jmp fac_set_int

fn_mki:
    call fn_arg_int
    push ax
    mov cx, 2
    call fn_newstr
    pop ax
    stosw
    jmp b_ds_es

; GET/PUT: file record (GET #n / GET n) or graphics (GET (x,y)-...: later).
stmt_get_tok:
    call b_skipsp
    cmp al, '('
    je err_feature
    cmp al, '@'
    je err_feature
    jmp stmt_get
stmt_put_tok:
    call b_skipsp
    cmp al, '('
    je err_feature
    cmp al, '@'
    je stmt_put_at
    jmp stmt_put

; ---------------------------------------------------------------- sequential
; File buffer offset of control block BX (VSEG).
fs_bufaddr:
    mov ax, bx
    sub ax, FS_FCB
    shl ax, 3
    add ax, [B_FBUF]
    mov [bx+FCB_BUF], ax
    ret

; Free FAT entry of [FS_UNIT] (FAT in FS_FAT) -> AL, marked as the last
; cluster with no sectors; "Disk full" when none.
fs_alloc:
    push di
    push cx
    push bx
    call fs_gptr
    movzx cx, byte [di+G_NCLUS]
    xor bx, bx
.l:
    cmp byte [FS_FAT+bx], 0FFh
    je .got
    inc bx
    loop .l
    mov al, E_DISKFULL
    jmp b_error
.got:
    mov byte [FS_FAT+bx], 0C0h
    mov al, bl
    pop bx
    pop cx
    pop di
    ret

; Free the cluster chain from AL (FAT in FS_FAT).
fs_free_chain:
    push bx
.l:
    movzx bx, al
    mov al, [FS_FAT+bx]
    mov byte [FS_FAT+bx], 0FFh
    cmp al, 0C0h
    jb .l
    pop bx
    ret

; Read directory sector [FS_ENTSEC] of [FS_UNIT] into FS_SEC / write it.
fs_dir_read:
    push cx
    mov ch, 56h
    jmp fs_dir_io
fs_dir_write:
    push cx
    mov ch, 55h
fs_dir_io:
    pusha
    call fs_gptr
    movzx ax, byte [di+G_DIRTRK]
    mov dl, [FS_ENTSEC]
    mov bx, 256
    mov bp, FS_SEC
    push ds
    pop es
    call fs_track_io
    popa
    pop cx
    jc .err
    ret
.err:
    mov al, E_DISKIO
    jmp b_error

; OPEN ... FOR OUTPUT: control block BX, name in FS_NAME / FS_UNIT. An
; existing file is replaced (its clusters freed, its entry reused).
fs_create:
    push si
    call fs_find                    ; (reads the FAT)
    jc .new
    mov al, [FS_START]
    call fs_free_chain
    jmp .entry
.new:
    ; first free (FFh) or deleted (00h) directory entry
    call fs_gptr
    mov dl, 1
.sec:
    cmp dl, [di+G_NDIR]
    ja .full
    movzx ax, dl
    mov [FS_ENTSEC], ax
    call fs_dir_read
    mov si, FS_SEC
.ent:
    cmp byte [si], 0FFh
    je .free
    cmp byte [si], 0
    je .free
    add si, 16
    cmp si, FS_SEC+256
    jb .ent
    inc dl
    jmp .sec
.full:
    mov al, E_DISKFULL
    jmp b_error
.free:
    sub si, FS_SEC
    mov [FS_ENTOFF], si
.entry:
    call fs_alloc                   ; first cluster
    mov [bx+FCB_START], al
    mov [bx+FCB_CLUS], al
    mov byte [bx+FCB_CSEC], 0
    mov word [bx+FCB_POS], 0
    mov word [bx+FCB_NSEC], 0
    mov ax, [FS_ENTSEC]
    mov [bx+FCB_ENTSEC], ax
    mov ax, [FS_ENTOFF]
    mov [bx+FCB_ENTOFF], ax
    mov al, [FS_UNIT]
    mov [bx+FCB_UNIT], al
    mov byte [bx+FCB_ATTR], 0
    mov byte [bx+FCB_MODE], 'O'
    call fs_bufaddr
    call fs_write_fat
    ; directory entry: name, attribute 00h (data), start cluster
    call fs_dir_read
    mov di, [FS_ENTOFF]
    add di, FS_SEC
    push si
    mov si, FS_NAME
    mov cx, 9
    rep movsb
    pop si
    mov byte [di], 0
    mov al, [bx+FCB_START]
    mov [di+1], al
    mov dword [di+2], 0FFFFFFFFh
    mov byte [di+6], 0FFh
    call fs_dir_write
    pop si
    ret

; Write byte AL to output file BX.
fs_putb:
    push di
    push es
    mov es, [B_VSEG]
    mov di, [bx+FCB_BUF]
    add di, [bx+FCB_POS]
    mov [es:di], al
    pop es
    pop di
    inc word [bx+FCB_POS]
    cmp word [bx+FCB_POS], 256
    jb .r
    call fs_out_flush
.r:
    ret

; Write the buffer of output file BX as the next sector of the file.
fs_out_flush:
    pusha
    mov al, [bx+FCB_UNIT]
    mov [FS_UNIT], al
    call fs_gptr
    mov al, [bx+FCB_CSEC]
    cmp al, [di+G_SPT]
    jb .w
    ; cluster full: link a new one
    call fs_read_fat
    call fs_alloc
    movzx si, byte [bx+FCB_CLUS]
    mov [FS_FAT+si], al
    mov [bx+FCB_CLUS], al
    mov byte [bx+FCB_CSEC], 0
    call fs_write_fat
.w:
    movzx ax, byte [bx+FCB_CLUS]
    mov dl, [bx+FCB_CSEC]
    inc dl
    mov bp, [bx+FCB_BUF]
    mov es, [B_VSEG]
    push bx
    mov bx, 256
    mov ch, 55h
    call fs_track_io
    pop bx
    push ds
    pop es
    jc .err
    inc byte [bx+FCB_CSEC]
    inc word [bx+FCB_NSEC]
    mov word [bx+FCB_POS], 0
    popa
    ret
.err:
    mov byte [bx+FCB_MODE], 0
    mov al, E_DISKIO
    jmp b_error

; CLOSE of an output file: end mark 1Ah, last sector, FAT.
fs_out_close:
    pusha
    mov al, 1Ah
    push es
    mov es, [B_VSEG]
    mov di, [bx+FCB_BUF]
    mov cx, [bx+FCB_POS]
    add di, cx
    neg cx
    add cx, 256
    rep stosb                       ; pad with 1Ah
    pop es
    call fs_out_flush
    mov al, [bx+FCB_UNIT]
    mov [FS_UNIT], al
    call fs_read_fat
    movzx si, byte [bx+FCB_CLUS]
    mov al, [bx+FCB_CSEC]
    add al, 0C0h
    mov [FS_FAT+si], al
    call fs_write_fat
    popa
    ret

; Next byte of input file BX -> AL; CF at the end (1Ah or no more sectors).
fs_getb:
    cmp word [bx+FCB_POS], 256
    jb .have
    mov ax, [bx+FCB_SECIX]
    inc ax
    cmp ax, [bx+FCB_NSEC]
    jae .eof
    mov [bx+FCB_SECIX], ax
    pusha
    mov dl, [bx+FCB_UNIT]
    mov [FS_UNIT], dl
    call fs_read_fat
    mov dx, ax
    mov al, [bx+FCB_START]
    push bx
    mov bx, dx
    call fs_locate
    pop bx
    jc .ioerr
    mov bp, [bx+FCB_BUF]
    mov es, [B_VSEG]
    push bx
    mov bx, 256
    mov ch, 56h
    call fs_track_io
    pop bx
    push ds
    pop es
    jc .ioerr
    popa
    mov word [bx+FCB_POS], 0
.have:
    push di
    push es
    mov es, [B_VSEG]
    mov di, [bx+FCB_BUF]
    add di, [bx+FCB_POS]
    mov al, [es:di]
    pop es
    pop di
    cmp al, 1Ah
    je .eof
    inc word [bx+FCB_POS]
    clc
    ret
.eof:
    stc
    ret
.ioerr:
    popa
    mov al, E_DISKIO
    jmp b_error

; B_INMORE for INPUT #: next line of file [B_INFCB] into B_FLINE -> SI.
fs_refill:
    push bx
    push cx
    push di
    mov bx, [B_INFCB]
    mov di, B_FLINE
    xor cx, cx
.l:
    call fs_getb
    jc .end
    cmp al, 0Dh
    je .cr
    cmp al, 0Ah
    je .l
    cmp cx, 94
    jae .l
    mov [di], al
    inc di
    inc cx
    jmp .l
.cr:
    inc cx                          ; (a line was read)
.end:
    jcxz .past
    mov byte [di], 0
    mov si, B_FLINE
    pop di
    pop cx
    pop bx
    ret
.past:
    mov al, E_PASTEND
    jmp b_error

; INPUT #n, var[, var ...]
stmt_input_file:
    call fs_filenum
    cmp byte [bx+FCB_MODE], 'I'
    jne .mode
    mov [B_INFCB], bx
    mov ah, ','
    call b_expect
    mov word [B_INMORE], fs_refill
    mov byte [B_FLINE], 0
    mov word [B_INPTR], B_FLINE
    jmp b_input_vars
.mode:
    mov al, E_NOTOPEN
    jmp b_error

; PRINT #n, items: numbers as on the screen, strings as they are, CR LF at
; the end unless ';' or ',' ends the list.
print_file:
    call fs_filenum
    cmp byte [bx+FCB_MODE], 'O'
    jne stmt_input_file.mode
    push bx
    mov ah, ','
    call b_expect
    pop bx
    mov dl, 0                       ; DL: list ended with a separator
.item:
    call b_at_end
    je .end
    cmp al, ';'
    je .sep
    cmp al, ','
    je .sep
    push bx
    call b_eval
    pop bx
    mov dl, 0
    push si
    cmp byte [FAC_TYPE], VT_STR
    je .str
    push bx
    call b_fmt_fac                  ; BX, CX (BSEG)
    mov si, bx
    pop bx
.n:
    lodsb
    call fs_putb
    loop .n
    mov al, ' '
    call fs_putb
    pop si
    jmp .item
.str:
    mov cx, [FAC_I]
    mov si, [FAC_P]
    jcxz .sd
    mov ax, [FAC_SEG]
    mov [B_ISEG], ax
.s:
    push ds
    mov ds, [B_ISEG]
    lodsb
    pop ds
    call fs_putb
    loop .s
.sd:
    pop si
    jmp .item
.sep:
    inc si
    mov dl, 1
    jmp .item
.end:
    test dl, dl
    jnz stmt_end
    mov al, 0Dh
    call fs_putb
    mov al, 0Ah
    call fs_putb
    jmp stmt_end

; KILL "file"
stmt_kill:
    call fs_eval_name
    call fs_find_or_err             ; (reads the FAT)
    mov al, [FS_START]
    call fs_free_chain
    call fs_write_fat
    call fs_dir_read
    mov di, [FS_ENTOFF]
    mov byte [FS_SEC+di], 0         ; deleted
    call fs_dir_write
    jmp stmt_end

; DSKI$(drive, surface, track, sector): the sector's first 255 bytes.
fn_dski:
    mov ah, '('
    call b_expect
    call b_eval_int
    dec ax
    cmp ax, 1
    ja err_func
    push ax
    mov ah, ','
    call b_expect
    call b_eval_int
    push ax
    mov ah, ','
    call b_expect
    call b_eval_int
    push ax
    mov ah, ','
    call b_expect
    call b_eval_int
    push ax
    mov ah, ')'
    call b_expect
    pop dx                          ; sector
    pop cx                          ; track (cylinder)
    pop ax                          ; surface
    mov dh, al
    pop ax
    mov [FS_UNIT], al
    call fs_geom
    mov ah, 56h
    mov bx, 256
    mov bp, FS_SEC
    push ds
    pop es
    call fs_io
    jc .err
    mov bx, FS_SEC
    mov cx, 255
    jmp fn_copy_buf
.err:
    mov al, E_DISKIO
    jmp b_error
