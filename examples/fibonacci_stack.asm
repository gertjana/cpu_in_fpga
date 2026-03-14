; fibonacci_stack.asm — compute Fibonacci numbers until 8-bit overflow,
;                       storing each value on the hardware stack, then
;                       popping them all off to verify LIFO order.
; clk_div: 20
; name: Fib Stack
;
; Phase 1 — PUSH:
;   For i = 0..15:
;     push lo byte of fib(i)
;     advance (a,b) ← (b, a+b) using 16-bit ADD/ADC
;
; Phase 2 — POP:
;   Pop all 16 values into R7 in LIFO order.
;   R0 counts 16 → 0 using ADDI R0,R0,1 + CMPI R0,16 + JNZ loop.
;
; Register use:
;   R0 = loop counter
;   R1 = scratch (hi byte of next during push advance)
;   R2 = a_lo    fib[i-2] low byte
;   R3 = a_hi    fib[i-2] high byte
;   R4 = b_lo    fib[i-1] low byte
;   R5 = b_hi    fib[i-1] high byte
;   R6 = next_lo (a_lo + b_lo)
;   R7 = display / pop result
;
; Expected lo bytes pushed (fib(0)..fib(15)):
;   0,1,1,2,3,5,8,13,21,34,55,89,144,233,121,98
;   (fib(14)=377 → lo=121,hi=1;  fib(15)=610 → lo=98,hi=2)
;
; Final state: R7 = 0 (= lo(fib(0)), last value popped), CPU halted.

.equ PUSH_COUNT, 16    ; number of values to push

; ── Phase 1: initialise ─────────────────────────────────────────────────────

        LDI  R0, 0          ; loop counter = 0

        ; a = fib(-1) sentinel so that fib(0)=0, fib(1)=1 fall out naturally:
        ; We start with a=0,b=1 and push b before advancing, but actually
        ; we want fib(0)=0 first. Seed: a_lo=1,a_hi=0  b_lo=0,b_hi=0
        ; so first push is b_lo=0=fib(0), then advance b←a+b=1=fib(1), etc.
        LDI  R2, 1          ; a_lo = 1  (seed so fib(0)=0 is b)
        LDI  R3, 0          ; a_hi = 0
        LDI  R4, 0          ; b_lo = 0  = fib(0)
        LDI  R5, 0          ; b_hi = 0

; ── Push loop ───────────────────────────────────────────────────────────────

push_loop:
        PUSH R4             ; push lo byte of current fib value (b_lo)
        MOV  R7, R4         ; R7 = latest lo byte (for debug display)

        ; Compute next = a + b (16-bit)
        ADD  R6, R2, R4     ; next_lo = a_lo + b_lo  (may produce carry in C)
        ADC  R1, R3, R5     ; next_hi = a_hi + b_hi + C

        ; Advance: a ← b,  b ← next
        MOV  R2, R4         ; a_lo = b_lo
        MOV  R3, R5         ; a_hi = b_hi
        MOV  R4, R6         ; b_lo = next_lo
        MOV  R5, R1         ; b_hi = next_hi

        ; Loop control: count up to PUSH_COUNT
        ADDI R0, R0, 1
        CMPI R0, PUSH_COUNT
        JNZ  push_loop

; ── Phase 2: POP all 16 values back into R7 ─────────────────────────────────

        LDI  R0, 0          ; reset counter

pop_loop:
        POP  R7             ; R7 = next value from stack (LIFO)
        ADDI R0, R0, 1
        CMPI R0, PUSH_COUNT
        JNZ  pop_loop

; ── Halt ────────────────────────────────────────────────────────────────────

        HALT
