; knightrider.asm — Knight Rider LED scanner (K.I.T.T. from the TV series)
;
; A single lit LED bounces left and right across the 8 LEDs continuously.
;
; LED mapping (mode 1, R7 displayed on LEDs):
;   LED[0] = R7[7]  (MSB, leftmost)
;   LED[1] = R7[6]
;   LED[2] = R7[5]
;   LED[3] = R7[4]
;   LED[4] = R7[3]
;   LED[5] = R7[2]
;   LED[6] = R7[1]
;   LED[7] = R7[0]  (LSB, rightmost)
;
; Pattern (one LED lit at a time):
;   R7 = 1000_0000  LED[0] on  → scan right
;   R7 = 0100_0000  LED[1] on
;   R7 = 0010_0000  LED[2] on
;   R7 = 0001_0000  LED[3] on
;   R7 = 0000_1000  LED[4] on
;   R7 = 0000_0100  LED[5] on
;   R7 = 0000_0010  LED[6] on
;   R7 = 0000_0001  LED[7] on  → reverse, scan left
;   R7 = 0000_0010  LED[6] on
;   ...and so on forever.
;
; Algorithm:
;   Check the edge *before* shifting, so R7 is never 0x00 (all LEDs off).
;
;   scan_right:
;     CMP  R7, R2      ; already at rightmost (0x01)?
;     JZ   scan_left   ; yes → reverse without shifting
;     SHR  R7, R7      ; no  → move one step right
;     JMP  scan_right
;
;   scan_left:
;     CMP  R7, R1      ; already at leftmost (0x80)?
;     JZ   scan_right  ; yes → reverse without shifting
;     SHL  R7, R7      ; no  → move one step left
;     JMP  scan_left
;
; Register use:
;   R1 = 0x80  — leftmost edge value
;   R2 = 0x01  — rightmost edge value
;   R7 = current LED pattern (shown on LEDs in display mode 1)
;
; This program runs forever — it never halts.

; ── initialise ────────────────────────────────────────────────────────────────

; Build R1 = 0x80.  LDI is limited to 6-bit immediates (0..63),
; so 0x80 (128) cannot be loaded directly.  Compute via two SHL from 0x20.
        LDI  R1, 0x20       ; R1 = 0x20
        SHL  R1, R1         ; R1 = 0x40
        SHL  R1, R1         ; R1 = 0x80  — leftmost edge

        LDI  R2, 1          ; R2 = 0x01  — rightmost edge

        MOV  R7, R1         ; R7 = 0x80 (LED[0] on), start scanning right

; ── scan right (SHR: moves lit bit from LED[0] toward LED[7]) ─────────────────

scan_right:
        CMP  R7, R2         ; R7 == 0x01 (rightmost edge)?
        JZ   scan_left      ; yes → reverse, scan left
        SHR  R7, R7         ; no  → step right
        JMP  scan_right

; ── scan left (SHL: moves lit bit from LED[7] toward LED[0]) ──────────────────

scan_left:
        CMP  R7, R1         ; R7 == 0x80 (leftmost edge)?
        JZ   scan_right     ; yes → reverse, scan right
        SHL  R7, R7         ; no  → step left
        JMP  scan_left
