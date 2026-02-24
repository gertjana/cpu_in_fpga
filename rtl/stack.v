// =============================================================================
// stack.v — Hardware LIFO Stack (16 entries x 8-bit)
//
// Used to save/restore the program counter for CALL/RET and PUSH/POP.
//
// Ports:
//   clk      — clock (rising edge)
//   rst      — synchronous reset: SP → 0, stack contents cleared
//   push     — push data_in onto stack on rising edge
//   pop      — pop top of stack on rising edge
//   data_in  — 8-bit value to push
//   data_out — 8-bit value at top of stack (combinational, always valid)
//   full     — stack is full  (SP == DEPTH)
//   empty    — stack is empty (SP == 0)
//   overflow — push attempted when full  (held for one cycle)
//   underflow— pop  attempted when empty (held for one cycle)
//
// Priority: rst > push > pop  (simultaneous push+pop is a push)
//
// SP points to the next free slot (0 = empty).
// data_out always shows mem[SP-1] (the current top), or 0x00 when empty.
// =============================================================================

module stack #(
    parameter DEPTH = 16
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       push,
    input  wire       pop,
    input  wire [7:0] data_in,
    output wire [7:0] data_out,
    output wire       full,
    output wire       empty,
    output reg        overflow,
    output reg        underflow
);

localparam PTR_W = 5;   // enough bits for depth 0..16

reg [7:0]     mem [0:DEPTH-1];
reg [PTR_W:0] sp;        // stack pointer: 0 = empty, DEPTH = full

// ---------------------------------------------------------------------------
// Status flags (combinational)
// ---------------------------------------------------------------------------
assign full  = (sp == DEPTH);
assign empty = (sp == 0);

// Top of stack — combinational peek
assign data_out = (sp == 0) ? 8'h00 : mem[sp - 1];

// ---------------------------------------------------------------------------
// Synchronous push / pop / reset
// ---------------------------------------------------------------------------
integer j;

always @(posedge clk) begin
    overflow  <= 1'b0;
    underflow <= 1'b0;

    if (rst) begin
        sp <= 0;
        for (j = 0; j < DEPTH; j = j + 1)
            mem[j] <= 8'h00;

    end else if (push) begin
        if (full) begin
            overflow <= 1'b1;   // error — do not push
        end else begin
            mem[sp] <= data_in;
            sp      <= sp + 1;
        end

    end else if (pop) begin
        if (empty) begin
            underflow <= 1'b1;  // error — do not pop
        end else begin
            sp <= sp - 1;
        end
    end
end

endmodule
