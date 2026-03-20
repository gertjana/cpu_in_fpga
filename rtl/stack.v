// =============================================================================
// stack.v — Hardware LIFO Stack (16 entries x 16-bit)
//
// Used to save/restore the program counter for CALL/RET and PUSH/POP.
//
// Stack entries are 16 bits wide to accommodate the 16-bit program counter
// pushed by CALL. PUSH/POP of 8-bit register values are zero-extended on push
// and the low 8 bits are read on pop (upper byte is always 0 for PUSH).
//
// Ports:
//   clk      — clock (rising edge; must be the global system clock)
//   ce       — clock enable: stack state only changes when ce=1
//   rst      — synchronous reset: SP → 0, stack contents cleared
//   push     — push data_in onto stack on rising edge
//   pop      — pop top of stack on rising edge
//   data_in  — 16-bit value to push
//   data_out — 16-bit value at top of stack (combinational, always valid)
//   full     — stack is full  (SP == DEPTH)
//   empty    — stack is empty (SP == 0)
//   overflow — push attempted when full  (held for one cycle)
//   underflow— pop  attempted when empty (held for one cycle)
//
// Priority: rst > push > pop  (simultaneous push+pop is a push)
//
// SP points to the next free slot (0 = empty).
// data_out always shows mem[SP-1] (the current top), or 0x0000 when empty.
// =============================================================================

module stack #(
    parameter DEPTH = 16
) (
    input  wire        clk,
    input  wire        ce,
    input  wire        rst,
    input  wire        push,
    input  wire        pop,
    input  wire [15:0] data_in,
    output wire [15:0] data_out,
    output wire        full,
    output wire        empty,
    output reg         overflow,
    output reg         underflow,
    output wire [4:0]  dbg_stack_depth  // current number of entries on the stack (0..DEPTH)
);

localparam PTR_W = 5;   // enough bits for depth 0..16

reg [15:0]    mem [0:DEPTH-1];
reg [PTR_W:0] sp;        // stack pointer: 0 = empty, DEPTH = full

// ---------------------------------------------------------------------------
// Status flags (combinational)
// ---------------------------------------------------------------------------
assign full  = (sp == DEPTH);
assign empty = (sp == 0);
assign dbg_stack_depth = sp[4:0];

// Top of stack — combinational peek
assign data_out = (sp == 0) ? 16'h0000 : mem[sp - 1];

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
            mem[j] <= 16'h0000;

    end else if (ce) begin
        if (push) begin
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
end

endmodule
