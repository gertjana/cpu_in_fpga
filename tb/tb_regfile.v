// =============================================================================
// tb_regfile.v — Testbench for the 8x8-bit Register File
//
// Simulate with:
//   iverilog -o tb_regfile tb/tb_regfile.v rtl/regfile.v && vvp tb_regfile
// =============================================================================

`timescale 1ns/1ps

module tb_regfile;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg        clk;
reg        rst;
reg        we;
reg  [2:0] rd_addr;
reg  [2:0] ra_addr;
reg  [2:0] rb_addr;
reg  [7:0] rd_data;
wire [7:0] ra_data;
wire [7:0] rb_data;

// ---------------------------------------------------------------------------
// Instantiate DUT
// ---------------------------------------------------------------------------
regfile dut (
    .clk     (clk),
    .ce      (1'b1),
    .rst     (rst),
    .we      (we),
    .rd_addr (rd_addr),
    .ra_addr (ra_addr),
    .rb_addr (rb_addr),
    .rd_data (rd_data),
    .ra_data (ra_data),
    .rb_data (rb_data)
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

task check_ra;
    input [63:0] test_id;
    input [7:0]  exp;
    begin
        if (ra_data === exp) begin
            $display("  PASS [%0d] ra_data=%02h (expected %02h)", test_id, ra_data, exp);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL [%0d] ra_data=%02h (expected %02h)", test_id, ra_data, exp);
            fail_count = fail_count + 1;
        end
    end
endtask

task check_rb;
    input [63:0] test_id;
    input [7:0]  exp;
    begin
        if (rb_data === exp) begin
            $display("  PASS [%0d] rb_data=%02h (expected %02h)", test_id, rb_data, exp);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL [%0d] rb_data=%02h (expected %02h)", test_id, rb_data, exp);
            fail_count = fail_count + 1;
        end
    end
endtask

// Perform a synchronous write then check a read on the next cycle
task write_reg;
    input [2:0] addr;
    input [7:0] data;
    begin
        @(negedge clk);   // set inputs between clock edges
        we      = 1;
        rd_addr = addr;
        rd_data = data;
        @(posedge clk);   // write captured here
        #1;               // small settle after edge
        we      = 0;
    end
endtask

// ---------------------------------------------------------------------------
// Stimulus
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("sim/vcd/tb_regfile.vcd");
    $dumpvars(0, tb_regfile);

    pass_count = 0;
    fail_count = 0;

    // Initialise inputs
    rst     = 0;
    we      = 0;
    rd_addr = 0;
    ra_addr = 0;
    rb_addr = 0;
    rd_data = 0;

    $display("=== Register File Testbench ===");

    // ------------------------------------------------------------------
    // Test 1: Reset clears all registers
    // ------------------------------------------------------------------
    $display("--- Test 1: Reset clears all registers ---");
    @(negedge clk); rst = 1;
    @(posedge clk); #1;
    rst = 0;

    begin : t1
        integer r;
        for (r = 0; r < 8; r = r + 1) begin
            @(negedge clk);
            ra_addr = r[2:0];
            #1;
            check_ra(10 + r, 8'h00);
        end
    end

    // ------------------------------------------------------------------
    // Test 2: Write a unique value to each register, read it back
    // ------------------------------------------------------------------
    $display("--- Test 2: Write & read back each register ---");
    begin : t2
        integer r;
        for (r = 0; r < 8; r = r + 1) begin
            write_reg(r[2:0], 8'hA0 | r[7:0]);
            @(negedge clk);
            we      = 0;
            ra_addr = r[2:0];
            #1;
            check_ra(20 + r, 8'hA0 | r[7:0]);
        end
    end

    // ------------------------------------------------------------------
    // Test 3: Write enable gate — we=0 must not alter register
    // ------------------------------------------------------------------
    $display("--- Test 3: Write enable gate ---");
    // R3 currently holds 0xA3; attempt to overwrite with we=0
    @(negedge clk);
    we      = 0;
    rd_addr = 3;
    rd_data = 8'hFF;
    ra_addr = 3;
    @(posedge clk); #1;
    check_ra(30, 8'hA3);   // must still be 0xA3

    // ------------------------------------------------------------------
    // Test 4: Independent dual read ports
    // ------------------------------------------------------------------
    $display("--- Test 4: Dual read ports ---");
    // R1=0xA1, R5=0xA5 were written in test 2
    @(negedge clk);
    we      = 0;
    ra_addr = 3'd1;
    rb_addr = 3'd5;
    #1;
    check_ra(40, 8'hA1);
    check_rb(41, 8'hA5);

    // ------------------------------------------------------------------
    // Test 5: No same-cycle forwarding — write is visible only AFTER clock edge
    // ------------------------------------------------------------------
    $display("--- Test 5: No same-cycle forwarding (port A) ---");
    // R2 = 0xA2 from test 2; drive a new write in same cycle and read back
    @(negedge clk);
    we      = 1;
    rd_addr = 3'd2;
    rd_data = 8'hBE;
    ra_addr = 3'd2;   // read the same register being written
    #1;
    // Without forwarding, ra_data must return the OLD stored value (0xA2)
    check_ra(50, 8'hA2);
    @(posedge clk); #1;
    we = 0;
    // After the clock edge the write has committed — now we see 0xBE
    @(negedge clk);
    ra_addr = 3'd2;
    #1;
    check_ra(51, 8'hBE);

    // ------------------------------------------------------------------
    // Test 6: No same-cycle forwarding (port B)
    // ------------------------------------------------------------------
    $display("--- Test 6: No same-cycle forwarding (port B) ---");
    @(negedge clk);
    we      = 1;
    rd_addr = 3'd4;
    rd_data = 8'hEF;
    rb_addr = 3'd4;   // read the same register being written
    #1;
    // Without forwarding, rb_data must return the OLD stored value (0xA4)
    check_rb(60, 8'hA4);
    @(posedge clk); #1;
    we = 0;
    // After the clock edge the write has committed — now we see 0xEF
    @(negedge clk);
    rb_addr = 3'd4;
    #1;
    check_rb(61, 8'hEF);

    // ------------------------------------------------------------------
    // Test 7: Stale read when we=0 — write does not propagate
    // ------------------------------------------------------------------
    $display("--- Test 7: Stale read when we=0 ---");
    // R6 = 0xA6 from test 2; attempt to forward 0xFF with we=0
    @(negedge clk);
    we      = 0;
    rd_addr = 3'd6;
    rd_data = 8'hFF;
    ra_addr = 3'd6;
    #1;
    check_ra(70, 8'hA6);   // must return stored 0xA6, not 0xFF

    // ------------------------------------------------------------------
    // Test 8: Overwrite — second write replaces first
    // ------------------------------------------------------------------
    $display("--- Test 8: Overwrite same register ---");
    write_reg(3'd7, 8'h11);
    write_reg(3'd7, 8'h22);
    @(negedge clk);
    we      = 0;
    ra_addr = 3'd7;
    #1;
    check_ra(80, 8'h22);   // only the second write should survive

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
