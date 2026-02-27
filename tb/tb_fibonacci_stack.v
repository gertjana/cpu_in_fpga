// =============================================================================
// tb_fibonacci_stack.v — Testbench for the fibonacci_stack.asm example program
//
// Program: examples/fibonacci_stack.hex
//
// Phase 1 — the program computes fib(0)..fib(13) iteratively and PUSHes each
// value onto the hardware stack.  R7 tracks the latest valid result.
//
// Phase 2 — the program POPs all 14 values back into R7 in LIFO order, then
// halts.  The final R7 = 0 (= fib(0), the last value popped).
//
// What is verified:
//   1. halt_out asserted within timeout
//   2. No timeout
//   3. Stack is empty after all POPs (dbg_stack_empty == 1)
//   4. R7 == 0 at halt (fib(0) was at the bottom of the stack)
//   5. Stack internal contents at end of phase 1 — verified via hierarchical
//      access to u_cpu.u_stack.mem[] and .sp before the pop phase starts.
//      We detect "end of push phase" by watching dbg_stack_top == 233 and
//      halt_out is not yet set.
//   6. PC frozen after halt
//
// Expected stack (bottom→top) after phase 1:
//   mem[0]  =   0  fib(0)
//   mem[1]  =   1  fib(1)
//   mem[2]  =   1  fib(2)
//   mem[3]  =   2  fib(3)
//   mem[4]  =   3  fib(4)
//   mem[5]  =   5  fib(5)
//   mem[6]  =   8  fib(6)
//   mem[7]  =  13  fib(7)
//   mem[8]  =  21  fib(8)
//   mem[9]  =  34  fib(9)
//   mem[10] =  55  fib(10)
//   mem[11] =  89  fib(11)
//   mem[12] = 144  fib(12)
//   mem[13] = 233  fib(13)  ← top (sp == 14)
// =============================================================================

`timescale 1ns/1ps

module tb_fibonacci_stack;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg  clk;
reg  rst;
wire halt_out;
wire [7:0] dbg_pc;
wire       dbg_flag_z, dbg_flag_c, dbg_flag_n, dbg_flag_v;
wire [7:0] dbg_r7;
wire [7:0] dbg_stack_top;
wire       dbg_stack_empty;

// ---------------------------------------------------------------------------
// Clock: 10 ns period
// ---------------------------------------------------------------------------
initial clk = 0;
always #5 clk = ~clk;

// ---------------------------------------------------------------------------
// Instantiate CPU
// ---------------------------------------------------------------------------
cpu #(.ROM_INIT("examples/fibonacci_stack.hex")) u_cpu (
    .clk             (clk),
    .rst             (rst),
    .halt_out        (halt_out),
    .dbg_pc          (dbg_pc),
    .dbg_flag_z      (dbg_flag_z),
    .dbg_flag_c      (dbg_flag_c),
    .dbg_flag_n      (dbg_flag_n),
    .dbg_flag_v      (dbg_flag_v),
    .dbg_r7          (dbg_r7),
    .dbg_stack_top   (dbg_stack_top),
    .dbg_stack_empty (dbg_stack_empty)
);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
integer pass_count;
integer fail_count;

task check;
    input [63:0] got;
    input [63:0] expected;
    input [159:0] name;
    begin
        if (got === expected) begin
            $display("  PASS  %-35s got=%0d", name, got);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  %-35s got=%0d  expected=%0d", name, got, expected);
            fail_count = fail_count + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------
integer timeout_cyc;

// Expected fib sequence for stack content checks
reg [7:0] fib [0:13];
integer   i;

initial begin
    $dumpfile("sim/vcd/tb_fibonacci_stack.vcd");
    $dumpvars(0, tb_fibonacci_stack);

    pass_count = 0;
    fail_count = 0;

    // Pre-compute expected values
    fib[0]  =   0; fib[1]  =   1; fib[2]  =   1; fib[3]  =   2;
    fib[4]  =   3; fib[5]  =   5; fib[6]  =   8; fib[7]  =  13;
    fib[8]  =  21; fib[9]  =  34; fib[10] =  55; fib[11] =  89;
    fib[12] = 144; fib[13] = 233;

    // ---- Reset ----
    rst = 1;
    repeat(3) @(posedge clk);
    @(negedge clk);
    rst = 0;

    $display("\n=== Fibonacci Stack Test ===");

    // ---- Run until phase 1 complete: stack top == 233 (fib(13) pushed) ----
    // We detect this when dbg_stack_top == 233 AND stack pointer == 14.
    // Use a timeout in case something goes wrong.
    timeout_cyc = 0;
    while (!(u_cpu.u_stack.sp == 14) && timeout_cyc < 2000) begin
        @(posedge clk);
        timeout_cyc = timeout_cyc + 1;
    end

    @(negedge clk);  // settle

    if (u_cpu.u_stack.sp == 14) begin
        $display("  PASS  %-35s got=%0d", "push phase complete (sp==14)", timeout_cyc);
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL  push phase timeout: sp=%0d", u_cpu.u_stack.sp);
        fail_count = fail_count + 1;
    end

    // ---- Verify all 14 stack slots contain the correct fib values ----
    $display("  --- Stack contents after push phase (bottom to top) ---");
    for (i = 0; i < 14; i = i + 1) begin
        if (u_cpu.u_stack.mem[i] === fib[i]) begin
            $display("  PASS  stack[%0d] == fib(%0d) == %0d", i, i, fib[i]);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  stack[%0d] == fib(%0d): got=%0d expected=%0d",
                     i, i, u_cpu.u_stack.mem[i], fib[i]);
            fail_count = fail_count + 1;
        end
    end

    // ---- Run to halt ----
    timeout_cyc = 0;
    while (!halt_out && timeout_cyc < 2000) begin
        @(posedge clk);
        timeout_cyc = timeout_cyc + 1;
    end

    @(posedge clk);
    @(negedge clk);

    if (halt_out) begin
        $display("  PASS  %-35s got=%0d", "halt_out after pop phase", timeout_cyc);
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL  timeout: halt_out never asserted");
        fail_count = fail_count + 1;
    end

    check(timeout_cyc < 2000 ? 1 : 0, 1, "no timeout");

    // ---- Stack must be empty after all POPs ----
    check(dbg_stack_empty, 1'b1, "stack empty after all POPs");

    // ---- R7 must be fib(0) = 0 (last value popped) ----
    check(dbg_r7, 8'd0, "R7 == 0 (fib(0), last POPped)");

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
    #500000;
    $display("FATAL: simulation hard timeout");
    $finish;
end

endmodule
