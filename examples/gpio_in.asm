; gpio_in.asm — GPIO input demo
; clk_div: 20
; name: GPIO Input Demo
;
; All 8 GPIO pins are configured as inputs.
; The pin values are continuously read and shown on the onboard LEDs.
;
; Convention: connect a pin to 3.3V → corresponding LED lights.
;             connect a pin to GND  → corresponding LED goes dark.
;
; Note: MAX10 GPIO pins are bidirectional with an output-enable, so Quartus
;       does not apply weak pull-ups to them.  Unconnected (floating) pins
;       will read unpredictably and cause the LEDs to cycle.
;       Drive all pins to a known level (3.3V or GND) for stable results.

.equ GPIO_DIR_PORT,  0x04   ; Port 4 = GPIO direction register (1=output, 0=input)
.equ GPIO_DATA_PORT, 0x05   ; Port 5 = GPIO data
.equ LEDS_PORT,      0x02   ; Port 2 = onboard LEDs

        ; --- configure all 8 GPIO pins as inputs ---
        LDI  R0, 0x00
        OUT  R0, GPIO_DIR_PORT

loop:
        IN   R1, GPIO_DATA_PORT  ; read all 8 GPIO pin values
        OUT  R1, LEDS_PORT       ; mirror onto the onboard LEDs
        JMP  loop
