; count_to_9.asm — count from 0 to 9, then halt
; clk_div: 20
;           12 MHz / 2^20 ≈ 11.4 Hz
;
; R0 = counter (starts at 0, increments to 9)
; R1 = limit   (constant 10 — loop exits when R0 == 10, i.e. after counting 0..9)
;
; Expected final state: R0 = 10, flags Z=1 C=0 N=0 V=0, CPU halted

.equ LIMIT, 10

        LDI  R0, 0          ; R0 = 0  (counter)
        LDI  R1, LIMIT      ; R1 = 10 (loop bound)
loop:
        ADDI R0, R0, 1      ; R0++
        CMP  R0, R1         ; set flags: R0 - R1
        JNZ  loop           ; repeat while R0 != R1
        HALT
