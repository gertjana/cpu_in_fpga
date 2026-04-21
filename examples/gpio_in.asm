; gpio_in.asm — GPIO single-pin input demo
; clk_div: 20
; name: GPIO Input Demo
;
; GPIO pin 0 (first pin on J1/J2 header) is configured as input.
; All other pins are configured as outputs (driven low).
;
; The masked value of pin 0 is written directly to the LEDs:
;   pin 0 HIGH (3.3V or floating) → LED 0 lit (0x01)
;   pin 0 LOW  (GND)              → all LEDs off (0x00)

.equ GPIO_DIR_PORT,  0x04   ; Port 4 = GPIO direction register (1=output, 0=input)
.equ GPIO_DATA_PORT, 0x05   ; Port 5 = GPIO data
.equ LEDS_PORT,      0x02   ; Port 2 = onboard LEDs

        ; --- diagnostic: write constant 0xAA to LEDs and halt ---
        LDI  R0, 0xAA
        OUT  R0, LEDS_PORT
        HALT
