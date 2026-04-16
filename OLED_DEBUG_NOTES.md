# OLED Debug Investigation Notes

## Problem Statement

The OLED debug monitor (PmodOLED / SSD1306) is **completely black** (no pixels at all -- not even static labels like "R0-R3:" or the program name) for some programs but works perfectly for others.

| Program | OLED Status | LEDs | Key Characteristics |
|---------|------------|------|---------------------|
| jmp_loop.asm | WORKS | N/A | Single JMP 0, ALL registers always 0, maximum Quartus optimization |
| prng.asm | WORKS | OK | R0/R7 change unpredictably (PRNG), infinite loop |
| knightrider.asm | WORKS | OK | R1/R2/R7 change, infinite loop, clk_div=17 |
| fibonacci.asm | BLACK | LEDs work | R0-R3/R7 used, deterministic, HALTs |
| adc.asm | BLACK | LEDs work | Only R0 changes (from ADC), R1-R7 always 0 |

Reflashing knightrider (working) over a broken build immediately works -- ruling out hardware issues.

## Six Hypotheses DISPROVEN

### 1. Quartus constant-propagation/optimization breaks OLED -- DISPROVEN
`jmp_loop` triggers the MOST aggressive optimization (Quartus removes the entire CPU: regfile, ALU, RAM, stack, flags, PRNG, ADC). Yet the OLED works perfectly, displaying "00" for all registers.

### 2. OLED module resources differ between builds -- DISPROVEN
fit.rpt comparison across all builds: OLED module is virtually identical (146 regs, ~962-976 LCs, 82 input_barrier regs, 0 M9K blocks).

### 3. Timing violations break OLED -- DISPROVEN
STA reports: All four builds pass timing with NO violations. Worst-case Fmax margin is 2.37x. The ADC build (BROKEN) actually has the BEST timing margin (3.84x).

### 4. Uninferred RAM / font ROM causes blank screen -- DISPROVEN
Both working and broken builds have identical uninferred RAM messages. Font ROM and init sequence are implemented as `case` statements (pure combinational), not `initial` blocks.

### 5. FSM is stuck / init sequence fails -- DISPROVEN
Diagnostic build #1 (commit `71e44a3`): Routed OLED FSM state + power bits to LEDs. Result: LED pattern `11101111`:
- LED[0]=spi_res_n=1 (reset released)
- LED[1]=vbat_was_on=1 (VBAT enabled)
- LED[2]=vdd_was_on=1 (VDD enabled)
- state=01111=15 (ST_COL_WAIT -- the ~87% dominant state in a normally-running refresh loop, NOT a stuck state)

### 6. Font data / character data path is dead -- DISPROVEN
Diagnostic build #2 (commit `49c2be4`): Added `font_nonzero` and `ascii_nonspace` sticky flags. Result: LED pattern `11101111`:
- LED[0]=font_nonzero=1 -- font ROM IS producing non-zero pixel data
- LED[1]=ascii_nonspace=1 -- cur_ascii IS generating real characters (R, 0, :, etc.)
- LED[2]=vdd_was_on=1 (sanity check)
- state=01111=15 (normal refresh loop)

## Key Conclusion from Diagnostics

**The entire internal data path is working correctly.** The OLED FSM runs the refresh loop, characters are generated, font data is non-zero. Yet the screen is completely black. The problem is **downstream** -- somewhere between `spi_shift` loading valid data and the SSD1306 actually displaying pixels.

Possible causes:
- Quartus optimizing the `spi_shift -> spi_mosi` path despite `font_byte` being correct for the diagnostic flag
- SPI output signal corruption at the pin level due to placement/routing differences
- Some other issue in how dynamic `font_byte` feeds into `spi_shift` vs constant values

## Current State: DIAGNOSTIC BUILD #3 PUSHED, AWAITING TEST

**Commit `8b4e93c`** -- Forces `8'hFF` (all pixels ON) instead of `font_byte` in `ST_COL_DATA`, behind `ifdef OLED_DIAG`.

This is the decisive test to determine if the SPI engine itself works.

### What to do when CI finishes

1. Flash the **fibonacci** `.pof` onto the FPGA
2. Report what you see:

**If screen is fully WHITE (or filled with lit pixels):**
- SPI engine and init sequence work perfectly
- Problem is isolated to how `font_byte` feeds into `spi_shift` -- Quartus is optimizing/breaking that combinational path
- **Fix:** Add a registered pipeline stage for `font_byte` before `spi_send`

**If screen is still completely BLACK:**
- SPI engine itself is broken for this build despite sending constant `0xFF`
- **Next step:** Investigate SPI output timing, add delays between init commands, try different SPI clock divider

3. Also flash **knightrider** from the same CI run to confirm its LEDs show `11101111` (validates that pattern = normal OLED operation)

## Diagnostic Infrastructure in Place

These files have `ifdef OLED_DIAG` conditional code:
- `rtl/oled_monitor.v` -- 0xFF override in ST_COL_DATA, font_nonzero/ascii_nonspace sticky flags, conditional dbg_oled assignment
- `rtl/top.v` -- Routes dbg_oled to LEDs when OLED_DIAG defined
- `rtl/build_config.vh` -- Contains `` `define OLED_DIAG ``
- `.github/workflows/synthesize.yml` -- Contains `` `define OLED_DIAG `` in CI-generated build_config.vh

### Cleanup after fix is found
- Remove `OLED_DIAG` define from CI and `build_config.vh`
- Keep the `ifdef` infrastructure in source files for future use

## Protection Attributes Already Applied
- All SPI output ports (`spi_mosi`, `spi_clk`, `spi_cs_n`, `spi_dc`, `spi_res_n`, `vbat_en`, `vdd_en`) have `(* preserve, noprune *)` attributes
- `input_barrier` module has `(* preserve, noprune, dont_merge *)` on all output regs and `AUTO_CLOCK_ENABLE_RECOGNITION OFF` on the module

## All 10 Simulation Testbenches Pass
Throughout all changes, all 10 testbenches continue to pass.

## Commit History (relevant)
```
8b4e93c diag: force 0xFF pixel data to test SPI engine (diagnostic build #3)
49c2be4 diag: add font_nonzero and ascii_nonspace sticky flags to dbg_oled
71e44a3 diag: route OLED FSM state to LEDs for black-screen debugging
33aa86d diag: add map.rpt to CI artifacts + jmp_loop minimal test program
f129c86 fix: replace synthesis black_box with per-register preserve/noprune attributes in input_barrier
993bd35 Fix OLED testbench: add missing input_barrier.v and halt port
```

## Future Test Programs (not yet tested on hardware)
- `infinite_counter.asm` -- loops, no HALT
- `count_to_9.asm` -- loops then HALTs
These can help validate the fix once found (especially count_to_9 which HALTs like fibonacci).
