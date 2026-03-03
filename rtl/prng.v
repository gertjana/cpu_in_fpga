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
// Seeding:
//   On the falling edge of rst (i.e. the cycle rst goes low), the LFSR loads
//   the value present on the `seed` port instead of the fixed default.
//   In top.v `seed` is wired to the low 8 bits of the free-running
//   cpu_div_ctr, so the exact counter value at button-release time acts as
//   entropy — every power-cycle or button press starts the sequence at a
//   different point.  If seed happens to be 0x00 the module falls back to
//   0x01 to avoid the LFSR lock-up state.
//
//   The `load` / `load_data` interface allows top.v to reseed the LFSR at
//   any time (used by the OUT Ra, 1 instruction).  When load=1, load_data
//   is latched into the LFSR on the next rising clk edge (with the same
//   zero-guard as the rst-based seed).
//
// Ports:
//   clk       — board clock (12 MHz, rising edge)
//   rst       — synchronous active-high reset
//   seed      — 8-bit entropy value latched when rst falls; must be non-zero
//               (0x00 is automatically replaced with 0x01)
//   load      — 1 = load load_data into LFSR this cycle (overrides normal advance)
//   load_data — value to load when load=1
//   data      — current LFSR value (combinational, valid every cycle)
// =============================================================================

module prng (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] seed,
    input  wire       load,
    input  wire [7:0] load_data,
    output wire [7:0] data
);

// Galois tap mask: x^8 + x^6 + x^5 + x^4 + 1
localparam [7:0] TAP_MASK = 8'hB8;

// LFSR state register — initialised to 0x01 at power-on so it is never
// stuck in the lock-up state even before the first button press.
reg [7:0] lfsr = 8'h01;

// Detect the falling edge of rst (rst goes 1→0) to latch the seed.
reg rst_prev = 1'b0;
always @(posedge clk)
    rst_prev <= rst;

wire rst_falling = rst_prev & ~rst;

// Safe seed: replace 0x00 with 0x01 to avoid the lock-up state.
wire [7:0] safe_seed      = (seed      == 8'h00) ? 8'h01 : seed;
wire [7:0] safe_load_data = (load_data == 8'h00) ? 8'h01 : load_data;

// Galois LFSR next-state logic:
//   1. Capture the output bit (LSB)
//   2. Shift right by one (MSB filled with 0)
//   3. XOR tap positions with the output bit
wire feedback = lfsr[0];
wire [7:0] shifted = lfsr >> 1;
wire [7:0] next    = feedback ? (shifted ^ TAP_MASK) : shifted;

always @(posedge clk) begin
    if (rst_falling) begin
        lfsr <= safe_seed;       // latch entropy at the moment reset releases
    end else if (!rst) begin
        if (load)
            lfsr <= safe_load_data;  // CPU OUT Ra, 1 mid-program reseed
        else
            lfsr <= next;            // free-running when not in reset
    end
    // while rst is high: hold current value (seed not yet latched)
end

assign data = lfsr;

endmodule
