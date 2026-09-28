; Constant tables for the resident BIOS.

; 8x8 graphic character set returned by INT 18h AH=14h, DH=00h.
; Placeholder until the free font set is generated (docs/FONT.md):
; all 256 glyphs are blank.
font8x8:
    times 256*8 db 0
