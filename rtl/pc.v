// =============================================================================
// pc.v — 16-bit Program Counter
//
// Ports:
//   clk       — clock (rising edge; must be the global system clock)
//   ce        — clock enable: PC only advances when ce=1
//   rst       — synchronous reset: PC → 0x0000
//   halt      — freeze PC (stop incrementing / loading)
//   load      — load pc_in as the new PC value (for jumps/branches/call/ret)
//   pc_in     — target address to load when load=1
//   pc_out    — current PC value (address of instruction to fetch)
//   pc_next   — PC + 1 (combinational, useful for CALL to save return address)
//
// Priority (highest to lowest):
//   1. rst  — synchronous reset to 0
//   2. halt — hold current value, do nothing
//   3. load — jump to pc_in
//   4. default — increment by 1
// =============================================================================

module pc (
    input  wire        clk,
    input  wire        ce,
    input  wire        rst,
    input  wire        halt,
    input  wire        load,
    input  wire [15:0] pc_in,
    output reg  [15:0] pc_out,
    output wire [15:0] pc_next
);

// pc_next is always PC+1, regardless of what happens on the next edge.
// The instruction decoder uses this as the CALL return address.
assign pc_next = pc_out + 16'd1;

always @(posedge clk) begin
    if (rst)
        pc_out <= 16'h0000;
    else if (ce) begin
        if (halt)
            pc_out <= pc_out;   // hold — explicit for clarity
        else if (load)
            pc_out <= pc_in;
        else
            pc_out <= pc_next;
    end
end

endmodule
