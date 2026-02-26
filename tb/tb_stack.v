// =============================================================================
// tb_stack.v — Testbench for the hardware stack
//
// Simulate with:
//   iverilog -o tb_stack tb/tb_stack.v rtl/stack.v && vvp tb_stack
// =============================================================================

`timescale 1ns/1ps

module tb_stack;

reg        clk, rst, push, pop;
reg  [7:0] data_in;
wire [7:0] data_out;
wire       full, empty;
wire       overflow, underflow;

stack #(.DEPTH(16)) dut (
    .clk       (clk),
    .rst       (rst),
    .push      (push),
    .pop       (pop),
    .data_in   (data_in),
    .data_out  (data_out),
    .full      (full),
    .empty     (empty),
    .overflow  (overflow),
    .underflow (underflow)
);

initial clk = 0;
always #5 clk = ~clk;

integer pass_count;
integer fail_count;

task chk8;
    input [63:0]  id;
    input [127:0] name;
    input [7:0]   got;
    input [7:0]   exp;
    begin
        if (got === exp) begin
            $display("  PASS [%0d] %s = %02h", id, name, got);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL [%0d] %s = %02h (expected %02h)", id, name, got, exp);
            fail_count = fail_count + 1;
        end
    end
endtask

task chk1;
    input [63:0]  id;
    input [127:0] name;
    input         got;
    input         exp;
    begin
        if (got === exp) begin
            $display("  PASS [%0d] %s = %b", id, name, got);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL [%0d] %s = %b (expected %b)", id, name, got, exp);
            fail_count = fail_count + 1;
        end
    end
endtask

// Push one value and clock
task do_push;
    input [7:0] val;
    begin
        @(negedge clk);
        push    = 1; pop = 0;
        data_in = val;
        @(posedge clk); #1;
        push = 0;
    end
endtask

// Pop one value and clock
task do_pop;
    begin
        @(negedge clk);
        pop = 1; push = 0;
        @(posedge clk); #1;
        pop = 0;
    end
endtask

// Do a synchronous reset
task do_rst;
    begin
        @(negedge clk); rst = 1;
        @(posedge clk); #1;
        rst = 0;
    end
endtask

initial begin
    $dumpfile("sim/vcd/tb_stack.vcd");
    $dumpvars(0, tb_stack);

    pass_count = 0;
    fail_count = 0;
    rst = 0; push = 0; pop = 0; data_in = 0;

    $display("=== Stack Testbench ===");

    // ------------------------------------------------------------------
    // Test 1: Reset — stack empty, data_out = 0
    // ------------------------------------------------------------------
    $display("--- Test 1: Reset ---");
    do_rst;
    chk1(1, "empty     ", empty,    1'b1);
    chk1(2, "full      ", full,     1'b0);
    chk8(3, "data_out  ", data_out, 8'h00);

    // ------------------------------------------------------------------
    // Test 2: Push one value — empty clears, data_out shows top
    // ------------------------------------------------------------------
    $display("--- Test 2: Push one value ---");
    do_push(8'hAA);
    chk1(10, "empty     ", empty,    1'b0);
    chk1(11, "full      ", full,     1'b0);
    chk8(12, "data_out  ", data_out, 8'hAA);

    // ------------------------------------------------------------------
    // Test 3: Push multiple values — LIFO order
    // ------------------------------------------------------------------
    $display("--- Test 3: LIFO order ---");
    do_push(8'hBB);
    chk8(20, "top after BB", data_out, 8'hBB);
    do_push(8'hCC);
    chk8(21, "top after CC", data_out, 8'hCC);
    do_push(8'hDD);
    chk8(22, "top after DD", data_out, 8'hDD);

    // ------------------------------------------------------------------
    // Test 4: Pop — data comes back in LIFO order
    // ------------------------------------------------------------------
    $display("--- Test 4: Pop LIFO ---");
    // Before popping, peek should show DD
    chk8(30, "peek DD   ", data_out, 8'hDD);
    do_pop; chk8(31, "after pop1", data_out, 8'hCC);
    do_pop; chk8(32, "after pop2", data_out, 8'hBB);
    do_pop; chk8(33, "after pop3", data_out, 8'hAA);
    // One more pop empties it
    do_pop;
    chk1(34, "empty now ", empty,    1'b1);
    chk8(35, "data_out 0", data_out, 8'h00);

    // ------------------------------------------------------------------
    // Test 5: Underflow protection
    // ------------------------------------------------------------------
    $display("--- Test 5: Underflow ---");
    // Stack is already empty
    chk1(40, "empty     ", empty, 1'b1);
    do_pop;
    chk1(41, "underflow ", underflow, 1'b1);
    // Stack pointer must not have gone negative; empty still asserted
    chk1(42, "still empty", empty, 1'b1);
    // underflow clears next cycle
    @(negedge clk); @(posedge clk); #1;
    chk1(43, "underflow clears", underflow, 1'b0);

    // ------------------------------------------------------------------
    // Test 6: Fill to capacity, check full flag
    // ------------------------------------------------------------------
    $display("--- Test 6: Fill to full ---");
    do_rst;
    begin : fill
        integer k;
        for (k = 0; k < 16; k = k + 1)
            do_push(k[7:0]);
    end
    chk1(50, "full      ", full,  1'b1);
    chk1(51, "not empty ", empty, 1'b0);
    chk8(52, "top = 15  ", data_out, 8'hF); // last pushed = 15

    // ------------------------------------------------------------------
    // Test 7: Overflow protection
    // ------------------------------------------------------------------
    $display("--- Test 7: Overflow ---");
    do_push(8'hFF);  // stack is full — should not push
    chk1(60, "overflow  ", overflow, 1'b1);
    chk8(61, "top still 15", data_out, 8'hF); // unchanged
    chk1(62, "still full", full, 1'b1);
    @(negedge clk); @(posedge clk); #1;
    chk1(63, "overflow clears", overflow, 1'b0);

    // ------------------------------------------------------------------
    // Test 8: Pop all — check LIFO order and empty at end
    // ------------------------------------------------------------------
    $display("--- Test 8: Drain LIFO order ---");
    begin : drain
        integer k;
        for (k = 15; k >= 0; k = k - 1) begin
            chk8(70 + (15 - k), "top", data_out, k[7:0]);
            do_pop;
        end
    end
    chk1(87, "empty after drain", empty, 1'b1);

    // ------------------------------------------------------------------
    // Test 9: Reset mid-use clears stack
    // ------------------------------------------------------------------
    $display("--- Test 9: Reset mid-use ---");
    do_push(8'h11);
    do_push(8'h22);
    do_push(8'h33);
    chk8(90, "top=33 before rst", data_out, 8'h33);
    do_rst;
    chk1(91, "empty after rst", empty,    1'b1);
    chk8(92, "data_out=0      ", data_out, 8'h00);

    // ------------------------------------------------------------------
    // Test 10: CALL/RET simulation — push PC+1, jump, pop PC
    // ------------------------------------------------------------------
    $display("--- Test 10: CALL/RET simulation ---");
    do_rst;
    do_push(8'h05);   // CALL saves PC+1 = 0x05
    chk8(100, "saved ret addr", data_out, 8'h05);
    do_push(8'h12);   // nested CALL saves 0x12
    chk8(101, "nested ret addr", data_out, 8'h12);
    do_pop;           // RET — should get 0x12
    chk8(102, "RET inner", data_out, 8'h05);
    do_pop;           // RET outer
    chk1(103, "empty after ret", empty, 1'b1);

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
