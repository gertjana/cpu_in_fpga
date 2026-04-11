; jmp_loop.asm — minimal test: infinite JMP to self
; clk_div: 20
; name: JMP Loop
;
; Single-instruction program: just jumps to address 0 forever.
; No registers are written, no HALT. This is the most aggressively
; optimizable program — Quartus can prove every register is always 0.
; Used to diagnose OLED blank-screen issue.

loop:
        JMP  loop
