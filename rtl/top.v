// =============================================================================
// top.v — MAX1000 top-level for the 8-bit CPU
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
// =============================================================================

module top (
    input  wire       clk_12m,   // 12 MHz board clock (pin H6)
    input  wire       rst_n,     // USER_BTN active-low (pin E6)
    output wire [7:0] led        // active-low LEDs: LED[0]..LED[7]
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

// CPU reset is active while long-press threshold is held.
wire rst = was_long;

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
// Preserved across CPU resets.
// ---------------------------------------------------------------------------
reg display_mode = 1'b0;
always @(posedge clk_12m)
    if (btn_released && !was_long)
        display_mode <= ~display_mode;

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
// ---------------------------------------------------------------------------
wire [7:0] prng_data;

prng u_prng (
    .clk  (clk_12m),
    .rst  (rst),
    .data (prng_data)
);

// ---------------------------------------------------------------------------
// CPU instantiation
// ---------------------------------------------------------------------------
wire       halt_out;
wire [7:0] dbg_pc;
wire       dbg_flag_z, dbg_flag_c, dbg_flag_n, dbg_flag_v;
wire [7:0] dbg_r7;

cpu #(.ROM_INIT("program.hex")) u_cpu (
    .clk             (cpu_clk),
    .rst             (rst),
    .halt_out        (halt_out),
    .prng_data       (prng_data),
    .dbg_pc          (dbg_pc),
    .dbg_flag_z      (dbg_flag_z),
    .dbg_flag_c      (dbg_flag_c),
    .dbg_flag_n      (dbg_flag_n),
    .dbg_flag_v      (dbg_flag_v),
    .dbg_r7          (dbg_r7),
    .dbg_stack_top   (),
    .dbg_stack_empty ()
);

// ---------------------------------------------------------------------------
// Heartbeat / halt indicator (mode 0 only).
// ---------------------------------------------------------------------------
wire hb_or_halt = halt_out ? 1'b1 : heartbeat;

// ---------------------------------------------------------------------------
// LED mux — mode 0: flags + PC   mode 1: R7
// Active-low: 0 = LED on, 1 = LED off.
// ---------------------------------------------------------------------------
assign led[0] = display_mode ? dbg_r7[7] : dbg_flag_c;
assign led[1] = display_mode ? dbg_r7[6] : dbg_flag_v;
assign led[2] = display_mode ? dbg_r7[5] : hb_or_halt;
assign led[3] = display_mode ? dbg_r7[4] : dbg_pc[4];
assign led[4] = display_mode ? dbg_r7[3] : dbg_pc[3];
assign led[5] = display_mode ? dbg_r7[2] : dbg_pc[2];
assign led[6] = display_mode ? dbg_r7[1] : dbg_pc[1];
assign led[7] = display_mode ? dbg_r7[0] : dbg_pc[0];

endmodule
