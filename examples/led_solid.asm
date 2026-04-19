; led_solid.asm — light all 8 LEDs solidly (no GPIO)
; clk_div: 20
; name: LED Solid Test

        LDI  R0, 0xFF
loop:
        OUT  R0, 2
        JMP  loop
