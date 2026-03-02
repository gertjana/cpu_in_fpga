; flag_test.asm — exercise Z, C, N, V flags and halt with C=1, V=1
; clk_div: 20
;
; LEDs in mode 0 (default):
;   LED[0] = C  (active-low: ON means C=1)
;   LED[1] = V  (active-low: ON means V=1)
;   LED[2] = heartbeat → solid ON when halted
;
; Expected final state:
;   C=1, V=1  →  LED[0] and LED[1] both lit, LED[2] solid
;
; Flag trace:
;   XOR R0,R0,R0  → R0=0x00  Z=1 C=0 N=0 V=0
;   JZ  z_ok      → taken (tests Z)
;   HALT          → skipped (fail guard)
;
;   NOT R1,R0     → R1=0xFF  Z=0 N=1 C=0 V=0
;   JN  n_ok      → taken (tests N)
;   HALT          → skipped (fail guard)
;
;   LDI R2,1      → R2=0x01
;   ADD R3,R1,R2  → 0xFF+0x01=0x00  C=1 Z=1 N=0 V=0
;   JC  c_ok      → taken (tests C)
;   HALT          → skipped (fail guard)
;
;   ; 0x80+0x80=0x00 → C=1, V=1 (both signed and unsigned overflow)
;   LDI R4,0x20   → R4=0x20
;   SHL R4,R4     → R4=0x40
;   SHL R4,R4     → R4=0x80
;   ADD R7,R4,R4  → 0x80+0x80=0x00  C=1 V=1 Z=1 N=0
;   JV  v_ok      → taken (tests V)
;   HALT          → skipped (fail guard)
;
;   HALT          → stop here with C=1 V=1

; ── test Z ────────────────────────────────────────────────────────────────────
        XOR  R0, R0, R0     ; R0 = 0x00 → Z=1
        JZ   z_ok
        HALT                ; fail guard
z_ok:

; ── test N ────────────────────────────────────────────────────────────────────
        NOT  R1, R0         ; R1 = 0xFF → N=1
        JN   n_ok
        HALT                ; fail guard
n_ok:

; ── test C ────────────────────────────────────────────────────────────────────
        LDI  R2, 1          ; R2 = 0x01
        ADD  R3, R1, R2     ; 0xFF + 0x01 = 0x00 → C=1
        JC   c_ok
        HALT                ; fail guard
c_ok:

; ── test V, and leave C=1 V=1 as final state ──────────────────────────────────
        LDI  R4, 0x20       ; R4 = 0x20
        SHL  R4, R4         ; R4 = 0x40
        SHL  R4, R4         ; R4 = 0x80
        ADD  R7, R4, R4     ; 0x80 + 0x80 = 0x00 → C=1 V=1
        JV   v_ok
        HALT                ; fail guard
v_ok:

; ── halt with C=1, V=1 ────────────────────────────────────────────────────────
        HALT
