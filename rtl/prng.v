// =============================================================================
// prng.v — 8-bit Galois LFSR pseudo-random number generator
//
// Polynomial: x^8 + x^6 + x^5 + x^4 + 1   (tap mask 0xB8)
// Period:     255  (visits every non-zero 8-bit value before repeating)
//
// The LFSR advances one step every clock cycle when `advance` is high.
// This makes it run at the *board* clock rate (12 MHz), independent of the
// slow CPU clock — so the value the CPU reads via IN is effectively
// unpredictable from the program's perspective.
//
// Ports:
//   clk     — board clock (rising edge)
//   rst     — synchronous active-high reset (loads seed 0x01)
//   advance — shift one step this cycle (tie high to run freely)
//   data    — current LFSR value (combinational, valid every cycle)
// =============================================================================

module prng (
    input  wire       clk,
    input  wire       rst,
    input  wire       advance,
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
    end else if (advance) begin
        lfsr <= next;
    end
end

assign data = lfsr;

endmodule
