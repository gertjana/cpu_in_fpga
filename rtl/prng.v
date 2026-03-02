// =============================================================================
// prng.v — 8-bit Galois LFSR pseudo-random number generator
//
// Polynomial: x^8 + x^6 + x^5 + x^4 + 1   (tap mask 0xB8)
// Period:     255  (visits every non-zero 8-bit value before repeating)
//
// This module is instantiated in top.v and clocked directly by the 12 MHz
// board clock, so it runs at full board speed — independent of the slow
// divided CPU clock.  The current LFSR value is passed into the CPU as a
// plain input port (prng_data), eliminating any cross-clock-domain issues
// inside the CPU hierarchy.
//
// Ports:
//   clk   — board clock (12 MHz, rising edge)
//   rst   — synchronous active-high reset; loads seed 0x01
//   data  — current LFSR value (combinational, valid every cycle)
// =============================================================================

module prng (
    input  wire       clk,
    input  wire       rst,
    output wire [7:0] data
);

// Galois tap mask: x^8 + x^6 + x^5 + x^4 + 1
// Bit positions: 7, 5, 4, 3 (0-indexed from LSB)
localparam [7:0] TAP_MASK = 8'hB8;

// LFSR state register — seed to 0x01 (0x00 is the lock-up state)
reg [7:0] lfsr;

// Galois LFSR next-state logic:
//   1. Capture the output bit (LSB)
//   2. Shift right by one (MSB filled with 0)
//   3. XOR tap positions with the output bit
wire feedback = lfsr[0];
wire [7:0] shifted = {1'b0, lfsr[7:1]};
wire [7:0] next    = feedback ? (shifted ^ TAP_MASK) : shifted;

always @(posedge clk) begin
    if (rst) begin
        lfsr <= 8'h01;
    end else begin
        lfsr <= next;
    end
end

assign data = lfsr;

endmodule
