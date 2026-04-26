; dice_mod.asm — roll polyhedral dice using a modulo-by-subtraction subroutine
; clk_div: 8
; name: Dice mod
;
; Rolls one of each: d20, d12, d10, d8, d6, d4 using the hardware PRNG
; (port 1, Galois LFSR).  Each raw PRNG byte is reduced modulo N (using a
; repeated-subtraction `mod8` subroutine) and biased by +1 so the final
; result lies in 1..N.
;
; ──────────────────────────────────────────────────────────────────────────
; Companion programs
; ──────────────────────────────────────────────────────────────────────────
;   examples/dice.asm     — same dice, but uses rejection sampling with a
;                           bitmask and a `roll` subroutine.  That version
;                           is faster (essentially constant time per die,
;                           ~1.0–1.6 attempts) and unbiased.
;
;   This file (dice_mod.asm) keeps the simpler modulo approach for
;   comparison — it is correct but has two drawbacks:
;     • Variable runtime per die: ~1 to 63 SUB iterations depending on
;       the random byte and the divisor.  d4 is roughly 5× slower than
;       d20 in the worst case.
;     • Slight bias toward low values when 256 mod N ≠ 0 (e.g. for d20,
;       values 1..16 are slightly more likely than 17..20).
;
; ──────────────────────────────────────────────────────────────────────────
; Final register layout (held until reset)
; ──────────────────────────────────────────────────────────────────────────
;   R0 = d20  (1..20)
;   R1 = d12  (1..12)
;   R2 = d10  (1..10)
;   R3 = d8   (1..8)
;   R4 = d6   (1..6)
;   R5 = d4   (1..4)
;   R6 = 0    (scratch, cleared at end)
;   R7 = 0    (scratch, cleared at end)
;
; The LEDs are not touched — results live only in R0..R5 and can be
; inspected via the debug interface after the CPU halts.
;
; ──────────────────────────────────────────────────────────────────────────
; Modulo helper — `mod8`
; ──────────────────────────────────────────────────────────────────────────
; The CPU has no DIV/MOD, so modulo is implemented as repeated subtraction.
;
; Calling convention:
;   in : R6 = dividend (0..255)
;        R7 = divisor  (1..255)
;   out: R6 = R6 mod R7   (0 .. R7-1)
;        R7 unchanged
;
; CMP performs Ra - Rb and sets C=1 on borrow (i.e. when Ra < Rb).  So we
; loop while there is no borrow (R6 >= R7) and subtract each iteration.

.equ PRNG_PORT,    0x01

; ── Roll d20 → R0 ─────────────────────────────────────────────────────────

        IN   R6, PRNG_PORT       ; R6 = raw random byte
        LDI  R7, 20              ; divisor
        CALL mod8                ; R6 = R6 mod 20  (0..19)
        ADDI R0, R6, 1           ; R0 = 1..20

; ── Roll d12 → R1 ─────────────────────────────────────────────────────────

        IN   R6, PRNG_PORT
        LDI  R7, 12
        CALL mod8
        ADDI R1, R6, 1           ; R1 = 1..12

; ── Roll d10 → R2 ─────────────────────────────────────────────────────────

        IN   R6, PRNG_PORT
        LDI  R7, 10
        CALL mod8
        ADDI R2, R6, 1           ; R2 = 1..10

; ── Roll d8 → R3 ──────────────────────────────────────────────────────────

        IN   R6, PRNG_PORT
        LDI  R7, 8
        CALL mod8
        ADDI R3, R6, 1           ; R3 = 1..8

; ── Roll d6 → R4 ──────────────────────────────────────────────────────────

        IN   R6, PRNG_PORT
        LDI  R7, 6
        CALL mod8
        ADDI R4, R6, 1           ; R4 = 1..6

; ── Roll d4 → R5 ──────────────────────────────────────────────────────────

        IN   R6, PRNG_PORT
        LDI  R7, 4
        CALL mod8
        ADDI R5, R6, 1           ; R5 = 1..4

; ── Clear scratch registers so only R0..R5 hold meaningful values ───────

        LDI  R6, 0
        LDI  R7, 0

; ── All dice rolled — halt with results held in R0..R5 ───────────────────

        HALT

; ──────────────────────────────────────────────────────────────────────────
; mod8 — R6 = R6 mod R7   (subroutine)
; ──────────────────────────────────────────────────────────────────────────
mod8:
        CMP  R6, R7              ; R6 - R7, sets C=1 if R6 < R7 (borrow)
        JC   mod8_done           ; if R6 < R7, R6 already holds the remainder
        SUB  R6, R6, R7          ; otherwise subtract divisor
        JMP  mod8                ; and try again
mod8_done:
        RET
