// =============================================================================
// tb_mem.v — Testbench for ROM and RAM modules
//
// Simulate with:
//   iverilog -o tb_mem tb/tb_mem.v rtl/rom.v rtl/ram.v && vvp tb_mem
// =============================================================================

`timescale 1ns/1ps

module tb_mem;

// ---------------------------------------------------------------------------
// Clock
// ---------------------------------------------------------------------------
reg clk;
initial clk = 0;
always #5 clk = ~clk;

// ---------------------------------------------------------------------------
// Test tracking
// ---------------------------------------------------------------------------
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

task chk24;
    input [63:0]  id;
    input [127:0] name;
    input [23:0]  got;
    input [23:0]  exp;
    begin
        if (got === exp) begin
            $display("  PASS [%0d] %s = %06h", id, name, got);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL [%0d] %s = %06h (expected %06h)", id, name, got, exp);
            fail_count = fail_count + 1;
        end
    end
endtask

// ===========================================================================
// ROM tests
// ===========================================================================
reg  [15:0] rom_addr;
wire [23:0] rom_data;

rom #(.INIT_FILE("tb/program.hex")) rom_dut (
    .clk      (clk),
    .addr     (rom_addr),
    .data_out (rom_data)
);

// ===========================================================================
// RAM tests
// ===========================================================================
reg        ram_we;
reg  [7:0] ram_addr;
reg  [7:0] ram_din;
wire [7:0] ram_dout;

ram ram_dut (
    .clk      (clk),
    .we       (ram_we),
    .addr     (ram_addr),
    .data_in  (ram_din),
    .data_out (ram_dout)
);

// ---------------------------------------------------------------------------
// Stimulus
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("sim/vcd/tb_mem.vcd");
    $dumpvars(0, tb_mem);

    pass_count = 0;
    fail_count = 0;
    ram_we   = 0;
    ram_addr = 0;
    ram_din  = 0;
    rom_addr = 16'h0000;

    $display("=== Memory Testbench ===");

    // ------------------------------------------------------------------
    // RAM Test 1: Initialised to zero
    // ------------------------------------------------------------------
    $display("--- RAM: Init to zero ---");
    ram_addr = 8'h00; #1; chk8(1, "RAM[00]", ram_dout, 8'h00);
    ram_addr = 8'hAB; #1; chk8(2, "RAM[AB]", ram_dout, 8'h00);
    ram_addr = 8'hFF; #1; chk8(3, "RAM[FF]", ram_dout, 8'h00);

    // ------------------------------------------------------------------
    // RAM Test 2: Write then read back
    // ------------------------------------------------------------------
    $display("--- RAM: Write & readback ---");
    @(negedge clk); ram_we = 1; ram_addr = 8'h10; ram_din = 8'hAB;
    @(posedge clk); #1; ram_we = 0;
    ram_addr = 8'h10; #1;
    chk8(10, "RAM[10]", ram_dout, 8'hAB);

    @(negedge clk); ram_we = 1; ram_addr = 8'hFF; ram_din = 8'h5A;
    @(posedge clk); #1; ram_we = 0;
    ram_addr = 8'hFF; #1;
    chk8(11, "RAM[FF]", ram_dout, 8'h5A);

    // ------------------------------------------------------------------
    // RAM Test 3: Write enable gate — we=0 must not alter memory
    // ------------------------------------------------------------------
    $display("--- RAM: Write enable gate ---");
    @(negedge clk); ram_we = 0; ram_addr = 8'h10; ram_din = 8'hFF;
    @(posedge clk); #1;
    ram_addr = 8'h10; #1;
    chk8(20, "RAM[10] unchanged", ram_dout, 8'hAB);

    // ------------------------------------------------------------------
    // RAM Test 4: Multiple addresses independent
    // ------------------------------------------------------------------
    $display("--- RAM: Multiple addresses ---");
    @(negedge clk); ram_we = 1; ram_addr = 8'h01; ram_din = 8'h11;
    @(posedge clk); #1; ram_we = 0;
    @(negedge clk); ram_we = 1; ram_addr = 8'h02; ram_din = 8'h22;
    @(posedge clk); #1; ram_we = 0;
    @(negedge clk); ram_we = 1; ram_addr = 8'h03; ram_din = 8'h33;
    @(posedge clk); #1; ram_we = 0;

    ram_addr = 8'h01; #1; chk8(30, "RAM[01]", ram_dout, 8'h11);
    ram_addr = 8'h02; #1; chk8(31, "RAM[02]", ram_dout, 8'h22);
    ram_addr = 8'h03; #1; chk8(32, "RAM[03]", ram_dout, 8'h33);
    // Check earlier writes not overwritten
    ram_addr = 8'h10; #1; chk8(33, "RAM[10] still", ram_dout, 8'hAB);

    // ------------------------------------------------------------------
    // RAM Test 5: Overwrite
    // ------------------------------------------------------------------
    $display("--- RAM: Overwrite ---");
    @(negedge clk); ram_we = 1; ram_addr = 8'h01; ram_din = 8'hEE;
    @(posedge clk); #1; ram_we = 0;
    ram_addr = 8'h01; #1; chk8(40, "RAM[01] overwritten", ram_dout, 8'hEE);

    // ------------------------------------------------------------------
    // ROM Test 1: Read known instruction words
    //   program.hex was written at program ROM address 0,1,2... as:
    //   0000: 00DEAD, 0001: 00BEEF, 0002: 001234, 0003: 00ABCD
    // ------------------------------------------------------------------
    $display("--- ROM: Fetch instructions ---");
    // Sync read — present addr, clock, read result next cycle
    @(negedge clk); rom_addr = 16'h0000;
    @(posedge clk); #1;
    chk24(50, "ROM[00]", rom_data, 24'h00DEAD);

    @(negedge clk); rom_addr = 16'h0001;
    @(posedge clk); #1;
    chk24(51, "ROM[01]", rom_data, 24'h00BEEF);

    @(negedge clk); rom_addr = 16'h0002;
    @(posedge clk); #1;
    chk24(52, "ROM[02]", rom_data, 24'h001234);

    @(negedge clk); rom_addr = 16'h0003;
    @(posedge clk); #1;
    chk24(53, "ROM[03]", rom_data, 24'h00ABCD);

    // ------------------------------------------------------------------
    // ROM Test 2: Sequential addresses (simulate instruction fetch)
    // ------------------------------------------------------------------
    $display("--- ROM: Sequential fetch ---");
    begin : seq
        integer k;
        // ROM hex has 0x000010 at address 4, 0x000020 at 5, 0x000030 at 6, 0x000040 at 7
        for (k = 0; k < 4; k = k + 1) begin
            @(negedge clk); rom_addr = 16'h0004 + k[15:0];
            @(posedge clk); #1;
            chk24(60 + k, "ROM seq", rom_data, 24'h000010 + (k[23:0] << 4));
        end
    end

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
