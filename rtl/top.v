// =============================================================================
// top.v — MAX1000 top-level for the CPU (8-bit data path, 16-bit address space)
//
// USER_BTN (pin E6, active-low) — single button, dual function:
//   Short press (<0.35 s) → toggles LED display mode; CPU keeps running
//   Long  press (≥0.35 s) → resets the CPU; display mode is preserved
//
// Display modes:
//
//   Mode 0 — flags + PC (default):
//     LED[0]  — flag C  (carry)
//     LED[1]  — flag V  (overflow)
//     LED[2]  — heartbeat blink (toggles at CPU clock rate); solid ON when halted
//     LED[3]  — PC[4]
//     LED[4]  — PC[3]
//     LED[5]  — PC[2]
//     LED[6]  — PC[1]
//     LED[7]  — PC[0]
//
//   Mode 1 — R7 register value:
//     LED[0]  — R7[7]  (MSB)
//     LED[1]  — R7[6]
//     LED[2]  — R7[5]
//     LED[3]  — R7[4]
//     LED[4]  — R7[3]
//     LED[5]  — R7[2]
//     LED[6]  — R7[1]
//     LED[7]  — R7[0]  (LSB)
//
//   Mode 2 — OLED debug (FSM state + power/control signals):
//     LED[4:0] — oled_monitor FSM state (see localparam table in oled_monitor.v)
//     LED[5]   — vdd_en  (1 = VDD off, 0 = VDD on)
//     LED[6]   — vbat_en (1 = VBAT off, 0 = VBAT on)
//     LED[7]   — spi_res_n (0 = display in reset, 1 = released)
//
// LEDs are active-low: led=0 illuminates the LED.
//
// Clock: 12 MHz oscillator on pin H6.
//
// CPU clock: divided down from 12 MHz via a prescaler.
//   CPU_CLK_DIV_BITS selects how many bits of the prescaler counter are used.
//     bits=23 → 12_000_000 / 2^23 ≈  1.43 Hz  (one step per heartbeat blink)
//     bits=22 → ~2.86 Hz
//     bits=21 → ~5.7 Hz
//     bits=20 → ~11.4 Hz
//     bits=1  → 6 MHz (near full speed)
//
// Heartbeat: MSB of the CPU prescaler counter — toggles at the CPU clock
//   rate, so the blink is always synchronised with program execution speed.
//   Frozen solid (1) once the CPU halts.
//
// OLED Monitor: hardware debug display on the PmodOLED connected to the
//   MAX1000 PMOD header.  Runs entirely at 12 MHz — independent of CPU speed.
//   Continuously shows all 8 registers and flags in hex on the OLED.
//   The program name is injected at synthesis time via PROG_NAME parameter,
//   set from a "; name: <PROGRAM_NAME>" comment in the .asm source.
// =============================================================================

`include "build_config.vh"

module top (
    input  wire       clk_12m,    // 12 MHz board clock (pin H6)
    input  wire       rst_n,      // USER_BTN active-low (pin E6)
    output wire [7:0] led,        // active-low LEDs: LED[0]..LED[7]
    inout  wire [7:0] gpio,       // 8 bidirectional GPIO pins
    // adc_in: 8 MSBs of the MAX 10 internal ADC result, supplied by the
    // alt_adc_ctrl IP core. The external analog input is ADC channel AIN0 on
    // PIN_E1 (J1 pin 2 on the MAX1000 board). This port is driven by the IP
    // wrapper, not tied directly to a pad.
    input  wire [7:0] adc_in,     // ADC result [11:4] from alt_adc_ctrl IP

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

wire por_rst = (por_ctr != 5'd31);

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

// ---------------------------------------------------------------------------
// Display mode toggle — only on short press (was_long still 0 at release).
//   0 = flags + PC  (default)
//   1 = R7 register value
//   2 = OLED debug (FSM state + vdd_en + vbat_en + spi_res_n)
// Preserved across CPU resets.
// ---------------------------------------------------------------------------
reg [1:0] display_mode = 2'b00;
always @(posedge clk_12m)
    if (btn_released && !was_long)
        display_mode <= (display_mode == 2'd2) ? 2'd0 : display_mode + 2'd1;

// ---------------------------------------------------------------------------
// CPU clock prescaler — runs the CPU at a human-visible rate.
//   Change CPU_CLK_DIV_BITS to tune speed (see header for values).
// ---------------------------------------------------------------------------
parameter CPU_CLK_DIV_BITS = 20;

reg [CPU_CLK_DIV_BITS-1:0] cpu_div_ctr = {CPU_CLK_DIV_BITS{1'b0}};
always @(posedge clk_12m) begin
    if (rst)
        cpu_div_ctr <= {CPU_CLK_DIV_BITS{1'b0}};
    else
        cpu_div_ctr <= cpu_div_ctr + 1'b1;
end

// cpu_clk_en pulses for one clk_12m cycle every 2^CPU_CLK_DIV_BITS cycles.
wire cpu_clk_en = (cpu_div_ctr == {CPU_CLK_DIV_BITS{1'b1}});

// Registered clock enable to drive the CPU — avoids glitchy derived clocks,
// keeps everything in the clk_12m domain.
reg cpu_clk_r = 1'b0;
always @(posedge clk_12m) begin
    if (rst)
        cpu_clk_r <= 1'b0;
    else if (cpu_clk_en)
        cpu_clk_r <= ~cpu_clk_r;
end

wire cpu_clk = cpu_clk_r;

// ---------------------------------------------------------------------------
// Heartbeat — MSB of the CPU prescaler counter.
// Toggles at exactly the CPU clock rate, so the blink speed always matches
// program execution speed.  Frozen solid (1) once the CPU halts.
// ---------------------------------------------------------------------------
wire heartbeat = cpu_div_ctr[CPU_CLK_DIV_BITS-1];

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
wire [2:0]  cpu_periph_port;
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
                     & (cpu_periph_port == 3'b001);  // port 1 = PRNG seed

prng u_prng (
    .clk       (clk_12m),
    .rst       (rst),
    .seed      (cpu_div_ctr[7:0]),
    .load      (prng_load_req),
    .load_data (cpu_periph_data),
    .data      (prng_data)
);

// ---------------------------------------------------------------------------
// GPIO output register — driven by OUT Ra, 2 (port 2).
// Holds the last value written; reset to 0x00 on CPU reset.
// ---------------------------------------------------------------------------
reg [7:0] gpio_reg = 8'h00;
always @(posedge clk_12m) begin
    if (rst)
        gpio_reg <= 8'h00;
    else if (cpu_periph_we & (cpu_periph_port == 3'b010))
        gpio_reg <= cpu_periph_data;
end

// ---------------------------------------------------------------------------
// GPIO direction register — driven by OUT Ra, 3 (port 3).
// 1 = output, 0 = input.  Reset to all-inputs (0x00) on CPU reset.
// ---------------------------------------------------------------------------
reg [7:0] gpio_dir_reg = 8'h00;
always @(posedge clk_12m) begin
    if (rst)
        gpio_dir_reg <= 8'h00;
    else if (cpu_periph_we & (cpu_periph_port == 3'b011))
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
// CPU instantiation
// ---------------------------------------------------------------------------
wire       halt_out;
wire [7:0] dbg_pc;
wire       dbg_flag_z, dbg_flag_c, dbg_flag_n, dbg_flag_v;
wire [7:0] dbg_r0, dbg_r1, dbg_r2, dbg_r3;
wire [7:0] dbg_r4, dbg_r5, dbg_r6, dbg_r7;
wire [4:0] dbg_stack_depth;

cpu #(.ROM_INIT("program.hex")) u_cpu (
    .clk             (cpu_clk),
    .rst             (rst),
    .halt_out        (halt_out),
    .prng_data       (prng_data),
    .gpio_data       (gpio_in),
    .adc_data        (adc_in),
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
// Heartbeat / halt indicator (mode 0 only).
// ---------------------------------------------------------------------------
wire hb_or_halt = halt_out ? 1'b1 : heartbeat;

wire [7:0] dbg_oled;  // OLED debug: {spi_res_n, vbat_was_on, vdd_was_on, state[4:0]}

// ---------------------------------------------------------------------------
// LED mux — mode 0: flags + PC   mode 1: R7   mode 2: OLED debug
// Active-low: 0 = LED on, 1 = LED off.
// ---------------------------------------------------------------------------
assign led[0] = (display_mode == 2'd1) ? dbg_r7[7] :
                (display_mode == 2'd2) ? dbg_oled[0] : dbg_flag_c;
assign led[1] = (display_mode == 2'd1) ? dbg_r7[6] :
                (display_mode == 2'd2) ? dbg_oled[1] : dbg_flag_v;
assign led[2] = (display_mode == 2'd1) ? dbg_r7[5] :
                (display_mode == 2'd2) ? dbg_oled[2] : hb_or_halt;
assign led[3] = (display_mode == 2'd1) ? dbg_r7[4] :
                (display_mode == 2'd2) ? dbg_oled[3] : dbg_pc[4];
assign led[4] = (display_mode == 2'd1) ? dbg_r7[3] :
                (display_mode == 2'd2) ? dbg_oled[4] : dbg_pc[3];
assign led[5] = (display_mode == 2'd1) ? dbg_r7[2] :
                (display_mode == 2'd2) ? dbg_oled[5] : dbg_pc[2];
assign led[6] = (display_mode == 2'd1) ? dbg_r7[1] :
                (display_mode == 2'd2) ? dbg_oled[6] : dbg_pc[1];
assign led[7] = (display_mode == 2'd1) ? dbg_r7[0] :
                (display_mode == 2'd2) ? dbg_oled[7] : dbg_pc[0];

// ---------------------------------------------------------------------------
// OLED Hardware Monitor — runs at 12 MHz, reads CPU state directly.
// Continuously refreshes the PmodOLED with live register and flag values.
// PROG_NAME is injected at synthesis time via build_config.vh.
// ---------------------------------------------------------------------------
oled_monitor #(
    .PROG_NAME (`PROG_NAME)
) u_oled (
    .clk      (clk_12m),
    .rst      (por_rst),
    .r0       (dbg_r0),
    .r1       (dbg_r1),
    .r2       (dbg_r2),
    .r3       (dbg_r3),
    .r4       (dbg_r4),
    .r5       (dbg_r5),
    .r6       (dbg_r6),
    .r7       (dbg_r7),
    .pc       (dbg_pc),
    .stack_depth (dbg_stack_depth),
    .flag_c   (dbg_flag_c),
    .flag_z   (dbg_flag_z),
    .flag_n   (dbg_flag_n),
    .flag_v   (dbg_flag_v),
    .spi_cs_n (pmod_cs_n),
    .spi_clk  (pmod_sclk),
    .spi_mosi (pmod_mosi),
    .spi_dc   (pmod_dc),
    .spi_res_n(pmod_res_n),
    .vbat_en  (pmod_vbatc),
    .vdd_en   (pmod_vddc),
    .dbg_oled (dbg_oled)
);

endmodule
