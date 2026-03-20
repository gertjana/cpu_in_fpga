// =============================================================================
// rom.v — Program ROM (parameterizable depth × 24-bit, synchronous read)
//
// Holds the instruction stream. In simulation the contents are loaded via
// $readmemh from a hex file. On MAX 10 Quartus infers this as on-chip M9K
// block RAM initialised from a .mif / .hex file.
//
// Parameters:
//   DEPTH     — number of 24-bit words in the ROM (default: 256). The address
//               port width is always 16-bit (matching the architectural PC) but
//               only DEPTH locations are actually instantiated, keeping block-RAM
//               usage proportional to actual program size. The caller must
//               ensure addr < DEPTH at all times (no out-of-bounds protection
//               inside this module; wrap the PC or use a guard in the CPU top).
//   INIT_FILE — hex file loaded at elaboration / programming time.
//
// Ports:
//   clk      — clock (rising edge)
//   addr     — 16-bit word address; must be in range [0, DEPTH-1]
//   data_out — 24-bit instruction word at addr
//
// Read is synchronous (registered output) to match block RAM timing on MAX 10.
// The CPU must present the fetch address one cycle before it needs the result.
// =============================================================================

module rom #(
    parameter DEPTH     = 256,              // number of ROM words (power-of-2 recommended)
    parameter INIT_FILE = "program.hex"     // override in simulation
) (
    input  wire        clk,
    input  wire        ce,       // clock enable: ROM output only advances when ce=1
    input  wire [15:0] addr,
    output reg  [23:0] data_out
);

reg [23:0] mem [0:DEPTH-1];

// Load initial contents from hex file at elaboration time
initial begin
    $readmemh(INIT_FILE, mem);
end

always @(posedge clk) begin
    if (ce)
        data_out <= mem[addr];
end

endmodule
