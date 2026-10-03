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
B_CSRX          equ W+16h
B_CSRY          equ W+17h
B_TATTR         equ W+18h       ; text attribute for PRINT
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
W_END           equ W+100h

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
