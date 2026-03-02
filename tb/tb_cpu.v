// =============================================================================
// tb_cpu.v — Testbench for the top-level CPU
//
// Program loaded: cpu_program.hex
//
// Program behaviour (verified by manual simulation):
//   R0 counts 0 → 5 via a CALL/RET subroutine that increments by 1
//   Loop uses CMPI + JNZ; exits when R0 == 5
//   After loop: PUSH R0, POP R2  (so R2 should equal 5)
//   Then HALT
//
// Expected final state (checked after halt is detected):
//   R0 == 5
//   R2 == 5
//
// The testbench also verifies the hardware PRNG (IN instruction):
//   - Drives clk_fast at a faster rate than clk to mimic the board's 12 MHz
//   - Reads the raw LFSR register and confirms it changes between CPU cycles
//
// The testbench inspects internal register file via hierarchical references.
// It also verifies halt_out is asserted and the CPU stops advancing.
// =============================================================================

`timescale 1ns/1ps

module tb_cpu;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg  clk;
reg  clk_fast;   // fast board clock fed to the PRNG (runs independently)
reg  rst;
wire halt_out;
wire [7:0] dbg_pc;
wire       dbg_flag_z, dbg_flag_c, dbg_flag_n, dbg_flag_v;
wire [7:0] dbg_r7;

// ---------------------------------------------------------------------------
// CPU clock: 10 ns period (100 MHz in simulation)
// Fast clock: 3 ns period (~333 MHz) — ~3× faster than clk, mimicking the
// ratio of 12 MHz board clock vs the divided CPU clock on hardware.
// ---------------------------------------------------------------------------
initial clk      = 0;
initial clk_fast = 0;
always #5  clk      = ~clk;
always #1  clk_fast = ~clk_fast;

// ---------------------------------------------------------------------------
// Instantiate CPU (point ROM to our program hex)
// ---------------------------------------------------------------------------
cpu #(.ROM_INIT("tb/cpu_program.hex")) u_cpu (
    .clk             (clk),
    .clk_fast        (clk_fast),
    .rst             (rst),
    .halt_out        (halt_out),
    .dbg_pc          (dbg_pc),
    .dbg_flag_z      (dbg_flag_z),
    .dbg_flag_c      (dbg_flag_c),
    .dbg_flag_n      (dbg_flag_n),
    .dbg_flag_v      (dbg_flag_v),
    .dbg_r7          (dbg_r7),
    .dbg_stack_top   (),
    .dbg_stack_empty ()
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
    $dumpfile("sim/vcd/tb_cpu.vcd");
    $dumpvars(0, tb_cpu);

    pass_count = 0;
    fail_count = 0;

    // ---- Reset ----
    rst = 1;
    repeat(3) @(posedge clk);
    @(negedge clk);
    rst = 0;

    // ---- Run until halt or timeout ----
    timeout_cyc = 0;
    while (!halt_out && timeout_cyc < 500) begin
        @(posedge clk);
        timeout_cyc = timeout_cyc + 1;
    end

    // Wait one more cycle so everything settles after halt
    @(posedge clk);
    @(negedge clk);

    // ---- Check halt was actually asserted ----
    $display("\n=== CPU Integration Test ===");
    if (halt_out) begin
        $display("  PASS  halt_out asserted after %0d cycles", timeout_cyc);
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL  timeout: halt_out never asserted");
        fail_count = fail_count + 1;
    end

    // ---- Verify CPU did not timeout ----
    check(timeout_cyc < 500 ? 1 : 0, 1, "no timeout");

    // ---- Check register values via hierarchical access ----
    // R0 should be 5 (loop ran 5 times, each call incremented by 1)
    check(u_cpu.u_rf.regs[0], 8'd5, "R0 == 5");

    // R2 should be 5 (popped from stack after PUSH R0)
    check(u_cpu.u_rf.regs[2], 8'd5, "R2 == 5 (after PUSH/POP)");

    // ---- Check CPU stays halted (PC should not change) ----
    begin : halt_check
        reg [7:0] pc_snap;
        pc_snap = u_cpu.u_pc.pc_out;
        repeat(5) @(posedge clk);
        check(u_cpu.u_pc.pc_out, pc_snap, "PC frozen after halt");
    end

    // ---- Check PRNG: LFSR advances on clk_fast independently of clk ----
    // Reset the CPU, then sample the raw LFSR across multiple clk_fast edges.
    begin : prng_check
        reg [7:0] val0, val1, val2;
        rst = 1; @(posedge clk); @(posedge clk); rst = 0;
        // Wait for rst_r (the cpu-clock-registered reset flop inside prng) to
        // clear, then let a few fast-clock edges pass before sampling.
        @(posedge clk);           // rst_r clears on this edge
        repeat(4) @(posedge clk_fast);  // let LFSR run a bit
        // Sample three consecutive fast-clock values
        @(posedge clk_fast); val0 = u_cpu.u_prng.lfsr;
        @(posedge clk_fast); val1 = u_cpu.u_prng.lfsr;
        @(posedge clk_fast); val2 = u_cpu.u_prng.lfsr;
        // LFSR should have stepped — values must differ
        if (val0 !== val1) begin
            $display("  PASS  PRNG advances each fast-clock cycle (0x%02h → 0x%02h)", val0, val1);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  PRNG did not advance (stuck at 0x%02h)", val0);
            fail_count = fail_count + 1;
        end
        // LFSR should never be zero (lock-up state)
        if (val0 !== 8'h00 && val1 !== 8'h00 && val2 !== 8'h00) begin
            $display("  PASS  PRNG never zero");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  PRNG reached zero (lock-up state)");
            fail_count = fail_count + 1;
        end
        // Confirm LFSR is still moving after several slow CPU cycles
        // (i.e. it is not gated by the CPU clock)
        @(posedge clk); val0 = u_cpu.u_prng.lfsr;
        @(posedge clk); val1 = u_cpu.u_prng.lfsr;
        if (val0 !== val1) begin
            $display("  PASS  PRNG runs independently of CPU clock");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  PRNG held across CPU clock edges (not running freely)");
            fail_count = fail_count + 1;
        end
    end

    // ---- Summary ----
    $display("\n=== Results: %0d passed, %0d failed ===", pass_count, fail_count);

    if (fail_count == 0)
        $display("ALL TESTS PASSED");
    else
        $display("SOME TESTS FAILED");

    $finish;
end

// Safety net — hard timeout
initial begin
    #100000;
    $display("FATAL: simulation hard timeout");
    $finish;
end

endmodule
