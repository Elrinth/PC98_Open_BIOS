; Interrupt services of the BASIC runtime and the statement table.

; Call machine code at DX:AX through INT C3h, the way BASIC calls USR and
; CALL routines (they end with IRET): DS = ES = BSEG, BX -> FAC value,
; AL = FAC type. DS/ES are reloaded afterwards.
b_call_c3:
    push es
    xor bx, bx
    mov es, bx
    cli
    mov [es:0C3h*4], ax
    mov [es:0C3h*4+2], dx
    sti
    pop es
    push si
    push bp
    mov bx, FAC_I
    movzx ax, byte [FAC_TYPE]
    mov cx, ds                      ; text segment
    mov dx, [B_VSEG]                ; variable segment
    int 0C3h
    call b_ds_es
    cld
    pop bp
    pop si
    ret

; INT 9Eh: empty the keyboard buffer.
b_int9e:
    push ax
    push bx
.l:
    mov ah, 05h
    int 18h
    test bh, bh
    jnz .l
    pop bx
    pop ax
    iret

; INT C4h: BASIC services for disk modules and loaders, DI = function.
;   1Bh  run the program from [TXTTAB] (program text ends at [PRGEND])
b_intc4:
    cmp di, 1Bh
    je .run
    iret
.run:
    cli
    cld
    mov ax, BSEG
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, B_STACK
    mov fs, [B_VSEG]
    sti
    call b_clear_vars
    mov bx, [TXTTAB]
    cmp word [bx], 0
    je basic_ready
    jmp b_goto_bx

; ---------------------------------------------------------------- statements
%macro ST 1
    dw %1
%endmacro

stmt_table:
    ST err_feature      ; 80 AUTO
    ST err_feature      ; 81 BSAVE
    ST err_feature      ; 82 BLOAD
    ST stmt_ignore      ; 83 BEEP
    ST stmt_console     ; 84 CONSOLE
    ST err_feature      ; 85 COPY
    ST stmt_ignore      ; 86 CLOSE
    ST err_feature      ; 87 CONT
    ST stmt_clear       ; 88 CLEAR
    ST stmt_call        ; 89 CALL
    ST err_feature      ; 8A COMMON
    ST err_feature      ; 8B CHAIN
    ST stmt_ignore      ; 8C COM
    ST err_feature      ; 8D CIRCLE
    ST stmt_color       ; 8E COLOR
    ST stmt_cls         ; 8F CLS
    ST err_feature      ; 90 DELETE
    ST stmt_data        ; 91 DATA
    ST err_feature      ; 92 DIM
    ST stmt_deftype     ; 93 DEFSTR
    ST stmt_deftype     ; 94 DEFINT
    ST stmt_deftype     ; 95 DEFSNG
    ST stmt_deftype     ; 96 DEFDBL
    ST err_feature      ; 97 DSKO$
    ST stmt_def         ; 98 DEF
    ST stmt_eol         ; 99 ELSE: end of a THEN branch
    ST stmt_end_tok     ; 9A END
    ST err_feature      ; 9B ERASE
    ST err_feature      ; 9C EDIT
    ST err_feature      ; 9D ERROR
    ST stmt_for         ; 9E FOR
    ST err_feature      ; 9F FIELD
    ST err_feature      ; A0 FILES
    ST err_syntax       ; A1 FN
    ST err_feature      ; A2 DRAW
    ST stmt_goto        ; A3 GOTO
    ST stmt_gosub       ; A4 GOSUB
    ST err_feature      ; A5 GET
    ST err_feature      ; A6 HELP
    ST err_feature      ; A7 INPUT
    ST stmt_if          ; A8 IF
    ST stmt_ignore      ; A9 KEY
    ST err_feature      ; AA KILL
    ST err_feature      ; AB KANJI
    ST stmt_locate      ; AC LOCATE
    ST err_feature      ; AD LPRINT
    ST err_feature      ; AE LLIST
    ST stmt_let_tok     ; AF LET
    ST err_feature      ; B0 LINE
    ST err_feature      ; B1 LOAD
    ST err_feature      ; B2 LSET
    ST err_feature      ; B3 LFILES
    ST stmt_ignore      ; B4 MOTOR
    ST err_feature      ; B5 MERGE
    ST err_feature      ; B6 MON
    ST stmt_nextvar     ; B7 NEXT
    ST err_feature      ; B8 NAME
    ST err_feature      ; B9 NEW
    ST err_syntax       ; BA NOT
    ST err_feature      ; BB OPEN
    ST stmt_out         ; BC OUT
    ST stmt_on          ; BD ON
    ST err_feature      ; BE OPTION
    ST err_syntax       ; BF OFF
    ST stmt_print       ; C0 PRINT
    ST err_feature      ; C1 PUT
    ST stmt_poke        ; C2 POKE
    ST err_feature      ; C3 PSET
    ST err_feature      ; C4 PRESET
    ST err_feature      ; C5 PAINT
    ST stmt_return      ; C6 RETURN
    ST stmt_read        ; C7 READ
    ST stmt_run         ; C8 RUN
    ST stmt_restore     ; C9 RESTORE
    ST err_syntax       ; CA
    ST err_feature      ; CB RESUME
    ST err_feature      ; CC RSET
    ST err_feature      ; CD RENUM
    ST stmt_ignore      ; CE RANDOMIZE
    ST err_feature      ; CF ROLL
    ST stmt_screen      ; D0 SCREEN
    ST stmt_stop        ; D1 STOP
    ST err_feature      ; D2 SWAP
    ST err_feature      ; D3 SAVE
    ST err_syntax       ; D4 SPC
    ST err_syntax       ; D5 STEP
    ST err_syntax       ; D6 THEN
    ST stmt_ignore      ; D7 TRON
    ST stmt_ignore      ; D8 TROFF
    ST err_syntax       ; D9 TAB
    ST err_syntax       ; DA TO
    ST err_feature      ; DB TERM
    ST err_syntax       ; DC USING
    ST err_syntax       ; DD USR
    ST stmt_width       ; DE WIDTH
    ST err_feature      ; DF WAIT
    ST err_feature      ; E0 WHILE
    ST err_feature      ; E1 WEND
    ST err_feature      ; E2 WRITE
    ST err_feature      ; E3 LIST
    ST err_syntax       ; E4 SEG
    ST err_feature      ; E5 SET
    ST err_feature      ; E6 KINPUT
    ST err_feature      ; E7 SRQ
    ST stmt_ignore      ; E8 CMD (sound board BASIC extensions: not yet)
    ST err_feature      ; E9 IRESET
    ST err_feature      ; EA ISET
    ST err_feature      ; EB POLL
    ST err_feature      ; EC RBYTE
    ST err_feature      ; ED WBYTE
    ST err_feature      ; EE KPLOAD
    ST err_syntax       ; EF
    times 0Fh dw err_syntax  ; F0-FE operators
    ST stmt_eol         ; FF REM
