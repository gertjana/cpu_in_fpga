// =============================================================================
// tb_pc.v — Testbench for the 16-bit Program Counter
//
// Simulate with:
//   iverilog -o tb_pc tb/tb_pc.v rtl/pc.v && vvp tb_pc
// =============================================================================

`timescale 1ns/1ps

module tb_pc;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg         clk;
reg         rst;
reg         halt;
reg         load;
reg  [15:0] pc_in;
wire [15:0] pc_out;
wire [15:0] pc_next;

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
    input [15:0]  exp_pc_out;
    input [15:0]  exp_pc_next;
    begin
        #1;
        if (pc_out === exp_pc_out && pc_next === exp_pc_out + 16'd1 && pc_next === exp_pc_next) begin
            $display("  PASS [%0d] pc_out=%04h pc_next=%04h", test_id, pc_out, pc_next);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL [%0d] pc_out=%04h (exp %04h)  pc_next=%04h (exp %04h)",
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
    pc_in = 16'h0000;

    $display("=== Program Counter Testbench ===");

    // ------------------------------------------------------------------
    // Test 1: Synchronous reset → PC = 0x0000
    // ------------------------------------------------------------------
    $display("--- Test 1: Synchronous reset ---");
    // Pre-load a non-zero value so reset is meaningful
    @(negedge clk); load = 1; pc_in = 16'hABCD;
    tick; load = 0;
    // Now reset
    @(negedge clk); rst = 1;
    tick; rst = 0;
    check(1, 16'h0000, 16'h0001);

    // ------------------------------------------------------------------
    // Test 2: Normal increment (PC + 1 each cycle)
    // ------------------------------------------------------------------
    $display("--- Test 2: Normal increment ---");
    // PC is 0x0000 after reset
    tick; check(2, 16'h0001, 16'h0002);
    tick; check(3, 16'h0002, 16'h0003);
    tick; check(4, 16'h0003, 16'h0004);
    tick; check(5, 16'h0004, 16'h0005);

    // ------------------------------------------------------------------
    // Test 3: Load (jump) — PC takes pc_in value
    // ------------------------------------------------------------------
    $display("--- Test 3: Load / jump ---");
    @(negedge clk); load = 1; pc_in = 16'h0040;
    tick; load = 0;
    check(10, 16'h0040, 16'h0041);

    // Confirm it increments normally from the new address
    tick; check(11, 16'h0041, 16'h0042);
    tick; check(12, 16'h0042, 16'h0043);

    // ------------------------------------------------------------------
    // Test 4: Halt — PC freezes
    // ------------------------------------------------------------------
    $display("--- Test 4: Halt freezes PC ---");
    @(negedge clk); halt = 1;
    tick; check(20, 16'h0042, 16'h0043);  // still 0x0042
    tick; check(21, 16'h0042, 16'h0043);  // still 0x0042
    tick; check(22, 16'h0042, 16'h0043);  // still 0x0042

    // Resume
    @(negedge clk); halt = 0;
    tick; check(23, 16'h0043, 16'h0044);  // increments again

    // ------------------------------------------------------------------
    // Test 5: Load takes priority over increment
    // ------------------------------------------------------------------
    $display("--- Test 5: Load priority over increment ---");
    @(negedge clk); load = 1; pc_in = 16'hFFFF;
    tick; load = 0;
    check(30, 16'hFFFF, 16'h0000);        // pc_next wraps to 0x0000

    // ------------------------------------------------------------------
    // Test 6: Wrap-around — 0xFFFF + 1 = 0x0000
    // ------------------------------------------------------------------
    $display("--- Test 6: Wrap-around 0xFFFF → 0x0000 ---");
    // PC is 0xFFFF, increment it
    tick;
    check(40, 16'h0000, 16'h0001);

    // ------------------------------------------------------------------
    // Test 7: Reset takes priority over halt
    // ------------------------------------------------------------------
    $display("--- Test 7: Reset priority over halt ---");
    @(negedge clk); load = 1; pc_in = 16'h5555;
    tick; load = 0;
    @(negedge clk); halt = 1; rst = 1;
    tick; halt = 0; rst = 0;
    check(50, 16'h0000, 16'h0001);        // reset wins

    // ------------------------------------------------------------------
    // Test 8: Reset takes priority over load
    // ------------------------------------------------------------------
    $display("--- Test 8: Reset priority over load ---");
    @(negedge clk); load = 1; pc_in = 16'hCCCC; rst = 1;
    tick; load = 0; rst = 0;
    check(60, 16'h0000, 16'h0001);        // reset wins

    // ------------------------------------------------------------------
    // Test 9: pc_next is combinational — always PC+1 regardless of mode
    // ------------------------------------------------------------------
    $display("--- Test 9: pc_next combinational during halt ---");
    @(negedge clk); load = 1; pc_in = 16'h0010;
    tick; load = 0;
    @(negedge clk); halt = 1;
    #1;
    // During halt pc_out stays 0x0010, pc_next must still be 0x0011
    if (pc_out === 16'h0010 && pc_next === 16'h0011) begin
        $display("  PASS [70] pc_out=%04h pc_next=%04h", pc_out, pc_next);
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL [70] pc_out=%04h (exp 0010)  pc_next=%04h (exp 0011)", pc_out, pc_next);
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
