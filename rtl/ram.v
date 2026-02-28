// =============================================================================
// ram.v — Data RAM (256 x 8-bit, synchronous write / asynchronous read)
//
// Separate data memory space (Harvard architecture).
//
// Ports:
//   clk      — clock (rising edge)
//   we       — write enable
//   addr     — 8-bit address
//   data_in  — 8-bit data to write
//   data_out — 8-bit read data (combinational / async)
//
// Debug port (read-only, asynchronous — for OLED controller):
//   dbg_addr — address to inspect
//   dbg_data — data at that address (combinational)
//
// Writes are synchronous (captured on rising edge when we=1).
// Reads are asynchronous so the CPU can use the result in the same cycle
// it presents the address (single-cycle load).
// =============================================================================

module ram (
    input  wire       clk,
    input  wire       we,
    input  wire [7:0] addr,
    input  wire [7:0] data_in,
    output wire [7:0] data_out,
    // Debug read port (OLED label buffer scan — does not affect CPU operation)
    input  wire [7:0] dbg_addr,
    output wire [7:0] dbg_data
);

reg [7:0] mem [0:255];

// Initialise to zero (helps simulation determinism)
integer i;
initial begin
    for (i = 0; i < 256; i = i + 1)
        mem[i] = 8'h00;
end

// Synchronous write
always @(posedge clk) begin
    if (we)
        mem[addr] <= data_in;
end

// Asynchronous read (CPU port)
assign data_out = mem[addr];

// Asynchronous debug read (OLED port — independent of CPU access)
assign dbg_data = mem[dbg_addr];

endmodule
