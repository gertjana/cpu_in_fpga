// =============================================================================
// input_barrier.v — Anti-optimisation register barrier for oled_monitor
//
// This module registers all CPU debug outputs on the rising clock edge,
// preventing Quartus from performing constant-propagation or Auto Clock
// Enable (ACE) optimisation from the CPU into the oled_monitor.
//
// Without this barrier, Quartus analyses the CPU program ROM, determines
// the exact value of every register for simple programs (e.g. adc where
// only R0 changes, R1-R7 always 0), and then:
//   1. Derives clock-enable signals from proven-constant register bits
//      (e.g. R0[7]=0 always → CE=0 → input pipeline FF never loads)
//   2. Constant-folds the entire cur_ascii / font_byte combinatorial path
//      to 0x00, producing a permanently blank display
//
// Defence-in-depth strategy:
//   (* preserve *)    — keeps each register; prevents optimisation/removal
//   (* noprune *)     — prevents removal even if outputs appear unused
//   (* dont_merge *)  — prevents merging with other equivalent registers
//   altera_attribute  — disables Auto Clock Enable recognition on all FFs
//                       in this module, so Quartus cannot infer a CE signal
//                       from proven-constant input bits
//
// NOTE: An earlier version used /* synthesis black_box */ on the module,
// but that directive tells Quartus to NOT synthesize the module body at
// all (outputs left undriven / tied to GND).  This caused the OLED to be
// completely blank for some programs.  The per-register attributes above
// are the correct approach: Quartus synthesizes the FFs normally but
// cannot optimise across them.
//
// The one-cycle pipeline latency is imperceptible at ~11 Hz CPU clock speeds.
// =============================================================================

(* altera_attribute = "-name AUTO_CLOCK_ENABLE_RECOGNITION OFF" *)
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

    (* preserve, noprune, dont_merge *) output reg  [7:0]  r0_out,
    (* preserve, noprune, dont_merge *) output reg  [7:0]  r1_out,
    (* preserve, noprune, dont_merge *) output reg  [7:0]  r2_out,
    (* preserve, noprune, dont_merge *) output reg  [7:0]  r3_out,
    (* preserve, noprune, dont_merge *) output reg  [7:0]  r4_out,
    (* preserve, noprune, dont_merge *) output reg  [7:0]  r5_out,
    (* preserve, noprune, dont_merge *) output reg  [7:0]  r6_out,
    (* preserve, noprune, dont_merge *) output reg  [7:0]  r7_out,
    (* preserve, noprune, dont_merge *) output reg  [7:0]  pc_out,
    (* preserve, noprune, dont_merge *) output reg  [4:0]  stack_depth_out,
    (* preserve, noprune, dont_merge *) output reg         flag_c_out,
    (* preserve, noprune, dont_merge *) output reg         flag_z_out,
    (* preserve, noprune, dont_merge *) output reg         flag_n_out,
    (* preserve, noprune, dont_merge *) output reg         flag_v_out,
    (* preserve, noprune, dont_merge *) output reg         halt_out
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
