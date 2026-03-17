; knightrider.asm — Knight Rider LED scanner (K.I.T.T. from the TV series)
; clk_div: 17
; name: Knightrider
;
; A single lit LED bounces left and right across the 8 LEDs continuously.
;
; Register use:
;   R1 = 0x80  — leftmost edge value
;   R2 = 0x01  — rightmost edge value
;   R7 = current LED pattern (shown on LEDs in display mode 1)
;
; This program runs forever — it never halts.

; Build R1 = 0x80.  LDI is limited to 6-bit immediates (0..63),
; so 0x80 (128) cannot be loaded directly.  Compute via two SHL from 0x20.
        LDI  R1, 0x20       ; R1 = 0x20
        SHL  R1, R1         ; R1 = 0x40
        SHL  R1, R1         ; R1 = 0x80  — leftmost edge

        LDI  R2, 1          ; R2 = 0x01  — rightmost edge

        MOV  R7, R1         ; R7 = 0x80 (LED[0] on), start scanning right

scan_right:
        CMP  R7, R2         ; R7 == 0x01 (rightmost edge)?
        JZ   scan_left      ; yes → reverse, scan left
        SHR  R7, R7         ; no  → step right
        JMP  scan_right

scan_left:
        CMP  R1, R7         ; R7 == 0x80 (leftmost edge)?
        JZ   scan_right     ; yes → reverse, scan right
        SHL  R7, R7         ; no  → step left
        JMP  scan_left
