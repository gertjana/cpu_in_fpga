; prng.asm — hardware PRNG demo
; clk_div: 20
;
; Reads the hardware Galois LFSR (rtl/prng.v) into R7 on every CPU cycle

.equ PRNG_ADDR,    0x01     ; Port 1 is PRNG
.equ INITIAL_SEED, 0x28   

        LDI  R0, INITIAL_SEED     
        OUT  R0, PRNG_ADDR
loop:
        IN   R7, PRNG_ADDR
        JMP  loop           