// =============================================================================
// top.v — MAX1000 top-level for the 8-bit CPU
//
// USER_BTN (pin E6, active-low):
//   Short press (<0.5 s) → toggles LED display mode, CPU keeps running
//   Long  press (≥0.5 s) → resets the CPU; display mode is preserved
//
// Display modes:
//
//   Mode 0 — flags + PC (default):
//     LED[0]  — flag C  (carry)
//     LED[1]  — flag V  (overflow)
//     LED[2]  — heartbeat blink (~1.4 Hz while running); solid ON when halted
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
//     bits=23 → 12_000_000 / 2^23 ≈ 1.43 Hz
//     bits=21 → ~5.7 Hz
//     bits=1  → 6 MHz (near full speed)
//
// Heartbeat: 26-bit counter on 12 MHz; bit[23] toggles at ~1.43 Hz.
//   Frozen solid (1) once the CPU halts.
// =============================================================================

module top (
    input  wire       clk_12m,   // 12 MHz board clock (pin H6)
    input  wire       rst_n,     // USER_BTN active-low (pin E6)
    output wire [7:0] led        // active-low LEDs: LED[0]..LED[7]
);

// ---------------------------------------------------------------------------
// 2-FF synchroniser — bring the async button into the clock domain.
// Button pressed (rst_n=0) → btn=1.
// ---------------------------------------------------------------------------
reg btn_meta, btn;
always @(posedge clk_12m) begin
    btn_meta <= ~rst_n;
    btn      <= btn_meta;
end

// ---------------------------------------------------------------------------
// Hold-duration counter — counts 12 MHz cycles while button is held.
// Saturates at LONG_PRESS_CYCLES so it never wraps.
// LONG_PRESS_CYCLES = 2^23 - 1 ≈ 0.7 s  (well above the 0.5 s threshold)
// ---------------------------------------------------------------------------
parameter LONG_PRESS_BITS   = 23;
parameter LONG_PRESS_CYCLES = (1 << LONG_PRESS_BITS) - 1;  // ~0.7 s

reg [LONG_PRESS_BITS-1:0] hold_ctr;
always @(posedge clk_12m) begin
    if (!btn)
        hold_ctr <= {LONG_PRESS_BITS{1'b0}};           // reset counter when released
    else if (hold_ctr != LONG_PRESS_CYCLES)
        hold_ctr <= hold_ctr + 1'b1;                   // count up, saturate
end

// long_press goes high as soon as the threshold is reached (while still held)
wire long_press = (hold_ctr == LONG_PRESS_CYCLES);

// ---------------------------------------------------------------------------
// CPU reset — driven by long press.
// Held high for as long as the button stays held past the threshold.
// ---------------------------------------------------------------------------
wire rst = long_press;

// ---------------------------------------------------------------------------
// Release edge detector — fires one cycle after button is released.
// ---------------------------------------------------------------------------
reg btn_prev;
always @(posedge clk_12m)
    btn_prev <= btn;

wire btn_released = btn_prev & ~btn;   // one-cycle pulse on release

// ---------------------------------------------------------------------------
// Display mode toggle — on short press only (released before threshold).
//   0 = flags + PC  (default)
//   1 = R7 register value
// Display mode is preserved across CPU resets.
// ---------------------------------------------------------------------------
reg display_mode;
always @(posedge clk_12m)
    if (btn_released && !long_press)
        display_mode <= ~display_mode;

// ---------------------------------------------------------------------------
// Heartbeat counter — bit[23] of a 26-bit counter at 12 MHz toggles at
//   12_000_000 / 2^23 ≈ 1.43 Hz  (period ≈ 700 ms each half)
// ---------------------------------------------------------------------------
reg [25:0] hb_ctr;
always @(posedge clk_12m) begin
    if (rst)
        hb_ctr <= 26'b0;
    else
        hb_ctr <= hb_ctr + 1'b1;
end

wire heartbeat = hb_ctr[23];

// ---------------------------------------------------------------------------
// CPU clock prescaler — runs the CPU at a human-visible rate.
// ---------------------------------------------------------------------------
parameter CPU_CLK_DIV_BITS = 23;

reg [CPU_CLK_DIV_BITS-1:0] cpu_div_ctr;
always @(posedge clk_12m) begin
    if (rst)
        cpu_div_ctr <= {CPU_CLK_DIV_BITS{1'b0}};
    else
        cpu_div_ctr <= cpu_div_ctr + 1'b1;
end

// cpu_clk_en pulses for one clk_12m cycle every 2^CPU_CLK_DIV_BITS cycles.
wire cpu_clk_en = (cpu_div_ctr == {CPU_CLK_DIV_BITS{1'b1}});

// Registered clock enable to drive the CPU.
reg cpu_clk_r;
always @(posedge clk_12m) begin
    if (rst)
        cpu_clk_r <= 1'b0;
    else if (cpu_clk_en)
        cpu_clk_r <= ~cpu_clk_r;
end

wire cpu_clk = cpu_clk_r;

// ---------------------------------------------------------------------------
// CPU instantiation
// ---------------------------------------------------------------------------
wire       halt_out;
wire [7:0] dbg_pc;
wire       dbg_flag_z, dbg_flag_c, dbg_flag_n, dbg_flag_v;
wire [7:0] dbg_r7;

cpu #(.ROM_INIT("program.hex")) u_cpu (
    .clk        (cpu_clk),
    .rst        (rst),
    .halt_out   (halt_out),
    .dbg_pc     (dbg_pc),
    .dbg_flag_z (dbg_flag_z),
    .dbg_flag_c (dbg_flag_c),
    .dbg_flag_n (dbg_flag_n),
    .dbg_flag_v (dbg_flag_v),
    .dbg_r7     (dbg_r7)
);

// ---------------------------------------------------------------------------
// Heartbeat / halt indicator (mode 0 only).
// ---------------------------------------------------------------------------
wire hb_or_halt = halt_out ? 1'b1 : heartbeat;

// ---------------------------------------------------------------------------
// LED mux — mode 0: flags + PC   mode 1: R7
// Active-low: 0 = LED on, 1 = LED off.
// Flag/PC bits and R7 bits are all used directly (0 = not set / low bit).
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
