; dice.asm — roll a set of polyhedral dice and store results in registers
; clk_div: 8
; name: Dice Roll
;
; Rolls one of each: d20, d12, d10, d8, d6, d4 using the hardware PRNG
; (port 1, Galois LFSR).  Each die is rolled with rejection sampling so
; runtime per die is essentially flat regardless of N.
;
; ──────────────────────────────────────────────────────────────────────────
; Companion programs
; ──────────────────────────────────────────────────────────────────────────
;   examples/dice_mod.asm — same dice, but uses the simpler "modulo by
;                           repeated subtraction" approach with a `mod8`
;                           subroutine.  That version is correct but has
;                           variable runtime per die (d4 ~5× slower than
;                           d20 in the worst case) and a slight bias
;                           toward low values when 256 mod N ≠ 0.
;
;   This file (dice.asm) is the recommended version: rejection sampling
;   gives essentially constant time per die (~1.0–1.6 attempts) and is
;   unbiased.
;
; Final register layout (held until reset):
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
; Roll subroutine — `roll`
; ──────────────────────────────────────────────────────────────────────────
; Samples one die value uniformly in 1..N using rejection sampling against
; the smallest power-of-two ≥ N.  This gives roughly constant time per die
; (~1.0–1.6 attempts on average) instead of the variable-length repeated
; subtraction modulo used previously.
;
; Calling convention:
;   in : R6 = mask  (next power-of-two minus 1; e.g. 0x1F for d20)
;        R7 = limit (N, the die's face count)
;   out: R6 = die value in 1..N   (mask consumed, +1 already applied)
;        R7 unchanged
;
;   CLOBBERS: R5  (used as the working sample register).
;
; ⚠  Because R5 is clobbered by every call, the caller must NOT rely on R5
;    holding a previously-rolled die value during a later call.  This is
;    why d4 is rolled LAST — once R5 is written with the d4 result, no
;    further `roll` calls are made.
;
; CMP performs Ra - Rb and sets C=1 on borrow (i.e. when Ra < Rb).  We
; therefore loop while there is no borrow (R5 >= limit) and accept once
; R5 < limit.

.equ PRNG_PORT,    0x01

; ── Roll d20 → R0 ─────────────────────────────────────────────────────────

        LDI  R6, 0x1F            ; mask: next power-of-two − 1 (32−1)
        LDI  R7, 20              ; limit
        CALL roll
        MOV  R0, R6              ; R0 = d20 (1..20)

; ── Roll d12 → R1 ─────────────────────────────────────────────────────────

        LDI  R6, 0x0F            ; mask: 16−1
        LDI  R7, 12              ; limit
        CALL roll
        MOV  R1, R6              ; R1 = d12 (1..12)

; ── Roll d10 → R2 ─────────────────────────────────────────────────────────

        LDI  R6, 0x0F            ; mask: 16−1
        LDI  R7, 10              ; limit
        CALL roll
        MOV  R2, R6              ; R2 = d10 (1..10)

; ── Roll d8 → R3 ──────────────────────────────────────────────────────────

        LDI  R6, 0x07            ; mask: 8−1 (always accepts on first try)
        LDI  R7, 8               ; limit
        CALL roll
        MOV  R3, R6              ; R3 = d8 (1..8)

; ── Roll d6 → R4 ──────────────────────────────────────────────────────────

        LDI  R6, 0x07            ; mask: 8−1
        LDI  R7, 6               ; limit
        CALL roll
        MOV  R4, R6              ; R4 = d6 (1..6)

; ── Roll d4 → R5 ──────────────────────────────────────────────────────────
; (must be LAST — `roll` clobbers R5 as its working register.)

        LDI  R6, 0x03            ; mask: 4−1 (always accepts on first try)
        LDI  R7, 4               ; limit
        CALL roll
        MOV  R5, R6              ; R5 = d4 (1..4)

; ── Clear scratch registers so only R0..R5 hold meaningful values ───────

        LDI  R6, 0
        LDI  R7, 0

; ── All dice rolled — halt with results held in R0..R5 ───────────────────

        HALT

; ──────────────────────────────────────────────────────────────────────────
; roll — sample one die value in 1..N (rejection sampling)
;   in : R6 = mask, R7 = limit
;   out: R6 = result in 1..N
;   clobbers: R5
; ──────────────────────────────────────────────────────────────────────────
roll:
        IN   R5, PRNG_PORT       ; raw random byte
        AND  R5, R5, R6          ; mask down to next-power-of-two range
        CMP  R5, R7              ; R5 - limit; C=1 iff R5 < limit
        JNC  roll                ; reject (R5 >= limit) → redraw
        ADDI R6, R5, 1           ; accept and bias to 1..N
        RET
