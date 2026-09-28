; F8E8:0000-003F PC-9821 feature table. Software identifies a PC-9821 by the
; 98h 21h signature and reads capability bits here. Values follow what
; NP2kai publishes for its PC-9821 configuration (BSD-3-Clause, NP2
; developer team); bits not understood yet are left clear.
    db 98h, 21h                    ; 00 signature
    db 1Fh                         ; 02 (bit 2: 19200 bps RS-232C)
    db 20h                         ; 03
    db 2Ch                         ; 04
    db 0B0h                        ; 05 bit 7: no PEGC plane mode (cleared at POST if PEGC)
    times 10h-($-feature_table) db 0
    db 00h                         ; 10 IDE devices present (set at POST)
    db 00h                         ; 11
    times 3Fh-($-feature_table) db 0
    db 00h                         ; 3F model number
