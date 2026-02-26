// =============================================================================
// top.v — MAX1000 top-level for the 8-bit CPU
//
// Display modes (toggled by USER_BTN on pin E6):
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
// Reset: power-on reset only (USER_BTN repurposed for display mode toggle).
//
// CPU clock: divided down from 12 MHz via a prescaler.
//   CPU_CLK_DIV_BITS selects how many bits of the prescaler counter are used.
//   The CPU clock is the MSB of the counter, giving:
//     bits=23 → 12_000_000 / 2^23 ≈ 1.43 Hz  (matches heartbeat, one step per blink)
//     bits=21 → ~5.7 Hz  (faster, good for watching flags/PC)
//     bits=1  → 6 MHz (effectively full speed for synthesis verification)
//   Change CPU_CLK_DIV_BITS to tune the visible speed.
//
// Heartbeat: 26-bit counter on 12 MHz; bit[23] toggles at ~1.43 Hz.
//   Frozen solid (1) once the CPU halts so it is obvious the CPU stopped.
// =============================================================================

module top (
    input  wire       clk_12m,   // 12 MHz board clock (pin H6)
    input  wire       btn_n,     // USER_BTN active-low (pin E6) — toggles display mode
    output wire [7:0] led        // active-low LEDs: LED[0]..LED[7]
);

// ---------------------------------------------------------------------------
// 2-FF synchroniser — bring the async button into the clock domain.
// Button pressed (btn_n=0) → btn_sync=1.
// ---------------------------------------------------------------------------
reg btn_meta, btn_sync;
always @(posedge clk_12m) begin
    btn_meta <= ~btn_n;
    btn_sync <= btn_meta;
end

// ---------------------------------------------------------------------------
// Edge detector — detect rising edge of btn_sync (button press).
// ---------------------------------------------------------------------------
reg btn_prev;
always @(posedge clk_12m)
    btn_prev <= btn_sync;

wire btn_pressed = btn_sync & ~btn_prev;   // one-cycle pulse on press

// ---------------------------------------------------------------------------
// Display mode toggle flip-flop.
//   0 = flags + PC  (default)
//   1 = R7 register value
// ---------------------------------------------------------------------------
reg display_mode;
always @(posedge clk_12m)
    if (btn_pressed)
        display_mode <= ~display_mode;

// ---------------------------------------------------------------------------
// Heartbeat counter — bit[23] of a 26-bit counter at 12 MHz toggles at
//   12_000_000 / 2^23 ≈ 1.43 Hz  (period ≈ 700 ms each half)
// ---------------------------------------------------------------------------
reg [25:0] hb_ctr;
always @(posedge clk_12m)
    hb_ctr <= hb_ctr + 1'b1;

wire heartbeat = hb_ctr[23];

// ---------------------------------------------------------------------------
// CPU clock prescaler — runs the CPU at a human-visible rate.
// ---------------------------------------------------------------------------
parameter CPU_CLK_DIV_BITS = 23;

reg [CPU_CLK_DIV_BITS-1:0] cpu_div_ctr;
always @(posedge clk_12m)
    cpu_div_ctr <= cpu_div_ctr + 1'b1;

// cpu_clk_en pulses for one clk_12m cycle every 2^CPU_CLK_DIV_BITS cycles.
wire cpu_clk_en = (cpu_div_ctr == {CPU_CLK_DIV_BITS{1'b1}});

// Registered clock enable to drive the CPU.
reg cpu_clk_r;
always @(posedge clk_12m)
    if (cpu_clk_en)
        cpu_clk_r <= ~cpu_clk_r;

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
    .rst        (1'b0),          // no button reset; power-on reset only
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
// ---------------------------------------------------------------------------
assign led[0] = display_mode ? ~dbg_r7[7] : dbg_flag_c;
assign led[1] = display_mode ? ~dbg_r7[6] : dbg_flag_v;
assign led[2] = display_mode ? ~dbg_r7[5] : hb_or_halt;
assign led[3] = display_mode ? ~dbg_r7[4] : dbg_pc[4];
assign led[4] = display_mode ? ~dbg_r7[3] : dbg_pc[3];
assign led[5] = display_mode ? ~dbg_r7[2] : dbg_pc[2];
assign led[6] = display_mode ? ~dbg_r7[1] : dbg_pc[1];
assign led[7] = display_mode ? ~dbg_r7[0] : dbg_pc[0];

endmodule
