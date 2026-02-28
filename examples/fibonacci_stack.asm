; fibonacci_stack.asm — compute Fibonacci numbers until 8-bit overflow,
;                       storing each value on the hardware stack, then
;                       popping them all off to verify LIFO order.
; clk_div: 20
;           12 MHz / 2^23 ≈ 1.4 Hz — slow enough to watch each result appear
;
; Phase 1 — PUSH:
;   Compute fib(0)..fib(13) iteratively; PUSH each value as it is produced.
;   Stop when fib(i-2)+fib(i-1) would overflow (carry set).
;   R7 holds the last valid value (fib(13)=233) throughout this phase.
;
; Phase 2 — POP:
;   Pop all 14 values back off the stack into R7 one by one.
;   Use R4=1 as a constant to subtract from the counter in R0.
;   After the loop R7 = fib(0) = 0 (bottom of stack, last popped).
;   The loop counts pops with R0; R0 decrements from 14 to 0.
;
; Stack layout after phase 1 (top → bottom):
;   TOP  → fib(13) = 233
;           fib(12) = 144
;           ...
;   BOT  → fib(0)  = 0
;
; Register use:
;   R0 = pop counter (decremented 14 → 0 in phase 2)
;   R1 = fib[i-2]  (a)
;   R2 = fib[i-1]  (b)
;   R3 = fib[i]    (next = a + b)
;   R4 = constant 1  (used as subtrahend in phase 2)
;   R7 = latest value (last PUSH during phase 1;
;                      most recently POPped value during phase 2)
;
; Final state: R7 = 0 (= fib(0), the last value popped), CPU halted.

.equ FIB_COUNT, 14     ; number of Fibonacci values pushed (fib(0)..fib(13))

; ── Phase 1: compute and PUSH ──────────────────────────────────────────────

        .oled_label "Fib Stack       "

        LDI  R1, 0          ; a = fib(0) = 0
        LDI  R2, 1          ; b = fib(1) = 1
        LDI  R4, 1          ; R4 = constant 1 (for decrement in phase 2)

        PUSH R1             ; push fib(0)
        MOV  R7, R1         ; R7 = fib(0)
        PUSH R2             ; push fib(1)
        MOV  R7, R2         ; R7 = fib(1)

push_loop:
        ADD  R3, R1, R2     ; next = a + b; C set if > 255
        JC   pop_phase      ; overflow → done pushing, start popping

        MOV  R7, R3         ; R7 = latest valid fib
        PUSH R3             ; push fib(i)

        MOV  R1, R2         ; a = b
        MOV  R2, R3         ; b = next
        JMP  push_loop

; ── Phase 2: POP all values back into R7 ───────────────────────────────────

pop_phase:
        LDI  R0, FIB_COUNT  ; R0 = pop counter = 14

pop_loop:
        POP  R7             ; R7 = top of stack (fib values in reverse order)
        SUB  R0, R0, R4     ; R0 = R0 - 1
        JNZ  pop_loop       ; loop until all 14 values popped

; ── Halt ───────────────────────────────────────────────────────────────────

        HALT
