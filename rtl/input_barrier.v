// =============================================================================
// input_barrier.v — Synthesis black-box register barrier for oled_monitor
//
// This module is declared as a synthesis black box so that Quartus cannot
// perform constant-propagation or Auto Clock Enable (ACE) optimisation
// through it.  It simply registers its inputs on the rising clock edge.
//
// Without this barrier, Quartus analyses the CPU program ROM, determines
// the exact value of every register for simple programs (e.g. infinite_counter
// where R0 counts 0-63, R1=63, R2-R7 always 0), and then:
//   1. Derives clock-enable signals from proven-constant register bits
//      (e.g. R0[7]=0 always → CE=0 → input pipeline FF never loads)
//   2. Constant-folds the entire cur_ascii / font_byte combinatorial path
//      to 0x00, producing a permanently blank display
//
// By marking this module black_box, Quartus treats all outputs as unknown
// at synthesis time, which defeats both optimisations.
//
// The one-cycle pipeline latency is imperceptible at ~11 Hz CPU clock speeds.
// =============================================================================

/* synthesis black_box */
module input_barrier (
    input  wire        clk,

    input  wire [7:0]  r0_in,
    input  wire [7:0]  r1_in,
    input  wire [7:0]  r2_in,
    input  wire [7:0]  r3_in,
    input  wire [7:0]  r4_in,
    input  wire [7:0]  r5_in,
    input  wire [7:0]  r6_in,
    input  wire [7:0]  r7_in,
    input  wire [7:0]  pc_in,
    input  wire [4:0]  stack_depth_in,
    input  wire        flag_c_in,
    input  wire        flag_z_in,
    input  wire        flag_n_in,
    input  wire        flag_v_in,
    input  wire        halt_in,

    output reg  [7:0]  r0_out,
    output reg  [7:0]  r1_out,
    output reg  [7:0]  r2_out,
    output reg  [7:0]  r3_out,
    output reg  [7:0]  r4_out,
    output reg  [7:0]  r5_out,
    output reg  [7:0]  r6_out,
    output reg  [7:0]  r7_out,
    output reg  [7:0]  pc_out,
    output reg  [4:0]  stack_depth_out,
    output reg         flag_c_out,
    output reg         flag_z_out,
    output reg         flag_n_out,
    output reg         flag_v_out,
    output reg         halt_out
);

always @(posedge clk) begin
    r0_out          <= r0_in;
    r1_out          <= r1_in;
    r2_out          <= r2_in;
    r3_out          <= r3_in;
    r4_out          <= r4_in;
    r5_out          <= r5_in;
    r6_out          <= r6_in;
    r7_out          <= r7_in;
    pc_out          <= pc_in;
    stack_depth_out <= stack_depth_in;
    flag_c_out      <= flag_c_in;
    flag_z_out      <= flag_z_in;
    flag_n_out      <= flag_n_in;
    flag_v_out      <= flag_v_in;
    halt_out        <= halt_in;
end

endmodule
