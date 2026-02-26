// =============================================================================
// tb_fibonacci.v — Testbench for the fibonacci.asm example program
//
// Program: examples/fibonacci.hex
//
// Computes Fibonacci numbers iteratively until the next value would overflow
// 8 bits (carry flag set).  R7 holds the last valid result.
// Each fib value is also stored in RAM starting at address 0.
//
// Expected final state:
//   R7 == 233  (fib(13) — last value fitting in 8 bits)
//   RAM[0]  ==   0  (fib(0))
//   RAM[1]  ==   1  (fib(1))
//   RAM[2]  ==   1  (fib(2))
//   RAM[3]  ==   2  (fib(3))
//   RAM[4]  ==   3  (fib(4))
//   RAM[5]  ==   5  (fib(5))
//   RAM[6]  ==   8  (fib(6))
//   RAM[7]  ==  13  (fib(7))
//   RAM[8]  ==  21  (fib(8))
//   RAM[9]  ==  34  (fib(9))
//   RAM[10] ==  55  (fib(10))
//   RAM[11] ==  89  (fib(11))
//   RAM[12] == 144  (fib(12))
//   RAM[13] == 233  (fib(13))
// =============================================================================

`timescale 1ns/1ps

module tb_fibonacci;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg  clk;
reg  rst;
wire halt_out;
wire [7:0] dbg_pc;
wire       dbg_flag_z, dbg_flag_c, dbg_flag_n, dbg_flag_v;
wire [7:0] dbg_r7;

// ---------------------------------------------------------------------------
// Clock: 10 ns period
// ---------------------------------------------------------------------------
initial clk = 0;
always #5 clk = ~clk;

// ---------------------------------------------------------------------------
// Instantiate CPU
// ---------------------------------------------------------------------------
cpu #(.ROM_INIT("examples/fibonacci.hex")) u_cpu (
    .clk        (clk),
    .rst        (rst),
    .halt_out   (halt_out),
    .dbg_pc     (dbg_pc),
    .dbg_flag_z (dbg_flag_z),
    .dbg_flag_c (dbg_flag_c),
    .dbg_flag_n (dbg_flag_n),
    .dbg_flag_v (dbg_flag_v),
    .dbg_r7     (dbg_r7)
);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
integer pass_count;
integer fail_count;

task check;
    input [63:0] got;
    input [63:0] expected;
    input [127:0] name;
    begin
        if (got === expected) begin
            $display("  PASS  %-30s got=%0d", name, got);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  %-30s got=%0d  expected=%0d", name, got, expected);
            fail_count = fail_count + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------
integer timeout_cyc;

initial begin
    $dumpfile("sim/vcd/tb_fibonacci.vcd");
    $dumpvars(0, tb_fibonacci);

    pass_count = 0;
    fail_count = 0;

    // ---- Reset ----
    rst = 1;
    repeat(3) @(posedge clk);
    @(negedge clk);
    rst = 0;

    // ---- Run until halt or timeout ----
    timeout_cyc = 0;
    while (!halt_out && timeout_cyc < 2000) begin
        @(posedge clk);
        timeout_cyc = timeout_cyc + 1;
    end

    @(posedge clk);
    @(negedge clk);

    $display("\n=== Fibonacci Test ===");

    if (halt_out) begin
        $display("  PASS  halt_out asserted after %0d cycles", timeout_cyc);
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL  timeout: halt_out never asserted");
        fail_count = fail_count + 1;
    end

    check(timeout_cyc < 2000 ? 1 : 0, 1, "no timeout");

    // ---- Register check: R7 should hold last valid fib ----
    check(u_cpu.u_rf.regs[7], 8'd233, "R7 == fib(13) == 233");

    // ---- RAM checks: full fib sequence ----
    check(u_cpu.u_ram.mem[0],  8'd0,   "RAM[0]  == fib(0)  ==   0");
    check(u_cpu.u_ram.mem[1],  8'd1,   "RAM[1]  == fib(1)  ==   1");
    check(u_cpu.u_ram.mem[2],  8'd1,   "RAM[2]  == fib(2)  ==   1");
    check(u_cpu.u_ram.mem[3],  8'd2,   "RAM[3]  == fib(3)  ==   2");
    check(u_cpu.u_ram.mem[4],  8'd3,   "RAM[4]  == fib(4)  ==   3");
    check(u_cpu.u_ram.mem[5],  8'd5,   "RAM[5]  == fib(5)  ==   5");
    check(u_cpu.u_ram.mem[6],  8'd8,   "RAM[6]  == fib(6)  ==   8");
    check(u_cpu.u_ram.mem[7],  8'd13,  "RAM[7]  == fib(7)  ==  13");
    check(u_cpu.u_ram.mem[8],  8'd21,  "RAM[8]  == fib(8)  ==  21");
    check(u_cpu.u_ram.mem[9],  8'd34,  "RAM[9]  == fib(9)  ==  34");
    check(u_cpu.u_ram.mem[10], 8'd55,  "RAM[10] == fib(10) ==  55");
    check(u_cpu.u_ram.mem[11], 8'd89,  "RAM[11] == fib(11) ==  89");
    check(u_cpu.u_ram.mem[12], 8'd144, "RAM[12] == fib(12) == 144");
    check(u_cpu.u_ram.mem[13], 8'd233, "RAM[13] == fib(13) == 233");

    // ---- PC frozen after halt ----
    begin : halt_check
        reg [7:0] pc_snap;
        pc_snap = u_cpu.u_pc.pc_out;
        repeat(5) @(posedge clk);
        check(u_cpu.u_pc.pc_out, pc_snap, "PC frozen after halt");
    end

    // ---- Summary ----
    $display("\n=== Results: %0d passed, %0d failed ===", pass_count, fail_count);
    if (fail_count == 0)
        $display("ALL TESTS PASSED");
    else
        $display("SOME TESTS FAILED");

    $finish;
end

initial begin
    #400000;
    $display("FATAL: simulation hard timeout");
    $finish;
end

endmodule
