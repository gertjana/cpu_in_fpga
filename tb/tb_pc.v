// =============================================================================
// tb_pc.v — Testbench for the 8-bit Program Counter
//
// Simulate with:
//   iverilog -o tb_pc tb/tb_pc.v rtl/pc.v && vvp tb_pc
// =============================================================================

`timescale 1ns/1ps

module tb_pc;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg        clk;
reg        rst;
reg        halt;
reg        load;
reg  [7:0] pc_in;
wire [7:0] pc_out;
wire [7:0] pc_next;

// ---------------------------------------------------------------------------
// Instantiate DUT
// ---------------------------------------------------------------------------
pc dut (
    .clk    (clk),
    .rst    (rst),
    .halt   (halt),
    .load   (load),
    .pc_in  (pc_in),
    .pc_out (pc_out),
    .pc_next(pc_next)
);

// ---------------------------------------------------------------------------
// Clock: 10 ns period
// ---------------------------------------------------------------------------
initial clk = 0;
always #5 clk = ~clk;

// ---------------------------------------------------------------------------
// Test tracking
// ---------------------------------------------------------------------------
integer pass_count;
integer fail_count;

task check;
    input [63:0] test_id;
    input [7:0]  exp_pc_out;
    input [7:0]  exp_pc_next;
    begin
        #1;
        if (pc_out === exp_pc_out && pc_next === exp_pc_out + 8'd1 && pc_next === exp_pc_next) begin
            $display("  PASS [%0d] pc_out=%02h pc_next=%02h", test_id, pc_out, pc_next);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL [%0d] pc_out=%02h (exp %02h)  pc_next=%02h (exp %02h)",
                     test_id, pc_out, exp_pc_out, pc_next, exp_pc_next);
            fail_count = fail_count + 1;
        end
    end
endtask

// Helper: apply inputs between edges, then clock
task tick;
    begin
        @(posedge clk); #1;
    end
endtask

// ---------------------------------------------------------------------------
// Stimulus
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("sim/vcd/tb_pc.vcd");
    $dumpvars(0, tb_pc);

    pass_count = 0;
    fail_count = 0;

    rst   = 0;
    halt  = 0;
    load  = 0;
    pc_in = 8'h00;

    $display("=== Program Counter Testbench ===");

    // ------------------------------------------------------------------
    // Test 1: Synchronous reset → PC = 0x00
    // ------------------------------------------------------------------
    $display("--- Test 1: Synchronous reset ---");
    // Pre-load a non-zero value so reset is meaningful
    @(negedge clk); load = 1; pc_in = 8'hAB;
    tick; load = 0;
    // Now reset
    @(negedge clk); rst = 1;
    tick; rst = 0;
    check(1, 8'h00, 8'h01);

    // ------------------------------------------------------------------
    // Test 2: Normal increment (PC + 1 each cycle)
    // ------------------------------------------------------------------
    $display("--- Test 2: Normal increment ---");
    // PC is 0x00 after reset
    tick; check(2, 8'h01, 8'h02);
    tick; check(3, 8'h02, 8'h03);
    tick; check(4, 8'h03, 8'h04);
    tick; check(5, 8'h04, 8'h05);

    // ------------------------------------------------------------------
    // Test 3: Load (jump) — PC takes pc_in value
    // ------------------------------------------------------------------
    $display("--- Test 3: Load / jump ---");
    @(negedge clk); load = 1; pc_in = 8'h40;
    tick; load = 0;
    check(10, 8'h40, 8'h41);

    // Confirm it increments normally from the new address
    tick; check(11, 8'h41, 8'h42);
    tick; check(12, 8'h42, 8'h43);

    // ------------------------------------------------------------------
    // Test 4: Halt — PC freezes
    // ------------------------------------------------------------------
    $display("--- Test 4: Halt freezes PC ---");
    @(negedge clk); halt = 1;
    tick; check(20, 8'h42, 8'h43);  // still 0x42
    tick; check(21, 8'h42, 8'h43);  // still 0x42
    tick; check(22, 8'h42, 8'h43);  // still 0x42

    // Resume
    @(negedge clk); halt = 0;
    tick; check(23, 8'h43, 8'h44);  // increments again

    // ------------------------------------------------------------------
    // Test 5: Load takes priority over increment
    // ------------------------------------------------------------------
    $display("--- Test 5: Load priority over increment ---");
    @(negedge clk); load = 1; pc_in = 8'hFF;
    tick; load = 0;
    check(30, 8'hFF, 8'h00);        // pc_next wraps to 0x00

    // ------------------------------------------------------------------
    // Test 6: Wrap-around — 0xFF + 1 = 0x00
    // ------------------------------------------------------------------
    $display("--- Test 6: Wrap-around 0xFF → 0x00 ---");
    // PC is 0xFF, increment it
    tick;
    check(40, 8'h00, 8'h01);

    // ------------------------------------------------------------------
    // Test 7: Reset takes priority over halt
    // ------------------------------------------------------------------
    $display("--- Test 7: Reset priority over halt ---");
    @(negedge clk); load = 1; pc_in = 8'h55;
    tick; load = 0;
    @(negedge clk); halt = 1; rst = 1;
    tick; halt = 0; rst = 0;
    check(50, 8'h00, 8'h01);        // reset wins

    // ------------------------------------------------------------------
    // Test 8: Reset takes priority over load
    // ------------------------------------------------------------------
    $display("--- Test 8: Reset priority over load ---");
    @(negedge clk); load = 1; pc_in = 8'hCC; rst = 1;
    tick; load = 0; rst = 0;
    check(60, 8'h00, 8'h01);        // reset wins

    // ------------------------------------------------------------------
    // Test 9: pc_next is combinational — always PC+1 regardless of mode
    // ------------------------------------------------------------------
    $display("--- Test 9: pc_next combinational during halt ---");
    @(negedge clk); load = 1; pc_in = 8'h10;
    tick; load = 0;
    @(negedge clk); halt = 1;
    #1;
    // During halt pc_out stays 0x10, pc_next must still be 0x11
    if (pc_out === 8'h10 && pc_next === 8'h11) begin
        $display("  PASS [70] pc_out=%02h pc_next=%02h", pc_out, pc_next);
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL [70] pc_out=%02h (exp 10)  pc_next=%02h (exp 11)", pc_out, pc_next);
        fail_count = fail_count + 1;
    end
    @(negedge clk); halt = 0;

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
