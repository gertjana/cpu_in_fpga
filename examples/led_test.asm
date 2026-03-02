; led_test.asm — count R7 from 0 to 255 once, then halt.
; clk_div: 20
;           12 MHz / 2^20 ≈ 11.4 Hz
;

; ── initialise ────────────────────────────────────────────────────────────────

        LDI  R7, 0          ; R7 = 0

; ── loop ──────────────────────────────────────────────────────────────────────

loop:
        ADDI R7, R7, 1      ; R7++  (wraps 255→0, sets Z when result is 0)
        JNZ  loop           ; keep counting until wrap

; ── done ──────────────────────────────────────────────────────────────────────

        HALT                ; R7 = 0, all LEDs off
