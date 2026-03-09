// =============================================================================
// tb_alu.v — Testbench for the 8-bit ALU
//
// Simulate with:
//   iverilog -o tb_alu tb/tb_alu.v rtl/alu.v && vvp tb_alu
//
// Or in ModelSim / Questa:
//   vlog rtl/alu.v tb/tb_alu.v
//   vsim -c tb_alu -do "run -all; quit"
// =============================================================================

`timescale 1ns/1ps

module tb_alu;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg  [2:0] op;
reg  [7:0] a, b;
reg        cin;
wire [7:0] result;
wire       z, c, n, v;

// ---------------------------------------------------------------------------
// Instantiate DUT
// ---------------------------------------------------------------------------
alu dut (
    .op     (op),
    .a      (a),
    .b      (b),
    .cin    (cin),
    .result (result),
    .z      (z),
    .c      (c),
    .n      (n),
    .v      (v)
);

// ---------------------------------------------------------------------------
// Test tracking
// ---------------------------------------------------------------------------
integer pass_count;
integer fail_count;

task check;
    input [63:0] test_id;
    input [7:0]  exp_result;
    input        exp_z, exp_c, exp_n, exp_v;
    begin
        #1; // let combinational settle
        if (result === exp_result && z === exp_z && c === exp_c &&
            n === exp_n && v === exp_v) begin
            $display("  PASS [%0d] op=%b a=%02h b=%02h => result=%02h z=%b c=%b n=%b v=%b",
                     test_id, op, a, b, result, z, c, n, v);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL [%0d] op=%b a=%02h b=%02h", test_id, op, a, b);
            $display("         expected: result=%02h z=%b c=%b n=%b v=%b",
                     exp_result, exp_z, exp_c, exp_n, exp_v);
            $display("         got:      result=%02h z=%b c=%b n=%b v=%b",
                     result, z, c, n, v);
            fail_count = fail_count + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Stimulus
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("sim/vcd/tb_alu.vcd");
    $dumpvars(0, tb_alu);

    pass_count = 0;
    fail_count = 0;

    cin = 1'b0;   // default: no carry-in (normal ADD behaviour)

    $display("=== ALU Testbench ===");

    // ------------------------------------------------------------------
    // ADD
    // ------------------------------------------------------------------
    $display("--- ADD (op=000) ---");
    op = 3'b000;

    a = 8'd10;  b = 8'd20;
    check(1, 8'd30, 0, 0, 0, 0);                  // normal add

    a = 8'd255; b = 8'd1;
    check(2, 8'd0,  1, 1, 0, 0);                  // carry out, zero result

    a = 8'd127; b = 8'd1;
    check(3, 8'd128, 0, 0, 1, 1);                  // signed overflow pos->neg

    a = 8'd128; b = 8'd128;
    check(4, 8'd0,  1, 1, 0, 1);                  // signed overflow neg->pos + carry

    a = 8'd0;   b = 8'd0;
    check(5, 8'd0,  1, 0, 0, 0);                  // zero flag

    // ------------------------------------------------------------------
    // ADC — ADD with carry-in (cin=1 routes flag_c into the adder)
    // Same op code as ADD (op=000); cin is the extra input.
    // ------------------------------------------------------------------
    $display("--- ADC (op=000, cin=1) ---");
    op = 3'b000; cin = 1'b1;

    a = 8'd10;  b = 8'd20;
    check(6, 8'd31, 0, 0, 0, 0);                  // 10+20+1 = 31, no carry

    a = 8'd254; b = 8'd1;
    check(7, 8'd0,  1, 1, 0, 0);                  // 254+1+1 = 256 → result=0, C=1, Z=1

    a = 8'd255; b = 8'd0;
    check(8, 8'd0,  1, 1, 0, 0);                  // 255+0+1 = 256 → carry, zero

    a = 8'd126; b = 8'd1;
    check(9, 8'd128, 0, 0, 1, 1);                 // 126+1+1=128 → signed overflow pos→neg

    // Verify cin=0 produces identical result to plain ADD
    cin = 1'b0;
    a = 8'd10;  b = 8'd20;
    check(9, 8'd30, 0, 0, 0, 0);                  // cin=0 → same as ADD

    cin = 1'b0;   // restore for remaining tests

    // ------------------------------------------------------------------
    // SUB
    // ------------------------------------------------------------------
    $display("--- SUB (op=001) ---");
    op = 3'b001;

    a = 8'd20;  b = 8'd10;
    check(10, 8'd10, 0, 0, 0, 0);                 // normal sub

    a = 8'd10;  b = 8'd10;
    check(11, 8'd0,  1, 0, 0, 0);                 // zero result

    a = 8'd5;   b = 8'd10;
    check(12, 8'd251, 0, 1, 1, 0);                // borrow (unsigned underflow)

    a = 8'd128; b = 8'd1;
    check(13, 8'd127, 0, 0, 0, 1);                // signed overflow neg->pos

    // ------------------------------------------------------------------
    // AND
    // ------------------------------------------------------------------
    $display("--- AND (op=010) ---");
    op = 3'b010;

    a = 8'hAA;  b = 8'hFF;
    check(20, 8'hAA, 0, 0, 1, 0);

    a = 8'hAA;  b = 8'h55;
    check(21, 8'h00, 1, 0, 0, 0);                 // zero flag

    // ------------------------------------------------------------------
    // OR
    // ------------------------------------------------------------------
    $display("--- OR (op=011) ---");
    op = 3'b011;

    a = 8'hAA;  b = 8'h55;
    check(30, 8'hFF, 0, 0, 1, 0);

    a = 8'h00;  b = 8'h00;
    check(31, 8'h00, 1, 0, 0, 0);

    // ------------------------------------------------------------------
    // XOR
    // ------------------------------------------------------------------
    $display("--- XOR (op=100) ---");
    op = 3'b100;

    a = 8'hFF;  b = 8'hFF;
    check(40, 8'h00, 1, 0, 0, 0);                 // self-XOR = 0

    a = 8'hAA;  b = 8'h55;
    check(41, 8'hFF, 0, 0, 1, 0);

    // ------------------------------------------------------------------
    // NOT
    // ------------------------------------------------------------------
    $display("--- NOT (op=101) ---");
    op = 3'b101;

    a = 8'hFF;  b = 8'hxx;
    check(50, 8'h00, 1, 0, 0, 0);

    a = 8'h00;  b = 8'hxx;
    check(51, 8'hFF, 0, 0, 1, 0);

    a = 8'hAA;  b = 8'hxx;
    check(52, 8'h55, 0, 0, 0, 0);

    // ------------------------------------------------------------------
    // SHL (logical shift left by 1)
    // ------------------------------------------------------------------
    $display("--- SHL (op=110) ---");
    op = 3'b110;

    a = 8'b0000_0001; b = 8'hxx;
    check(60, 8'b0000_0010, 0, 0, 0, 0);

    a = 8'b1000_0001; b = 8'hxx;
    check(61, 8'b0000_0010, 0, 1, 0, 0);          // MSB shifted out -> carry

    a = 8'b0100_0000; b = 8'hxx;
    check(62, 8'b1000_0000, 0, 0, 1, 0);          // result is negative

    a = 8'b0000_0000; b = 8'hxx;
    check(63, 8'b0000_0000, 1, 0, 0, 0);          // zero

    // ------------------------------------------------------------------
    // SHR (logical shift right by 1)
    // ------------------------------------------------------------------
    $display("--- SHR (op=111) ---");
    op = 3'b111;

    a = 8'b1000_0000; b = 8'hxx;
    check(70, 8'b0100_0000, 0, 0, 0, 0);

    a = 8'b0000_0001; b = 8'hxx;
    check(71, 8'b0000_0000, 1, 1, 0, 0);          // LSB shifted out -> carry, zero

    a = 8'b1111_1111; b = 8'hxx;
    check(72, 8'b0111_1111, 0, 1, 0, 0);

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    $display("");
    $display("=== Results: %0d passed, %0d failed ===", pass_count, fail_count);

    if (fail_count == 0)
        $display("ALL TESTS PASSED");
    else
        $display("SOME TESTS FAILED");

    $finish;
end

endmodule
