// =============================================================================
// alu.v — 8-bit Arithmetic Logic Unit
//
// Inputs:
//   op    [2:0]  — operation select (see ALU_OP_* parameters)
//   a     [7:0]  — operand A
//   b     [7:0]  — operand B
//   cin           — carry input; when 1 the ADD operation becomes ADC
//                   (a + b + 1).  Driven by flag_c via the decoder alu_cin
//                   signal; always 0 for all non-ADD instructions.
//
// Outputs:
//   result [7:0] — computation result
//   z             — zero flag  (result == 0)
//   c             — carry flag (unsigned overflow/borrow)
//   n             — negative flag (result[7])
//   v             — overflow flag (signed overflow)
// =============================================================================

module alu (
    input  wire [2:0] op,
    input  wire [7:0] a,
    input  wire [7:0] b,
    input  wire       cin,
    output reg  [7:0] result,
    output wire       z,
    output reg        c,
    output wire       n,
    output reg        v
);

// ---------------------------------------------------------------------------
// ALU operation codes — must match instruction decoder
// ---------------------------------------------------------------------------
localparam ALU_ADD = 3'b000;
localparam ALU_SUB = 3'b001;
localparam ALU_AND = 3'b010;
localparam ALU_OR  = 3'b011;
localparam ALU_XOR = 3'b100;
localparam ALU_NOT = 3'b101;
localparam ALU_SHL = 3'b110;
localparam ALU_SHR = 3'b111;

// ---------------------------------------------------------------------------
// 9-bit intermediate to capture carry/borrow
// ---------------------------------------------------------------------------
reg [8:0] wide;

always @(*) begin
    // Default to no carry, no overflow
    wide   = 9'b0;
    result = 8'b0;
    c      = 1'b0;
    v      = 1'b0;

    case (op)
        ALU_ADD: begin
            wide   = {1'b0, a} + {1'b0, b} + {8'b0, cin};
            result = wide[7:0];
            c      = wide[8];
            // Signed overflow: both operands same sign, result different sign
            v      = (~a[7] & ~b[7] &  result[7])
                   | ( a[7] &  b[7] & ~result[7]);
        end

        ALU_SUB: begin
            wide   = {1'b0, a} - {1'b0, b};
            result = wide[7:0];
            // Carry (borrow): set when a < b (unsigned)
            c      = wide[8];
            // Signed overflow: operands have different signs, result sign differs from a
            v      = ( a[7] & ~b[7] & ~result[7])
                   | (~a[7] &  b[7] &  result[7]);
        end

        ALU_AND: begin
            result = a & b;
            c      = 1'b0;
            v      = 1'b0;
        end

        ALU_OR: begin
            result = a | b;
            c      = 1'b0;
            v      = 1'b0;
        end

        ALU_XOR: begin
            result = a ^ b;
            c      = 1'b0;
            v      = 1'b0;
        end

        ALU_NOT: begin
            result = ~a;
            c      = 1'b0;
            v      = 1'b0;
        end

        ALU_SHL: begin
            result = a << 1;
            c      = a[7];   // shifted-out MSB becomes carry
            v      = 1'b0;
        end

        ALU_SHR: begin
            result = a >> 1;
            c      = a[0];   // shifted-out LSB becomes carry
            v      = 1'b0;
        end

        default: begin
            result = 8'b0;
            c      = 1'b0;
            v      = 1'b0;
        end
    endcase
end

// ---------------------------------------------------------------------------
// Combinational flags derived from result
// ---------------------------------------------------------------------------
assign z = (result == 8'b0);
assign n = result[7];

endmodule
