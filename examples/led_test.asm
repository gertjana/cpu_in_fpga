; led_test.asm — count R7 from 0 to 255 once, then halt.
;
; Demonstrates: LDI, ADDI, JNZ, HALT
;
; Algorithm:
;   R7 = 0
;   loop:
;     R7++
;     if R7 != 0 goto loop   (Z is set when R7 wraps 255→0)
;   HALT
;
; At the slow CPU clock (~1.43 Hz) each value is visible for ~0.7 s.

; ── initialise ────────────────────────────────────────────────────────────────

        LDI  R7, 0          ; R7 = 0

; ── loop ──────────────────────────────────────────────────────────────────────

loop:
        ADDI R7, R7, 1      ; R7++  (wraps 255→0, sets Z when result is 0)
        JNZ  loop           ; keep counting until wrap

; ── done ──────────────────────────────────────────────────────────────────────

        HALT                ; R7 = 0, all LEDs off
