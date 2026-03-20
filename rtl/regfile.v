// =============================================================================
// regfile.v — 8 x 8-bit General-Purpose Register File
//
// Ports:
//   clk      — clock (rising edge; must be the global system clock)
//   ce       — clock enable: register state only advances when ce=1
//   rst      — synchronous reset: clears all registers to 0x00
//   we       — write enable
//   rd_addr  — destination register index (write port)
//   ra_addr  — source A register index    (read port A)
//   rb_addr  — source B register index    (read port B)
//   rd_data  — data to write
//   ra_data  — read data from source A (combinational, no forwarding)
//   rb_data  — read data from source B (combinational, no forwarding)
//
// Behaviour:
//   - Writes are synchronous (rising edge, gated by we).
//   - Reads are asynchronous / combinational.
//   - No write-read forwarding: a write committed on rising edge N is
//     visible on the read ports starting from the very same edge (since
//     reads are combinational from the flip-flop outputs).  In the
//     two-cycle fetch+execute pipeline this is always sufficient — the
//     result of an instruction executed in cycle N is available for the
//     instruction that executes in cycle N+1.
//   - Forwarding is intentionally omitted to avoid a combinational loop
//     through the ALU write-back path.
// =============================================================================

module regfile (
    input  wire       clk,
    input  wire       ce,
    input  wire       rst,
    input  wire       we,
    input  wire [2:0] rd_addr,
    input  wire [2:0] ra_addr,
    input  wire [2:0] rb_addr,
    input  wire [7:0] rd_data,
    output wire [7:0] ra_data,
    output wire [7:0] rb_data,
    output wire [7:0] dbg_r0,     // direct taps of all registers for OLED monitor
    output wire [7:0] dbg_r1,
    output wire [7:0] dbg_r2,
    output wire [7:0] dbg_r3,
    output wire [7:0] dbg_r4,
    output wire [7:0] dbg_r5,
    output wire [7:0] dbg_r6,
    output wire [7:0] dbg_r7      // direct tap of R7 for LED display
);

// ---------------------------------------------------------------------------
// Storage: 8 registers of 8 bits each
// ---------------------------------------------------------------------------
reg [7:0] regs [0:7];

// ---------------------------------------------------------------------------
// Synchronous write & reset
// ---------------------------------------------------------------------------
integer i;

always @(posedge clk) begin
    if (rst) begin
        for (i = 0; i < 8; i = i + 1)
            regs[i] <= 8'b0;
    end else if (ce && we) begin
        regs[rd_addr] <= rd_data;
    end
end

// ---------------------------------------------------------------------------
// Asynchronous reads (no write-read forwarding)
//
// In the two-cycle fetch+execute pipeline the write from cycle N is committed
// to regs[] on the rising edge, so the read in cycle N+1 naturally sees the
// updated value.  Forwarding is therefore not needed and is deliberately
// omitted to avoid a combinational loop through the ALU write-back path.
// ---------------------------------------------------------------------------
assign ra_data = regs[ra_addr];
assign rb_data = regs[rb_addr];
assign dbg_r0  = regs[0];
assign dbg_r1  = regs[1];
assign dbg_r2  = regs[2];
assign dbg_r3  = regs[3];
assign dbg_r4  = regs[4];
assign dbg_r5  = regs[5];
assign dbg_r6  = regs[6];
assign dbg_r7  = regs[7];

endmodule
