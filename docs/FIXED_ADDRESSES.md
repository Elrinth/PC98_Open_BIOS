# Fixed addresses

PC-98 software sometimes bypasses the interrupt vectors. These locations are
kept compatible:

| Address | Contents | Why |
|---|---|---|
| FFFF:0000 (FFFF0h) | `jmp F000:post_entry` | CPU reset vector |
| FD80:0000 | reset entry | traditional BIOS segment |
| FD80:091E | `jmp` to the boot sequence | MS-DOS 6.20 IO.SYS jumps here to restart booting |
| FD80:0E00 | 8 key tables of 60h bytes | also published through 05C6h; some software reads them directly |
| F8E8:0000-003F | PC-9821 feature table (98h 21h ...) | PC-9821 identification |
| INT 1Ah vector + 19h | printer body entered with DS, DX pushed | MS-DOS IO.SYS hooks INT 1Ah by jumping to the original vector + 19h |
| E800:xxxx | LIO entry points (INT A0h-AFh) | NEC keeps LIO in the E800h (BASIC) area |
| F990:0000 | LIO directory: count 11h, then {INT, 0, offset} for A0h-AFh and CEh, entry stubs at F990:0050+8n | MS-DOS locates the LIO through it; without it LIO calls end in IO.SYS's "invalid interrupt" message (E.V.O.) |
| F800:xxxx | 2HD/2DD parameter tables via 05F8h/05CCh | INT 1Bh reads EOT/GPL through these pointers, so software can replace them |

Work-area bytes the BIOS maintains are listed in `src/workarea.inc`.

Found by tracing MS-DOS 6.20 (IO.SYS) in the test model: log every jump into
E8000h-FFFFFh that does not land on an interrupt vector entry. Other DOS
versions or programs may use more such entries; add them here when found.
