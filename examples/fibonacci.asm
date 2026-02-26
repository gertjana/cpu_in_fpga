; fibonacci.asm — compute the first N Fibonacci numbers, store in RAM,
;                 then call a subroutine to read back the Nth result.
;
; Demonstrates: LDI, ADD, ADDI, ST, LD, CMP, JNZ, JMP, CALL, RET, HALT
;               plus .equ constants and forward/backward labels.
;
; Algorithm (iterative):
;   fib(0) = 0
;   fib(1) = 1
;   fib(i) = fib(i-2) + fib(i-1)   for i >= 2
;
; Register use:
;   R0 = loop index i
;   R1 = fib[i-2]  (a)
;   R2 = fib[i-1]  (b)
;   R3 = fib[i]    (next = a + b), also used as RAM address pointer
;   R4 = RAM base address (0x00)
;   R5 = N (number of terms)
;   R6 = result returned by get_result subroutine
;   R7 = latest Fibonacci result (updated after every term)
;
; RAM layout (at base 0x00):
;   RAM[0]  = fib(0) =  0
;   RAM[1]  = fib(1) =  1
;   RAM[2]  = fib(2) =  1
;   RAM[3]  = fib(3) =  2
;   RAM[4]  = fib(4) =  3
;   RAM[5]  = fib(5) =  5   ← "the fifth fibonacci number is 5"
;   RAM[6]  = fib(6) =  8
;   RAM[7]  = fib(7) = 13
;   RAM[8]  = fib(8) = 21
;   RAM[9]  = fib(9) = 34
;
; Final state: R6 = R7 = fib(N-1) = fib(9) = 34, CPU halted.
;
; To get fib(5) = 5, change N to 6.

.equ N,    10          ; number of terms to compute
.equ BASE, 0           ; RAM base address

; ── initialise ────────────────────────────────────────────────────────────────

        LDI  R4, BASE       ; R4 = RAM base address
        LDI  R5, N          ; R5 = N

        ; seed: RAM[0] = 0, RAM[1] = 1
        LDI  R1, 0          ; a = fib(0) = 0
        LDI  R2, 1          ; b = fib(1) = 1

        MOV  R3, R4         ; R3 = address pointer = BASE
        ST   [R3], R1       ; RAM[0] = 0
        MOV  R7, R1         ; R7 = fib(0) = 0
        ADDI R3, R3, 1      ; R3 = BASE+1
        ST   [R3], R2       ; RAM[1] = 1
        MOV  R7, R2         ; R7 = fib(1) = 1

        LDI  R0, 2          ; i = 2  (first index to compute)

; ── main loop: compute fib(i) = a + b ────────────────────────────────────────

loop:
        CMP  R0, R5         ; i == N ?
        JZ   done           ; yes → exit loop

        ADD  R3, R1, R2     ; next = a + b  (R3 = fib(i))
        MOV  R7, R3         ; R7 = latest Fibonacci result

        ; store at RAM[i]:  address = BASE + i = R4 + R0
        ADD  R6, R4, R0     ; R6 = BASE + i
        ST   [R6], R3       ; RAM[i] = fib(i)

        MOV  R1, R2         ; a = b
        MOV  R2, R3         ; b = next

        ADDI R0, R0, 1      ; i++
        JMP  loop

; ── call subroutine to load result ───────────────────────────────────────────

done:
        CALL get_result     ; R6 = RAM[N-1]  (= fib(N-1))
        HALT

; ── subroutine: get_result ───────────────────────────────────────────────────
; Loads RAM[N-1] into R6.
; Uses R3 as a scratch address register (caller-saved convention).
; Arguments:  R4 = BASE, R5 = N  (already set by main)
; Returns:    R6 = RAM[N-1]

get_result:
        ADDI R3, R4, N-1    ; R3 = BASE + (N-1)
        LD   R6, [R3]       ; R6 = RAM[N-1]
        RET
