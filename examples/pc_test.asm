; pc_test.asm — PC LED test
; clk_div: 21
;           12 MHz / 2^21 ≈ 5.7 Hz — slow enough to watch each value appear
;
; Counts PC through 0..31 visibly on LEDs[7:3], then jumps back to 0.
;
; Expected LED sequence (LED7..LED5 = PC[4..0]):
;   000 001 010 011 100 101 110 111 000 ...

        NOP         ; PC=0  → 00000
        NOP         ; PC=1  → 00001
        NOP         ; PC=2  → 00010
        NOP         ; PC=3  → 00011
        NOP         ; PC=4  → 00100
        NOP         ; PC=5  → 00101
        NOP         ; PC=6  → 00110
        NOP         ; PC=7  → 00111
        NOP         ; PC=8  → 01000
        NOP         ; PC=9  → 01001
        NOP         ; PC=10 → 01010
        NOP         ; PC=11 → 01011
        NOP         ; PC=12 → 01100
        NOP         ; PC=13 → 01101
        NOP         ; PC=14 → 01110
        NOP         ; PC=15 → 01111
        NOP         ; PC=16 → 10000
        NOP         ; PC=17 → 10001     
        NOP         ; PC=18 → 10010
        NOP         ; PC=19 → 10011
        NOP         ; PC=20 → 10100
        NOP         ; PC=21 → 10101
        NOP         ; PC=22 → 10110
        NOP         ; PC=23 → 10111
        NOP         ; PC=24 → 11000
        NOP         ; PC=25 → 11001
        NOP         ; PC=26 → 11010
        NOP         ; PC=27 → 11011
        NOP         ; PC=28 → 11100
        NOP         ; PC=29 → 11101
        NOP         ; PC=30 → 11110
        JMP 0       ; PC=31, jump back to 0
