; gpio.asm — GPIO bidirectional demo
; clk_div: 20
; name: GPIO Demo
;
; Demonstrates bidirectional GPIO using ports 4 and 5.
;
; Pin setup:
;   gpio[3:0]  (J1 pins 9–12) — configured as INPUTS
;   gpio[7:4]  (J1 pins 13–14, J2 pins 1–2) — configured as OUTPUTS
;
; Behaviour:
;   Continuously reads the 4 input pins and mirrors their state onto the
;   4 output pins (shifted up to bits [7:4]). The mirrored upper-nibble
;   output pattern is also shown on the onboard LEDs.
;
; Wiring suggestion:
;   Connect a jumper wire from any of J1/9–12 to 3.3V or GND and watch
;   the corresponding output pin (J1/13–14, J2/1–2) and LED follow it.
;
; Port map:
;   OUT Ra, 4  — set GPIO direction register (1=output, 0=input per bit)
;   OUT Ra, 5  — set GPIO output data register
;   IN  Rd, 5  — read GPIO pin logic levels
;   OUT Ra, 2  — drive onboard LEDs

.equ GPIO_DIR_PORT,  0x04   ; Port 4 = GPIO direction
.equ GPIO_DATA_PORT, 0x05   ; Port 5 = GPIO data (in and out)
.equ LEDS_PORT,      0x02   ; Port 2 = onboard LEDs

.equ DIR_MASK, 0xF0          ; gpio[7:4]=output (1), gpio[3:0]=input (0)

        ; --- initialise ---
        LDI  R0, DIR_MASK
        OUT  R0, GPIO_DIR_PORT   ; set direction: upper nibble out, lower in

loop:
        IN   R1, GPIO_DATA_PORT  ; read all 8 GPIO pins
        ; isolate lower nibble (input pins [3:0])
        LDI  R3, 0x0F
        AND  R2, R1, R3          ; R2 = gpio[3:0] input values
        ; shift left 4 to mirror onto output pins [7:4]
        SHL  R2, R2              ; after 1 shift: R2 <<= 1
        SHL  R2, R2              ; after 2 shifts: R2 <<= 2
        SHL  R2, R2              ; after 3 shifts: R2 <<= 3
        SHL  R2, R2              ; after 4 shifts: R2 <<= 4  →  R2 = inputs mirrored to [7:4]
        OUT  R2, GPIO_DATA_PORT  ; drive output pins
        OUT  R2, LEDS_PORT       ; show on LEDs too
        JMP  loop
