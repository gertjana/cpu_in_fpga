// =============================================================================
// top.v — MAX1000 top-level for the 8-bit CPU
//
// LED mapping (active-low, all 8 LEDs):
//   LED[0]  — flag Z  (zero)
//   LED[1]  — flag C  (carry)
//   LED[2]  — flag N  (negative)
//   LED[3]  — flag V  (overflow)
//   LED[4]  — heartbeat blink (~1.4 Hz while running); solid ON when halted
//   LED[5]  — PC[0]
//   LED[6]  — PC[1]
//   LED[7]  — PC[2]
//
// Clock: 12 MHz oscillator on pin H6.
// Reset: KEY0 button, active-low (pin C7).
//
// CPU clock: divided down from 12 MHz via a prescaler.
//   CPU_CLK_DIV_BITS selects how many bits of the prescaler counter are used.
//   The CPU clock is the MSB of the counter, giving:
//     bits=21 → 12_000_000 / 2^21 ≈ 5.7 Hz  (good for watching flags/PC)
//     bits=1  → 6 MHz (effectively full speed for synthesis verification)
//   Change CPU_CLK_DIV_BITS to tune the visible speed.
//
// Heartbeat: 26-bit counter on 12 MHz; bit[23] toggles at ~1.43 Hz.
//   Frozen solid (1) once the CPU halts so it is obvious the CPU stopped.
// =============================================================================

module top (
    input  wire       clk_12m,   // 12 MHz board clock (pin H6)
    input  wire       rst_n,     // KEY0 active-low reset  (pin C7)
    output wire [7:0] led_n      // active-low LEDs: LED[0]..LED[7]
);

// ---------------------------------------------------------------------------
// 2-FF synchroniser — bring the async reset button into the clock domain.
// Button pressed (rst_n=0) → rst=1 (active-high internal reset).
// ---------------------------------------------------------------------------
reg rst_meta, rst_sync;
always @(posedge clk_12m) begin
    rst_meta <= ~rst_n;
    rst_sync <= rst_meta;
end

wire rst = rst_sync;

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
//   cpu_clk toggles at 12 MHz / 2^CPU_CLK_DIV_BITS ≈ 1.43 Hz (bits=23).
//   Increase CPU_CLK_DIV_BITS to slow down further; set to 1 for near
//   full-speed (6 MHz). This is a simple clock-enable gated on posedge
//   clk_12m so it is safe for synchronous logic.
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

// Registered clock enable to drive the CPU — this avoids glitchy derived
// clocks and keeps everything in the clk_12m domain.
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

cpu #(.ROM_INIT("program.hex")) u_cpu (
    .clk        (cpu_clk),
    .rst        (rst),
    .halt_out   (halt_out),
    .dbg_pc     (dbg_pc),
    .dbg_flag_z (dbg_flag_z),
    .dbg_flag_c (dbg_flag_c),
    .dbg_flag_n (dbg_flag_n),
    .dbg_flag_v (dbg_flag_v)
);

// ---------------------------------------------------------------------------
// LED[4]: heartbeat while running; solid ON once halted.
// All outputs inverted for active-low LEDs.
// ---------------------------------------------------------------------------
wire hb_or_halt = halt_out ? 1'b1 : heartbeat;

assign led_n[0] = ~dbg_flag_z;
assign led_n[1] = ~dbg_flag_c;
assign led_n[2] = ~dbg_flag_n;
assign led_n[3] = ~dbg_flag_v;
assign led_n[4] = ~hb_or_halt;
assign led_n[5] = ~dbg_pc[0];
assign led_n[6] = ~dbg_pc[1];
assign led_n[7] = ~dbg_pc[2];

endmodule
