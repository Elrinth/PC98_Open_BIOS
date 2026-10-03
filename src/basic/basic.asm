; Open N88-BASIC(86)-compatible runtime in the E800h bank. Interfaces and
; the program-text format are described in docs/N88BASIC.md.

%include "basic/basic.inc"
%include "basic/tokens.inc"
%include "basic/bmain.asm"
%include "basic/bcrunch.asm"
%include "basic/bexpr.asm"
%include "basic/bvar.asm"
%include "basic/bstmt.asm"
%include "basic/bscreen.asm"
%include "basic/bsvc.asm"
%include "basic/kwtable.inc"
