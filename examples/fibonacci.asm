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
;
; RAM layout (at base 0x00):
;   RAM[0]  = fib(0)  =   0 = 00000000b
;   RAM[1]  = fib(1)  =   1 = 00000001b
;   RAM[2]  = fib(2)  =   1 = 00000001b
;   RAM[3]  = fib(3)  =   2 = 00000010b
;   RAM[4]  = fib(4)  =   3 = 00000011b
;   RAM[5]  = fib(5)  =   5 = 00000101b
;   RAM[6]  = fib(6)  =   8 = 00001000b
;   RAM[7]  = fib(7)  =  13 = 00001101b
;   RAM[8]  = fib(8)  =  21 = 00010101b
;   RAM[9]  = fib(9)  =  34 = 00100010b
;   RAM[10] = fib(10) =  55 = 00110111b
;   RAM[11] = fib(11) =  89 = 01011001b
;   RAM[12] = fib(12) = 144 = 10010000b
;   RAM[13] = fib(13) = 233 = 11101001b  ← last value that fits (fib(14)=377 overflows)
;
; Final state: R7 = 233, CPU halted.

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
