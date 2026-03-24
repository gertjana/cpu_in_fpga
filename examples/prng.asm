; prng.asm — hardware PRNG demo
; clk_div: 20
; name: Random
;
; Reads the hardware Galois psuedo-random number generator (rtl/prng.v) and displays each value on the LEDs

.equ PRNG_PORT,     0x01     ; Port 1 is PRNG
.equ LEDS_PORT,     0x02     ; Port 2 is LEDs
.equ INITIAL_SEED,  0x28   

        LDI  R0, INITIAL_SEED     
        OUT  R0, PRNG_PORT
loop:
        IN   R7, PRNG_PORT
        OUT  R7, LEDS_PORT
        JMP  loop           