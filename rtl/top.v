// =============================================================================
// top.v — MAX1000 top-level for the CPU (8-bit data path, 16-bit address space)
//
// USER_BTN (pin E6, active-low) — resets the CPU on long press (≥0.35 s).
//
// LEDs are driven by the CPU via the OUT Ra, 2 instruction:
//   LED[0] = Ra[7] (MSB), LED[7] = Ra[0] (LSB)
//   Active-low: led=0 illuminates the LED (hardware-inverted on the board).
//   All LEDs are off (0x00) at reset.
//
// Clock: 12 MHz oscillator on pin H6.
//
// CPU clock: divided down from 12 MHz via a prescaler.
//   CPU_CLK_DIV_BITS selects how many bits of the prescaler counter are used.
//     bits=23 → 12_000_000 / 2^23 ≈  1.43 Hz
//     bits=22 → ~2.86 Hz
//     bits=21 → ~5.7 Hz
//     bits=20 → ~11.4 Hz
//     bits=1  → 6 MHz (near full speed)
//
// OLED Monitor: hardware debug display on the PmodOLED connected to the
//   MAX1000 PMOD header.  Runs entirely at 12 MHz — independent of CPU speed.
//   Continuously shows all 8 registers and flags in hex on the OLED.
//   The program name is injected at synthesis time via PROG_NAME parameter,
//   set from a "; name: <PROGRAM_NAME>" comment in the .asm source.
//
// ADC: The MAX10 internal ADC is driven by the alt_adc_ctrl IP core,
//   instantiated directly inside this module.  The analog input is the
//   dedicated ANAIN pin (PIN_D2, labelled AIN on the MAX1000 board / J1
//   header).  This pin is connected internally by the IP — it must NOT be
//   declared as a top-level port.  The IP continuously samples channel 0
//   (ANAIN) and exposes the 12-bit result via an Avalon-ST response port.
//   Only the top 8 bits [11:4] are forwarded to the CPU as adc_data[7:0]
//   (IN Rd, 3).
// =============================================================================

`include "build_config.vh"

module top (
    input  wire       clk_12m,    // 12 MHz board clock (pin H6)
    input  wire       rst_n,      // USER_BTN active-low (pin E6)
    output wire [7:0] led,        // active-low LEDs: LED[0]..LED[7]
    inout  wire [7:0] gpio,       // 8 bidirectional GPIO pins
    // PmodOLED signals — MAX1000 PMOD header pins
    output wire       pmod_cs_n,  // PIN_M3  PMOD pin 1  — SPI chip select
    output wire       pmod_mosi,  // PIN_L3  PMOD pin 2  — SPI MOSI (SDIN)
    output wire       pmod_sclk,  // PIN_M1  PMOD pin 4  — SPI clock
    output wire       pmod_dc,    // PIN_N3  PMOD pin 7  — Data/Command
    output wire       pmod_res_n, // PIN_N2  PMOD pin 8  — Reset (active low)
    output wire       pmod_vbatc, // PIN_K2  PMOD pin 9  — VBAT control
    output wire       pmod_vddc   // PIN_K1  PMOD pin 10 — VDD  control
);

// ---------------------------------------------------------------------------
// 2-FF synchroniser — bring raw async button into the clock domain.
// Button pressed (rst_n=0) → btn_raw=1.
// ---------------------------------------------------------------------------
reg btn_meta, btn_raw;
always @(posedge clk_12m) begin
    btn_meta <= ~rst_n;
    btn_raw  <= btn_meta;
end

// ---------------------------------------------------------------------------
// Debounce filter — only update btn_db after the input has been stable for
// DEBOUNCE_CYCLES consecutive cycles (~5 ms at 12 MHz = 60000 cycles, fits
// in 16 bits).  This eliminates spurious edges from contact bounce.
// ---------------------------------------------------------------------------
parameter DEBOUNCE_CYCLES = 16'd60_000;

reg [15:0] db_ctr;
reg        btn_db;   // debounced button level (1 = pressed)

always @(posedge clk_12m) begin
    if (btn_raw == btn_db) begin
        // Input matches current debounced level — reset counter.
        db_ctr <= 16'd0;
    end else begin
        // Input differs — count stable cycles.
        if (db_ctr == DEBOUNCE_CYCLES - 1) begin
            // Stable long enough: commit new level and reset counter.
            btn_db <= btn_raw;
            db_ctr <= 16'd0;
        end else begin
            db_ctr <= db_ctr + 1'b1;
        end
    end
end

// ---------------------------------------------------------------------------
// Hold-duration counter.
// Counts up while debounced button is held; clears when released.
// Saturates at (2^LONG_PRESS_BITS - 1) — never wraps.
// At 12 MHz, 2^22 cycles ≈ 0.35 s.
// ---------------------------------------------------------------------------
parameter LONG_PRESS_BITS   = 22;
parameter LONG_PRESS_CYCLES = (1 << LONG_PRESS_BITS) - 1;

reg [LONG_PRESS_BITS-1:0] hold_ctr;
always @(posedge clk_12m) begin
    if (!btn_db)
        hold_ctr <= {LONG_PRESS_BITS{1'b0}};
    else if (hold_ctr != LONG_PRESS_CYCLES[LONG_PRESS_BITS-1:0])
        hold_ctr <= hold_ctr + 1'b1;
end

// ---------------------------------------------------------------------------
// was_long: latched the moment the threshold is crossed while held.
// Cleared when the button is released.
// Checked on release to distinguish short from long press.
// ---------------------------------------------------------------------------
reg was_long;
always @(posedge clk_12m) begin
    if (!btn_db)
        was_long <= 1'b0;
    else if (hold_ctr == LONG_PRESS_CYCLES[LONG_PRESS_BITS-1:0])
        was_long <= 1'b1;
end

// ---------------------------------------------------------------------------
// Power-on reset — asserts rst for 32 clk_12m cycles after FPGA configuration
// so all synchronous reset blocks fire reliably, independent of Quartus
// register power-up values.
// The counter starts at 0 and counts up; rst is held high until it reaches 31.
// After that it stays at 31 forever and contributes nothing.
// ---------------------------------------------------------------------------
reg [4:0] por_ctr = 5'd0;
always @(posedge clk_12m)
    if (por_ctr != 5'd31)
        por_ctr <= por_ctr + 1'b1;

wire por_rst /* synthesis keep */ = (por_ctr != 5'd31);

// CPU reset is active during power-on OR while long-press threshold is held.
wire rst = por_rst | was_long;

// OLED monitor reset is power-on only — never re-triggered by a button long-press.
// This prevents the OLED init sequence (VDD/VBAT power-up, SPI init) from being
// interrupted and restarted mid-sequence when the user holds the reset button.

// ---------------------------------------------------------------------------
// Release edge detector — one-cycle pulse on debounced button release.
// ---------------------------------------------------------------------------
reg btn_prev = 1'b0;
always @(posedge clk_12m)
    btn_prev <= btn_db;

wire btn_released = btn_prev & ~btn_db;

// (display mode removed — LEDs are now driven directly by OUT Ra, 2)

// ---------------------------------------------------------------------------
// CPU clock prescaler — runs the CPU at a human-visible rate.
//   Change CPU_CLK_DIV_BITS to tune speed (see header for values).
// ---------------------------------------------------------------------------
parameter CPU_CLK_DIV_BITS = 20;

// Free-running counter — intentionally no reset gate so the low 8 bits
// hold unpredictable timing entropy when the reset button is released.
// This value is used as the PRNG seed in prng.v.
reg [CPU_CLK_DIV_BITS-1:0] cpu_div_ctr = {CPU_CLK_DIV_BITS{1'b0}};
always @(posedge clk_12m) begin
    cpu_div_ctr <= cpu_div_ctr + 1'b1;
end

// cpu_clk_en pulses for one clk_12m cycle every 2^CPU_CLK_DIV_BITS cycles.
wire cpu_clk_en = (cpu_div_ctr == {CPU_CLK_DIV_BITS{1'b1}});

// ---------------------------------------------------------------------------
// Hardware PRNG — clocked directly by the 12 MHz board oscillator.
// Runs ~1 million steps per CPU instruction, so every IN read is at a
// different point in the 255-step LFSR sequence.
// The low 8 bits of cpu_div_ctr are used as the seed: they are captured
// at the moment the reset button is released, giving a different starting
// point in the sequence on every press (button-timing entropy).
wire [7:0] prng_data;

// CPU peripheral write interface — these signals are in the cpu_clk domain.
// They are stable for many clk_12m cycles (cpu_clk period >> clk_12m period),
// so it is safe to sample them directly in the fast clock domain.
wire        cpu_periph_we;
wire [3:0]  cpu_periph_port;
wire [7:0]  cpu_periph_data;

// PRNG load pulse: register the previous value of periph_we (as seen in the
// fast clock) and detect the rising edge to generate a one-cycle load pulse.
reg cpu_periph_we_prev = 1'b0;
always @(posedge clk_12m) begin
    if (rst)
        cpu_periph_we_prev <= 1'b0;
    else
        cpu_periph_we_prev <= cpu_periph_we;
end

wire prng_load_req = cpu_periph_we & ~cpu_periph_we_prev
                     & (cpu_periph_port == 4'd1);  // port 1 = PRNG seed

prng u_prng (
    .clk       (clk_12m),
    .rst       (rst),
    .seed      (cpu_div_ctr[7:0]),
    .load      (prng_load_req),
    .load_data (cpu_periph_data),
    .data      (prng_data)
);

// ---------------------------------------------------------------------------
// LED register — driven by OUT Ra, 2 (port 2).
// LED[0] = Ra[7] (MSB), LED[7] = Ra[0] (LSB).
// Holds the last value written; reset to 0x00 on CPU reset.
// Active-low hardware is compensated in the assign statements below,
// so from the programmer's perspective the LEDs are active-high:
// 0xFF = all on, 0x00 = all off.
// ---------------------------------------------------------------------------
reg [7:0] led_reg = 8'h00;
always @(posedge clk_12m) begin
    if (rst)
        led_reg <= 8'h00;
    else if (cpu_periph_we & (cpu_periph_port == 4'd2))
        led_reg <= cpu_periph_data;
end

// ---------------------------------------------------------------------------
// GPIO output register — driven by OUT Ra, 5 (port 5).
// Only pins whose direction bit is 1 (output) will drive this value.
// Reset to 0x00 on CPU reset.
// ---------------------------------------------------------------------------
reg [7:0] gpio_reg = 8'h00;
always @(posedge clk_12m) begin
    if (rst)
        gpio_reg <= 8'h00;
    else if (cpu_periph_we & (cpu_periph_port == 4'd5))
        gpio_reg <= cpu_periph_data;
end

// ---------------------------------------------------------------------------
// GPIO direction register — driven by OUT Ra, 4 (port 4).
// 1 = output, 0 = input.  Reset to all-inputs (0x00) on CPU reset.
// ---------------------------------------------------------------------------
reg [7:0] gpio_dir_reg = 8'h00;
always @(posedge clk_12m) begin
    if (rst)
        gpio_dir_reg <= 8'h00;
    else if (cpu_periph_we & (cpu_periph_port == 4'd4))
        gpio_dir_reg <= cpu_periph_data;
end

// ---------------------------------------------------------------------------
// GPIO tri-state drivers — each pin is driven when its direction bit is 1,
// and left floating (high-Z) when 0 so it acts as an input.
// gpio (inout) is the single bidirectional port presented to the pin-planner.
// ---------------------------------------------------------------------------
genvar gi;
generate
    for (gi = 0; gi < 8; gi = gi + 1) begin : gpio_tris
        assign gpio[gi] = gpio_dir_reg[gi] ? gpio_reg[gi] : 1'bz;
    end
endgenerate

// Read-back: capture current pin value regardless of direction.
wire [7:0] gpio_in = gpio;

// ---------------------------------------------------------------------------
// MAX10 internal ADC — alt_adc_ctrl IP instantiation
//
// The alt_adc_ctrl IP (from the Quartus IP Catalog / Platform Designer) wraps
// the MAX10 ADC hard block.  It operates in "run continuously" mode, sampling
// a single channel (channel 0 = ANAIN = PIN_D2) and presenting each result
// on the Avalon-ST response port.
//
// Interface summary:
//   clk_clk             — system clock (12 MHz)
//   reset_sink_reset_n  — active-low reset
//   adc_pll_clock_clk   — dedicated ADC clock; for the MAX10 internal ADC the
//                         IP uses the alt_pll IP for this
//   command_valid       — tied 1'b1: always issue sample commands
//   command_channel     — tied 5'b00000: sample ANAIN (channel 0)
//   command_startofpacket / endofpacket — tie both 1'b1 for single-channel
//   command_ready       — output from IP (we ignore it; command is always valid)
//   response_valid      — pulses 1 each time a new 12-bit result is ready
//   response_channel    — channel index of the result (always 0 here)
//   response_data       — 12-bit ADC result (0x000 = 0V, 0xFFF = 3.3V)
//   response_startofpacket / endofpacket — Avalon-ST framing (ignored)
//
// The top 8 bits [11:4] of the 12-bit result are latched into adc_result on
// each valid pulse, giving a 0–255 range over 0–3.3V (≈12.9 mV resolution).
// This value is forwarded to the CPU as adc_data (IN Rd, 3).
// ---------------------------------------------------------------------------

wire        adc_pll_clk;     // 2 MHz from ALTPLL C0 — fed to ADC hard block
wire        adc_pll_locked;  // ALTPLL locked flag — forwarded to alt_adc_ctrl

wire        adc_response_valid;
wire [4:0]  adc_response_channel;
wire [11:0] adc_response_data;

// Latch the 8 MSBs of the ADC result each time a new sample arrives.
reg [7:0] adc_result = 8'h00;
always @(posedge clk_12m) begin
    if (rst)
        adc_result <= 8'h00;
    else if (adc_response_valid)
        adc_result <= adc_response_data[11:4];
end

// ---------------------------------------------------------------------------
// ALTPLL — generates 2 MHz (÷6 from 12 MHz) for the ADC hard block.
// inclk0 = 12 MHz board oscillator; c0 = 2 MHz → adc_pll_clock_clk.
// areset is tied low (no async reset needed for the PLL).
// ---------------------------------------------------------------------------
alt_pll u_pll (
    .inclk0 (clk_12m),
    .areset (1'b0),
    .c0     (adc_pll_clk),
    .locked (adc_pll_locked)
);

alt_adc_ctrl u_adc (
    // Clocks & reset
    .clock_clk                  (clk_12m),      // system clock (12 MHz)
    .reset_sink_reset_n         (~rst),
    .adc_pll_clock_clk          (adc_pll_clk),  // 2 MHz from ALTPLL C0
    .adc_pll_locked_export      (adc_pll_locked), // PLL locked signal
    // Command channel — continuously request channel 0 (ANAIN = PIN_D2)
    .command_valid              (1'b1),
    .command_channel            (5'd0),
    .command_startofpacket      (1'b1),
    .command_endofpacket        (1'b1),
    .command_ready              (),       // ignored — we always send
    // Response channel — capture ADC results
    .response_valid             (adc_response_valid),
    .response_channel           (adc_response_channel),
    .response_data              (adc_response_data),
    .response_startofpacket     (),       // ignored
    .response_endofpacket       ()        // ignored
);

// ---------------------------------------------------------------------------
// CPU instantiation
// ---------------------------------------------------------------------------
wire       halt_out;
wire [7:0] dbg_pc            /* synthesis keep */;
wire       dbg_flag_z        /* synthesis keep */;
wire       dbg_flag_c        /* synthesis keep */;
wire       dbg_flag_n        /* synthesis keep */;
wire       dbg_flag_v        /* synthesis keep */;
wire [7:0] dbg_r0            /* synthesis keep */;
wire [7:0] dbg_r1            /* synthesis keep */;
wire [7:0] dbg_r2            /* synthesis keep */;
wire [7:0] dbg_r3            /* synthesis keep */;
wire [7:0] dbg_r4            /* synthesis keep */;
wire [7:0] dbg_r5            /* synthesis keep */;
wire [7:0] dbg_r6            /* synthesis keep */;
wire [7:0] dbg_r7            /* synthesis keep */;
wire [4:0] dbg_stack_depth   /* synthesis keep */;

cpu #(.ROM_INIT("program.hex")) u_cpu (
    .clk             (clk_12m),
    .ce              (cpu_clk_en),
    .rst             (rst),
    .halt_out        (halt_out),
    .prng_data       (prng_data),
    .gpio_data       (gpio_in),
    .adc_data        (adc_result),
    .periph_we       (cpu_periph_we),
    .periph_port     (cpu_periph_port),
    .periph_data     (cpu_periph_data),
    .dbg_pc          (dbg_pc),
    .dbg_flag_z      (dbg_flag_z),
    .dbg_flag_c      (dbg_flag_c),
    .dbg_flag_n      (dbg_flag_n),
    .dbg_flag_v      (dbg_flag_v),
    .dbg_r0          (dbg_r0),
    .dbg_r1          (dbg_r1),
    .dbg_r2          (dbg_r2),
    .dbg_r3          (dbg_r3),
    .dbg_r4          (dbg_r4),
    .dbg_r5          (dbg_r5),
    .dbg_r6          (dbg_r6),
    .dbg_r7          (dbg_r7),
    .dbg_stack_top   (),
    .dbg_stack_empty (),
    .dbg_stack_depth (dbg_stack_depth)
);

// ---------------------------------------------------------------------------
// LED output — normally driven by led_reg (OUT Ra, 2).
//
// DIAGNOSTIC MODE (OLED_DIAG): route dbg_oled to LEDs so the OLED data
// path and FSM state can be observed on a build where the display is
// completely black.
//
//   dbg_oled (OLED_DIAG) = {font_nonzero, ascii_nonspace, vdd_was_on, state[4:0]}
//
//   LED[0] = font_nonzero   — 1 if font ROM ever produced non-zero pixel data
//   LED[1] = ascii_nonspace — 1 if cur_ascii was ever a non-space character
//   LED[2] = vdd_was_on     — 1 after VDD enabled (sanity check, should be 1)
//   LED[3..7] = state[4:0]  — FSM state (see oled_monitor.v localparams)
//
// Expected on a WORKING build:  LEDs 0-2 all lit (font data present,
// non-space chars found, VDD on), LEDs 3-7 appearing as 01111 (state 15
// dominates at ~87% — ST_COL_WAIT).
//
// If LED[0]=0: font_byte is always 0x00 — font_lookup broken or optimised away
// If LED[1]=0: cur_ascii is always space — data path before font ROM is dead
// If LED[0]=1 but screen still black: SPI MOSI line or hardware issue
//
// To disable: comment out `define OLED_DIAG in build_config.vh and rebuild.
// ---------------------------------------------------------------------------
`ifdef OLED_DIAG
assign led[0] = dbg_oled[7];  // font_nonzero
assign led[1] = dbg_oled[6];  // ascii_nonspace
assign led[2] = dbg_oled[5];  // vdd_was_on
assign led[3] = dbg_oled[4];  // state[4]
assign led[4] = dbg_oled[3];  // state[3]
assign led[5] = dbg_oled[2];  // state[2]
assign led[6] = dbg_oled[1];  // state[1]
assign led[7] = dbg_oled[0];  // state[0]
`else
assign led[0] = led_reg[7];
assign led[1] = led_reg[6];
assign led[2] = led_reg[5];
assign led[3] = led_reg[4];
assign led[4] = led_reg[3];
assign led[5] = led_reg[2];
assign led[6] = led_reg[1];
assign led[7] = led_reg[0];
`endif

wire [7:0] dbg_oled;  // OLED debug (DIAG: {font_nz, ascii_nsp, vdd, state[4:0]})

// ---------------------------------------------------------------------------
// OLED Hardware Monitor — runs at 12 MHz, reads CPU state directly.
// Continuously refreshes the PmodOLED with live register and flag values.
// PROG_NAME is injected at synthesis time via build_config.vh.
// ---------------------------------------------------------------------------
oled_monitor #(
    .PROG_NAME (`PROG_NAME)
) u_oled (
    .clk         (clk_12m),
    .rst         (por_rst),
    .halt        (halt_out),
    .r0          (dbg_r0),
    .r1          (dbg_r1),
    .r2          (dbg_r2),
    .r3          (dbg_r3),
    .r4          (dbg_r4),
    .r5          (dbg_r5),
    .r6          (dbg_r6),
    .r7          (dbg_r7),
    .pc          (dbg_pc),
    .stack_depth (dbg_stack_depth),
    .flag_c      (dbg_flag_c),
    .flag_z      (dbg_flag_z),
    .flag_n      (dbg_flag_n),
    .flag_v      (dbg_flag_v),
    .spi_cs_n    (pmod_cs_n),
    .spi_clk     (pmod_sclk),
    .spi_mosi    (pmod_mosi),
    .spi_dc      (pmod_dc),
    .spi_res_n   (pmod_res_n),
    .vbat_en     (pmod_vbatc),
    .vdd_en      (pmod_vddc),
    .dbg_oled    (dbg_oled)
);

endmodule
