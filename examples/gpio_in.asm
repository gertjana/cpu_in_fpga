; gpio_in.asm — GPIO single-pin input demo
; clk_div: 20
; name: GPIO Input Demo
;
; GPIO pin 0 (first pin on J1/J2 header) is configured as input.
; All other pins are configured as outputs (driven low) so they
; are not floating and do not affect the result.
;
; The program reads all 8 GPIO pins, masks to pin 0 only, and
; lights all 8 onboard LEDs when pin 0 is HIGH, turns them all
; off when pin 0 is LOW.
;
; Wiring: connect GPIO pin 0 to 3.3V → all LEDs on.
;         connect GPIO pin 0 to GND  → all LEDs off.
;         leave unconnected           → all LEDs off (pin driven low via output).

.equ GPIO_DIR_PORT,  0x04   ; Port 4 = GPIO direction register (1=output, 0=input)
.equ GPIO_DATA_PORT, 0x05   ; Port 5 = GPIO data
.equ LEDS_PORT,      0x02   ; Port 2 = onboard LEDs

        ; --- configure pin 0 as input, pins 1-7 as outputs driven low ---
        LDI  R0, 0x00           ; all outputs = 0 (drive pins 1-7 low)
        OUT  R0, GPIO_DATA_PORT
        LDI  R0, 0xFE           ; direction: pins 1-7 = output (1), pin 0 = input (0)
        OUT  R0, GPIO_DIR_PORT

        LDI  R2, 0x01           ; mask: bit 0 only

loop:
        IN   R1, GPIO_DATA_PORT  ; read all 8 GPIO pins
        AND  R1, R1, R2          ; mask to pin 0 only
        CMPI R1, 0x00            ; is pin 0 low?
        JZ   led_off             ; yes → turn LEDs off

        LDI  R0, 0xFF            ; pin 0 is high → all LEDs on
        OUT  R0, LEDS_PORT
        JMP  loop

led_off:
        LDI  R0, 0x00            ; pin 0 is low → all LEDs off
        OUT  R0, LEDS_PORT
        JMP  loop
