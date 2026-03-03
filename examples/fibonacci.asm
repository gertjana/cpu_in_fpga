; fibonacci.asm — compute Fibonacci numbers until the next value would
;                 overflow an 8-bit unsigned integer (> 255), storing
;                 each result in RAM and keeping the latest in R7.
; clk_div: 20
;           12 MHz / 2^23 ≈ 1.4 Hz — slow enough to watch each result appear
;
; Algorithm (iterative):
;   fib(0) = 0
;   fib(1) = 1
;   fib(i) = fib(i-2) + fib(i-1)   for i >= 2
;   Stop when fib(i-2) + fib(i-1) overflows 8 bits (carry flag set).
;
; Register use:
;   R0 = loop index i (RAM address pointer)
;   R1 = fib[i-2]  (a)
;   R2 = fib[i-1]  (b)
;   R3 = fib[i]    (next = a + b)
;   R7 = latest Fibonacci result that fits in 8 bits shown on the 8 LEDs of the MAX1000 board.

.equ BASE, 0           ; RAM base address

; ── initialise ────────────────────────────────────────────────────────────────

        LDI  R1, 0          ; a = fib(0) = 0
        LDI  R2, 1          ; b = fib(1) = 1
        LDI  R0, BASE       ; R0 = RAM address pointer

        ST   [R0], R1       ; RAM[0] = 0
        MOV  R7, R1         ; R7 = fib(0) = 0
        ADDI R0, R0, 1      ; advance pointer
        ST   [R0], R2       ; RAM[1] = 1
        MOV  R7, R2         ; R7 = fib(1) = 1
        ADDI R0, R0, 1      ; advance pointer  (R0 now points to RAM[2])

; ── main loop ─────────────────────────────────────────────────────────────────

loop:
        ADD  R3, R1, R2     ; next = a + b; carry set if > 255
        JC   done           ; overflow → stop, R7 holds last valid result

        MOV  R7, R3         ; R7 = latest Fibonacci result
        ST   [R0], R3       ; RAM[i] = fib(i)
        ADDI R0, R0, 1      ; advance pointer

        MOV  R1, R2         ; a = b
        MOV  R2, R3         ; b = next
        JMP  loop

; ── halt ──────────────────────────────────────────────────────────────────────

done:
        HALT
