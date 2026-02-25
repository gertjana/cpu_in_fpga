; pc_test.asm — PC LED test
; Counts PC through 0..8 visibly on LEDs[7:5], then jumps back to 0.
; At ~1.4 Hz CPU clock each step is clearly visible.
;
; Expected LED sequence (LED7..LED5 = PC[2..0]):
;   000 001 010 011 100 101 110 111 000 ...

        NOP         ; PC=0  → 000
        NOP         ; PC=1  → 001
        NOP         ; PC=2  → 010
        NOP         ; PC=3  → 011
        NOP         ; PC=4  → 100
        NOP         ; PC=5  → 101
        NOP         ; PC=6  → 110
        NOP         ; PC=7  → 111
        JMP 0       ; PC=8, jump back to 0
