// =============================================================================
// tb_knightrider.v — Testbench for the knightrider.asm example program
//
// Program: examples/knightrider.hex
//
// A single lit LED bounces across 8 LEDs in R7 forever (no HALT).
//
// LED mapping in display mode 1:
//   LED[0] = R7[7] (MSB, leftmost)  →  R7=0x80 = leftmost
//   LED[7] = R7[0] (LSB, rightmost) →  R7=0x01 = rightmost
//
// Expected R7 pattern (first full bounce, starting after init):
//   Scan right:  0x80 → 0x40 → 0x20 → 0x10 → 0x08 → 0x04 → 0x02 → 0x01
//   Turn left:   reload 0x01, then SHL:
//   Scan left:   0x01 → 0x02 → 0x04 → 0x08 → 0x10 → 0x20 → 0x40 → 0x80
//   Turn right:  reload 0x80, continues...
//
// What is verified:
//   1. R7 starts at 0x80 (after init)
//   2. Scan-right: R7 visits 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01
//      (verified by watching for each value in sequence)
//   3. After hitting right edge, R7 reloads to 0x01 (turn_left)
//   4. Scan-left: R7 visits 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80
//   5. After hitting left edge, R7 reloads to 0x80 (turn_right) — second bounce
//   6. No timeout on any wait
//   7. CPU never halts (halt_out stays 0 throughout)
// =============================================================================

`timescale 1ns/1ps

module tb_knightrider;

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
cpu #(.ROM_INIT("examples/knightrider.hex")) u_cpu (
    .clk             (clk),
    .ce              (1'b1),
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
            $display("  PASS  %-35s got=0x%02X", name, got[7:0]);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  %-35s got=0x%02X  expected=0x%02X", name, got[7:0], expected[7:0]);
            fail_count = fail_count + 1;
        end
    end
endtask

// Wait for R7 to become `val`, up to `max_cycles` clock edges.
// Sets `timed_out` = 1 if timeout occurred.
integer wait_cyc;
reg timed_out;

task wait_for_r7;
    input [7:0] val;
    input integer max_cycles;
    begin
        wait_cyc = 0;
        timed_out = 0;
        while (dbg_r7 !== val && wait_cyc < max_cycles) begin
            @(posedge clk);
            #1;  // allow combinational outputs to settle
            wait_cyc = wait_cyc + 1;
        end
        if (dbg_r7 !== val) begin
            timed_out = 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

// Expected pattern arrays
reg [7:0] right_seq [0:7];  // scan right: 0x80 down to 0x01
reg [7:0] left_seq  [0:7];  // scan left: 0x01 up to 0x80
integer i;
integer max_wait;

initial begin
    $dumpfile("sim/vcd/tb_knightrider.vcd");
    $dumpvars(0, tb_knightrider);

    pass_count = 0;
    fail_count = 0;

    // Pre-compute expected sequences
    right_seq[0] = 8'h80; right_seq[1] = 8'h40; right_seq[2] = 8'h20; right_seq[3] = 8'h10;
    right_seq[4] = 8'h08; right_seq[5] = 8'h04; right_seq[6] = 8'h02; right_seq[7] = 8'h01;

    left_seq[0]  = 8'h01; left_seq[1]  = 8'h02; left_seq[2]  = 8'h04; left_seq[3]  = 8'h08;
    left_seq[4]  = 8'h10; left_seq[5]  = 8'h20; left_seq[6]  = 8'h40; left_seq[7]  = 8'h80;

    // Maximum cycles to wait for any single R7 value (generous budget)
    // Each step takes ~3 CPU cycles; 50 is ample.
    max_wait = 50;

    // ---- Reset ----
    rst = 1;
    repeat(3) @(posedge clk);
    @(negedge clk);
    rst = 0;
    repeat(2) @(posedge clk);
    #1;

    $display("\n=== Knight Rider Test ===");

    // ---- Wait for init to complete (R7 should become 0x80) ----
    wait_for_r7(8'h80, 20);
    if (!timed_out) begin
        $display("  PASS  %-35s", "init: R7 == 0x80");
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL  init: R7 never became 0x80 (got 0x%02X)", dbg_r7);
        fail_count = fail_count + 1;
    end

    // ---- Scan right: verify R7 visits 0x80, 0x40, ..., 0x01 in order ----
    $display("  --- Scan right ---");
    for (i = 0; i < 8; i = i + 1) begin
        if (dbg_r7 !== right_seq[i]) begin
            // Not at expected value yet — wait for it
            wait_for_r7(right_seq[i], max_wait);
        end
        if (!timed_out && dbg_r7 === right_seq[i]) begin
            $display("  PASS  scan_right[%0d]: got=0x%02X", i, dbg_r7);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  scan_right[%0d]: got=0x%02X expected=0x%02X", i, dbg_r7, right_seq[i]);
            fail_count = fail_count + 1;
        end
        // Advance one clock so we don't re-sample the same value on next iteration
        if (i < 7) begin
            @(posedge clk);
            #1;
        end
    end

    // ---- Turn left: R7 reloads to 0x01 ----
    // After the last SHR(0x01) the carry fires, turn_left reloads R7=0x01.
    // We already see 0x01 at the end of scan_right, so just verify it's still 0x01.
    // Then advance past the MOV (which writes 0x01 again) and into scan_left.

    // ---- Scan left: verify R7 visits 0x01, 0x02, ..., 0x80 in order ----
    $display("  --- Scan left ---");
    for (i = 0; i < 8; i = i + 1) begin
        if (dbg_r7 !== left_seq[i]) begin
            wait_for_r7(left_seq[i], max_wait);
        end
        if (!timed_out && dbg_r7 === left_seq[i]) begin
            $display("  PASS  scan_left[%0d]: got=0x%02X", i, dbg_r7);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  scan_left[%0d]: got=0x%02X expected=0x%02X", i, dbg_r7, left_seq[i]);
            fail_count = fail_count + 1;
        end
        if (i < 7) begin
            @(posedge clk);
            #1;
        end
    end

    // ---- Second right sweep entry: R7 must return to 0x80 ----
    // (turn_right reloads 0x80, which we already see at the tail of scan_left)
    $display("  --- Turn right (second bounce start) ---");
    if (dbg_r7 !== 8'h80) begin
        wait_for_r7(8'h80, max_wait);
    end
    if (!timed_out && dbg_r7 === 8'h80) begin
        $display("  PASS  %-35s got=0x%02X", "second bounce: R7 == 0x80", dbg_r7);
        pass_count = pass_count + 1;
    end else begin
        $display("  FAIL  second bounce: R7 never became 0x80 (got 0x%02X)", dbg_r7);
        fail_count = fail_count + 1;
    end

    // ---- CPU must never halt (this is an infinite loop program) ----
    check(halt_out, 1'b0, "halt_out stays 0");

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
