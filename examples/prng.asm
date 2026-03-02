; prng.asm — hardware PRNG demo
; clk_div: 20
;
; Reads the hardware Galois LFSR (rtl/prng.v) into R7 on every CPU cycle

.equ PRNG_ADDR, 0x01    ; IN address for hardware PRNG (see rtl/prng.v)

loop:
        IN   R7, PRNG_ADDR
        JMP  loop           