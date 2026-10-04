; N88-BASIC(86)-compatible runtime: work area in segment 0060h (BSEG).
;
; [if] marks addresses that disk BASIC modules, loaders or programs use and
; that therefore have fixed values (see docs/N88BASIC.md); everything else
; is this implementation's own layout. Ranges owned by others and left
; alone: 0500h-050Fh and 1596h-159Bh (disk module variables), 0620h-0637h
; and 0A08h (LIO work area), 1D00h-[TXTTAB] (disk module buffers).
;
; Variables and strings live in their own segment (VSEG, [VARSEG]): with a
; disk module it is the paragraph after the module's last 8 KiB block
; (1600h for a 24 KiB module) - programs hard-code it. Variables start at
; VSEG:0100h, strings grow down from the top CLEAR sets (VSEG offset).

BSEG            equ 0060h
KBUF            equ 0202h       ; [if] direct-mode line buffer (ASCII)
KBUF_LEN        equ 0100h
DISKMODE        equ 0505h       ; [if] 1: the IPL loaded a disk BASIC module
TXTTAB          equ 06A4h       ; [if] program text start (INT B4h moves it)
PRGEND          equ 06A6h       ; [if] program text end (loaders set it for INT C4h 1Bh)
CURLIN          equ 06E4h       ; [if] current line number, FFFFh = direct mode
KBUFPTR         equ 1406h       ; [if] offset of KBUF
VARSEG          equ 1410h       ; [if] segment of variables and strings
USRTAB          equ 14AEh       ; USR0-USR9 far pointers
TXT_DEFAULT     equ 1D00h       ; text start until the module reserves its buffers
DIRLINE         equ 1000h       ; tokenised direct line: [len][FFFFh][tokens][0]
DIRLINE_MAX     equ 0200h
B_STACK         equ 0F800h      ; stack top
TEXT_LIMIT      equ 0F000h      ; program text must end below this
VAR_START       equ 0100h       ; VSEG offset of the first variable
STR_TOP_DEFAULT equ 0FFF0h      ; string space top until CLEAR ,n

; interpreter variables
W               equ 0B00h
B_CURLINE       equ W+00h       ; header of the line being executed
B_VARTAB        equ W+02h       ; simple variables (VSEG offsets)
B_VAREND        equ W+04h
B_FRETOP        equ W+06h       ; lowest byte of string space in use (VSEG)
B_DATPTR        equ W+08h       ; READ position, 0 = from the program start
B_DEFSEG        equ W+0Ah
B_TSP           equ W+0Ch       ; temporary descriptors in use (count)
B_STMT          equ W+0Eh       ; start of the current statement
FAC_TYPE        equ W+10h       ; 2 integer, 3 string
FAC_I           equ W+12h       ; integer, or string length
FAC_P           equ W+14h       ; string pointer (segment FAC_SEG)
B_CSRX          equ 0438h       ; [if] cursor column (word; machine code reads it)
B_CSRY          equ 0436h       ; [if] cursor line (word)
B_TATTR         equ 043Ah       ; [if] text attribute for PRINT (word)
B_WIDTH         equ W+19h       ; columns
B_SCRTOP        equ W+1Ah       ; console: first line
B_SCRBOT        equ W+1Bh       ; console: last line + 1
B_FKEY          equ W+1Ch       ; function-key line shown
B_CURSW         equ W+1Dh       ; cursor switch (LOCATE ,,n)
B_LINES         equ W+1Eh       ; text lines (20/25)
B_INIF          equ W+1Fh       ; executing a THEN/ELSE branch
B_DEFTBL        equ W+20h       ; 26 bytes: default type of A-Z (2/3/4/8)
B_NUMBUF        equ W+60h       ; 16 bytes: number formatting
B_LIOPB         equ W+70h       ; 16 bytes: LIO parameter block
B_ARGS          equ W+80h       ; 16 words: statement arguments
B_ARGN          equ W+0A0h      ; argument present flags (16 bytes)
B_GCLIM         equ W+0B0h      ; garbage collection: strings at/above are placed
B_GCNEW         equ W+0B2h      ; garbage collection: new address of the moved string
B_RNDSEED       equ W+0B4h
B_SJIS          equ W+0B6h      ; pending Shift-JIS lead byte for PRINT
B_PRNL          equ W+0B7h      ; PRINT: no newline at the end
B_DATLINE       equ W+0B8h      ; line header of B_DATPTR
B_TSTK          equ W+0C0h      ; 8 temporary strings: db len, db 0, dw ptr, dw seg
B_TSTK_N        equ 8
B_VSEG          equ W+0F0h      ; variable/string segment
B_STRTOP        equ W+0F2h      ; string space top (VSEG offset)
FAC_SEG         equ W+0F4h
B_FBUF          equ W+0F6h      ; file buffers #1-#4 (VSEG), string space ends here
B_ARYEND        equ W+0F8h      ; arrays from B_VAREND to here
B_ONERR         equ W+0FAh      ; ON ERROR GOTO: line header, 0 = none
B_ERRNO         equ W+0FCh      ; ERR
B_INERR         equ W+0FDh      ; 1 while an error handler runs
B_ERRLINE       equ W+100h      ; ERL
B_ERRHDR        equ W+102h      ; RESUME: line header of the failed statement
B_ERRSTMT       equ W+104h      ; RESUME: start of the failed statement
B_STMTSP        equ W+106h      ; SP at the start of the current statement
B_KEYSTR        equ W+108h      ; reserved
B_SUBS          equ W+110h      ; 8 words: array subscripts
B_DIMS          equ W+120h      ; 8 words: DIM bounds / counts
B_USRDESC       equ W+130h      ; USR string argument: db len, db flag, dw ptr
B_USRFAR        equ W+134h      ; far pointer to B_USRDESC (what BX points to)
B_ISEG          equ W+138h      ; INSTR: segment of the searched string
B_USRVAR        equ W+13Ah      ; USR argument: VSEG offset of a lone string variable
F_SA            equ W+13Ch      ; float: sign temporary
F_NEG           equ W+13Dh
F_SEED          equ W+140h      ; RND state (dword)
F_LAST          equ W+144h      ; last RND value (dword)
F_MANT          equ W+148h      ; parse: mantissa (dword)
F_EXP10         equ W+14Ch      ; parse: decimal exponent
F_K             equ W+14Eh      ; format: decimal exponent
F_ISF           equ W+150h      ; parse: had a point or exponent
F_DIG           equ W+152h      ; format: 8 digit bytes
F_OUT           equ W+160h      ; format output (32 bytes)
B_LEFTHI        equ W+180h      ; expression: high word of the left operand
B_LEFTLO        equ W+182h      ; expression: left integer (overflow retry)
B_VALBUF        equ W+190h      ; VAL/READ: copy of the number text (40 bytes)
B_FLIM          equ W+1C0h      ; FOR: limit (dword)
B_FSTEP         equ W+1C4h      ; FOR: step (dword)
B_FTYPE         equ W+1C8h      ; FOR: variable type
B_FNCNT         equ W+1CAh      ; DEF FN: functions defined
B_FNSIZE        equ W+1CCh
B_FNTYPE        equ W+1CEh
B_FNTAB         equ W+1D0h      ; 16 words: text pointers of DEF FN names
B_ADATA         equ W+1F0h      ; array data region (VSEG, 16-aligned) ...
B_ADEND         equ W+1F2h      ; ... and its end (16-aligned)
B_ARRBASE       equ W+1F4h      ; b_getarr: data start of the array
B_ISARR         equ W+1F6h      ; b_getvar: 1 when the variable is an array element
B_MKTYPE        equ W+1F7h
B_MKNAME        equ W+1F8h
B_INPTR         equ W+1FAh      ; INPUT: next item in the line buffer
B_INMORE        equ W+1FCh      ; INPUT: routine refilling the buffer, 0 none
B_INQ           equ W+1FEh      ; INPUT: print "? "
W_END           equ W+200h

; graphics statements (bgfx.asm)
G_PB            equ 1300h       ; 32 bytes: LIO parameter block
G_LX            equ 1320h       ; last point (view coordinates)
G_LY            equ 1322h
G_OX            equ 1324h       ; VIEW origin (screen coordinates)
G_OY            equ 1326h
G_ASP           equ 1328h       ; CIRCLE aspect (single)
G_LWFG          equ 0623h       ; LIO foreground colour
; PRINT USING (bio.asm)
G_USELEN        equ 132Ch       ; format length
G_USEANY        equ 132Eh       ; a field was used in this pass
G_UPLUS         equ 1330h       ; number field: '+', ',', integer positions,
G_UCOMMA        equ 1331h       ; decimals, point
G_UINT          equ 1332h
G_UDEC          equ 1333h
G_UPT           equ 1334h
G_NUMBUF        equ 1340h       ; 32 bytes
G_USEBUF        equ 1360h       ; 64 bytes: copy of the format
B_FLINE         equ 13A0h       ; 96 bytes: INPUT # line buffer
B_INFCB         equ 1336h       ; INPUT #: control block

; value types
VT_INT          equ 2
VT_STR          equ 3
VT_SNG          equ 4
VT_DBL          equ 8

; error codes (Microsoft BASIC numbering)
E_NEXT          equ 1           ; NEXT without FOR
E_SYNTAX        equ 2
E_RETURN        equ 3           ; RETURN without GOSUB
E_DATA          equ 4           ; Out of DATA
E_FUNC          equ 5           ; Illegal function call
E_OVERFLOW      equ 6
E_MEMORY        equ 7
E_LINE          equ 8           ; Undefined line number
E_SUBSCRIPT     equ 9
E_DIV0          equ 11
E_TYPE          equ 13
E_STRSPACE      equ 14
E_STRLONG       equ 15
E_COMPLEX       equ 16          ; String formula too complex
E_FEATURE       equ 73          ; Advanced feature (not implemented here)
E_NORESUME      equ 19
E_RESUME        equ 20          ; RESUME without error
