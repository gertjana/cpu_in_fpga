; prng.asm — hardware PRNG demo
; clk_div: 20
; name: Random
;
; Reads the hardware Galois LFSR (rtl/prng.v) and displays each value on the LEDs

.equ PRNG_ADDR,    0x01     ; Port 1 is PRNG
.equ INITIAL_SEED, 0x28   

        LDI  R0, INITIAL_SEED     
        OUT  R0, PRNG_ADDR
loop:
        IN   R7, PRNG_ADDR
        OUT  R7, 2          ; display on LEDs
        JMP  loop           