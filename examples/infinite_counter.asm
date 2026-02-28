; infinite_counter.asm — FPGA demo: infinite counter loop
; clk_div: 20
;           12 MHz / 2^20 ≈ 11.4 Hz
;
; Counts R0 from 0 to LIMIT-1, compares against LIMIT, resets and repeats.
; The flags Z/C/N/V update on every iteration, producing changing LED patterns
; on the MAX1000 board. The CPU never halts so the heartbeat LED keeps blinking.
;
; R0 = counter
; R1 = limit (63 — maximum 6-bit LDI immediate)

.equ LIMIT, 63

        .oled_label "Inf Counter     "

        LDI  R0, 0          ; R0 = 0  (counter)
        LDI  R1, LIMIT      ; R1 = 63
loop:
        ADDI R0, R0, 1      ; R0++  (updates Z/C/N/V)
        CMP  R0, R1         ; flags = R0 - R1
        JNZ  loop           ; repeat while R0 != 63
        JMP  0              ; restart from the top
