// =============================================================================
// tb_fibonacci_stack.v — Testbench for the fibonacci_stack.asm example program
//
// Program: examples/fibonacci_stack.hex
//
// Phase 1 — the program computes fib(0)..fib(15) iteratively using 16-bit
// arithmetic (register pairs) and PUSHes the lo byte of each value onto the
// hardware stack.  16 pushes total (fills all 16 stack slots).
//
// Phase 2 — the program POPs all 16 values back into R7 in LIFO order,
// then halts.  Final R7 = 0 (= lo(fib(0)), the last value popped).
//
// What is verified:
//   1. halt_out asserted within timeout
//   2. No timeout
//   3. Stack is empty after all POPs (dbg_stack_empty == 1)
//   4. R7 == 0 at halt (fib(0)=0, the last value popped)
//   5. Stack internal contents at end of phase 1 — verified via hierarchical
//      access to u_cpu.u_stack.mem[] and .sp.
//      We detect "end of push phase" by watching sp == 16.
//   6. PC frozen after halt
//
// Expected stack (bottom->top) after phase 1 — lo bytes of fib(0)..fib(15):
//   mem[0]  =   0  lo(fib(0))  = 0
//   mem[1]  =   1  lo(fib(1))  = 1
//   mem[2]  =   1  lo(fib(2))  = 1
//   mem[3]  =   2  lo(fib(3))  = 2
//   mem[4]  =   3  lo(fib(4))  = 3
//   mem[5]  =   5  lo(fib(5))  = 5
//   mem[6]  =   8  lo(fib(6))  = 8
//   mem[7]  =  13  lo(fib(7))  = 13
//   mem[8]  =  21  lo(fib(8))  = 21
//   mem[9]  =  34  lo(fib(9))  = 34
//   mem[10] =  55  lo(fib(10)) = 55
//   mem[11] =  89  lo(fib(11)) = 89
//   mem[12] = 144  lo(fib(12)) = 144
//   mem[13] = 233  lo(fib(13)) = 233
//   mem[14] = 121  lo(fib(14)) = 121  (fib(14)=377, 377 & 0xFF = 121)
//   mem[15] =  98  lo(fib(15)) =  98  (fib(15)=610, 610 & 0xFF =  98)
//                               <- top (sp == 16)
// =============================================================================

`timescale 1ns/1ps

module tb_fibonacci_stack;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg  clk;
reg  rst;
wire halt_out;
wire [15:0] dbg_pc;
wire        dbg_flag_z, dbg_flag_c, dbg_flag_n, dbg_flag_v;
wire [7:0]  dbg_r7;
wire [15:0] dbg_stack_top;
wire        dbg_stack_empty;

// Unused CPU I/O ports tied off
wire        periph_we;
wire [2:0]  periph_port;
wire [7:0]  periph_data;

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
    .prng_data       (8'h00),
    .gpio_data       (8'h00),
    .adc_data        (8'h00),
    .periph_we       (periph_we),
    .periph_port     (periph_port),
    .periph_data     (periph_data),
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

// Expected lo-byte fib sequence for stack content checks
reg [7:0] fib_lo [0:15];
integer   i;

initial begin
    $dumpfile("sim/vcd/tb_fibonacci_stack.vcd");
    $dumpvars(0, tb_fibonacci_stack);

    pass_count = 0;
    fail_count = 0;

    // Pre-compute expected lo bytes: fib(0)..fib(15)
    fib_lo[0]  =   0; fib_lo[1]  =   1; fib_lo[2]  =   1; fib_lo[3]  =   2;
    fib_lo[4]  =   3; fib_lo[5]  =   5; fib_lo[6]  =   8; fib_lo[7]  =  13;
    fib_lo[8]  =  21; fib_lo[9]  =  34; fib_lo[10] =  55; fib_lo[11] =  89;
    fib_lo[12] = 144; fib_lo[13] = 233; fib_lo[14] = 121; fib_lo[15] =  98;

    // ---- Reset ----
    rst = 1;
    repeat(3) @(posedge clk);
    @(negedge clk);
    rst = 0;

    $display("\n=== Fibonacci Stack Test ===");

    // ---- Run until phase 1 complete: all 16 values pushed (sp == 16) ----
    timeout_cyc = 0;
    while (!(u_cpu.u_stack.sp == 16) && timeout_cyc < 4000) begin
        @(posedge clk);
        timeout_cyc = timeout_cyc + 1;
    end

    @(negedge clk);  // settle

    if (u_cpu.u_stack.sp == 16) begin
        $display("  PASS  %-35s got=%0d", "push phase complete (sp==16)", timeout_cyc);
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL  push phase timeout: sp=%0d", u_cpu.u_stack.sp);
        fail_count = fail_count + 1;
    end

    // ---- Verify all 16 stack slots contain the correct lo-byte fib values ----
    $display("  --- Stack contents after push phase (bottom to top) ---");
    for (i = 0; i < 16; i = i + 1) begin
        if (u_cpu.u_stack.mem[i][7:0] === fib_lo[i]) begin
            $display("  PASS  stack[%0d] == lo(fib(%0d)) == %0d", i, i, fib_lo[i]);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  stack[%0d] == lo(fib(%0d)): got=%0d expected=%0d",
                     i, i, u_cpu.u_stack.mem[i][7:0], fib_lo[i]);
            fail_count = fail_count + 1;
        end
    end

    // ---- Run to halt ----
    timeout_cyc = 0;
    while (!halt_out && timeout_cyc < 4000) begin
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

    check(timeout_cyc < 4000 ? 1 : 0, 1, "no timeout");

    // ---- Stack must be empty after all POPs ----
    check(dbg_stack_empty, 1'b1, "stack empty after all POPs");

    // ---- R7 must be lo(fib(0)) = 0 (last value popped) ----
    check(dbg_r7, 8'd0, "R7 == 0 (lo(fib(0)), last POPped)");

    // ---- PC frozen after halt ----
    begin : halt_check
        reg [15:0] pc_snap;
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
