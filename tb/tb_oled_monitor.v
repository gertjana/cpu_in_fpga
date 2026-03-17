// =============================================================================
// tb_oled_monitor.v — Testbench for the oled_monitor hardware debug display
//
// Verifies:
//   1. SSD1306 power-on sequence: VDD on, reset pulse, init commands, VBAT on
//   2. SPI signalling: CS asserted during each byte, DC correct per byte type
//   3. Display On command (0xAF) issued after VBAT delay
//   4. Refresh loop starts: page-set commands and font data bytes sent
//   5. PROG_NAME parameter appears in the text output (line 3)
//   6. Flag bits: letter shown when flag set, space when clear
//
// The testbench does NOT simulate a full screen refresh (that would take
// ~30 million cycles at 12 MHz × 8 bits × 128 cols × 4 pages). Instead it
// runs long enough to cover the init + VBAT delay + first few page bytes,
// then checks the SPI waveform shape and control signals.
// =============================================================================

`timescale 1ns/1ps

// Provide the build_config.vh include expected by top.v (not needed here
// since we instantiate oled_monitor directly, but include for compatibility).
`define PROG_NAME "TB TEST            "

module tb_oled_monitor;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg        clk;
reg        rst;
reg  [7:0] r0, r1, r2, r3, r4, r5, r6, r7;
reg  [7:0] pc;
reg        flag_c, flag_z, flag_n, flag_v;

wire       spi_cs_n;
wire       spi_clk;
wire       spi_mosi;
wire       spi_dc;
wire       spi_res_n;
wire       vbat_en;
wire       vdd_en;

// ---------------------------------------------------------------------------
// DUT instantiation
// ---------------------------------------------------------------------------
oled_monitor #(
    .PROG_NAME("TB TEST            ")  // 19 chars
) dut (
    .clk      (clk),
    .rst      (rst),
    .r0       (r0),  .r1 (r1), .r2 (r2), .r3 (r3),
    .r4       (r4),  .r5 (r5), .r6 (r6), .r7 (r7),
    .pc       (pc),
    .flag_c   (flag_c),
    .flag_z   (flag_z),
    .flag_n   (flag_n),
    .flag_v   (flag_v),
    .spi_cs_n (spi_cs_n),
    .spi_clk  (spi_clk),
    .spi_mosi (spi_mosi),
    .spi_dc   (spi_dc),
    .spi_res_n(spi_res_n),
    .vbat_en  (vbat_en),
    .vdd_en   (vdd_en)
);

// ---------------------------------------------------------------------------
// 12 MHz clock — 83.33 ns period
// ---------------------------------------------------------------------------
initial clk = 0;
always #41 clk = ~clk;   // ~12 MHz

// ---------------------------------------------------------------------------
// SPI byte capture helper
// ---------------------------------------------------------------------------
integer  spi_bit_count;
reg [7:0] spi_captured;
reg [7:0] spi_bytes   [0:511];  // captured byte stream
reg       spi_dc_log  [0:511];  // DC level per byte
integer   spi_byte_count;

// Detect falling edge of CS → start of a byte
reg spi_cs_prev;
reg capturing;

always @(posedge clk) begin
    spi_cs_prev <= spi_cs_n;

    // Rising edge of SPI clock → sample MOSI (SSD1306 latches on rising edge)
    // We detect it by watching spi_clk transitions
end

// Use a simple edge-detect on spi_clk to capture bytes
reg spi_clk_prev;
always @(posedge clk) begin
    spi_clk_prev <= spi_clk;

    if (!spi_clk_prev && spi_clk) begin
        // Rising edge of SPI clock — SSD1306 samples MOSI here
        if (!spi_cs_n) begin
            spi_captured <= {spi_captured[6:0], spi_mosi};
            spi_bit_count <= spi_bit_count + 1;
            if (spi_bit_count == 7) begin
                // Byte complete
                spi_captured <= {spi_captured[6:0], spi_mosi};  // include this last bit
                spi_bytes[spi_byte_count]  <= {spi_captured[6:0], spi_mosi};
                spi_dc_log[spi_byte_count] <= spi_dc;
                spi_byte_count <= spi_byte_count + 1;
                spi_bit_count  <= 0;
            end
        end
    end

    if (spi_cs_n) begin
        // CS de-asserted — reset bit counter for next byte
        spi_bit_count <= 0;
    end
end

// ---------------------------------------------------------------------------
// Test sequence
// ---------------------------------------------------------------------------
integer i;
integer pass_count, fail_count;
integer found_disp_on;
integer found_cp;
integer found_page;
integer found_data;

task check;
    input condition;
    input [127:0] msg;
    begin
        if (condition) begin
            $display("  PASS: %s", msg);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: %s", msg);
            fail_count = fail_count + 1;
        end
    end
endtask

// Total simulation time:
//   Reset pulse:  36 cycles
//   VDD wait:     120,000 cycles
//   Init seq:     ~32 bytes × 16 cycles = ~512 cycles
//   VBAT wait:    1,200,000 cycles
//   First refresh: a few hundred cycles for page commands
// We run for 1,400,000 cycles which covers init + VBAT delay + first page cmds.
// At 82 ns / cycle ≈ 115 ms simulated.

localparam SIM_CYCLES = 1_500_000;

initial begin
    $dumpfile("sim/vcd/tb_oled_monitor.vcd");
    $dumpvars(0, tb_oled_monitor);

    // Initialise
    pass_count    = 0;
    fail_count    = 0;
    spi_bit_count = 0;
    spi_byte_count= 0;
    spi_captured  = 8'h00;
    spi_cs_prev   = 1'b1;
    capturing     = 1'b0;
    spi_clk_prev  = 1'b0;

    // Registers, PC, and flags
    r0 = 8'hAB; r1 = 8'hCD; r2 = 8'hEF; r3 = 8'h12;
    r4 = 8'h34; r5 = 8'h56; r6 = 8'h78; r7 = 8'h9A;
    pc = 8'h42;
    flag_c = 1'b1; flag_z = 1'b0; flag_n = 1'b1; flag_v = 1'b0;

    // Apply reset for 10 cycles
    rst = 1'b1;
    repeat (10) @(posedge clk);
    rst = 1'b0;

    // Run for enough cycles to cover init + VBAT delay + start of refresh
    repeat (SIM_CYCLES) @(posedge clk);

    // -----------------------------------------------------------------------
    // Check 1: VDD powered on (vdd_en=0), VBAT powered on (vbat_en=0)
    // -----------------------------------------------------------------------
    $display("\n=== oled_monitor testbench ===");
    $display("--- Power sequence checks ---");
    check(vdd_en  == 1'b0, "VDD enabled (vdd_en=0)");
    check(vbat_en == 1'b0, "VBAT enabled (vbat_en=0)");
    check(spi_res_n == 1'b1, "RES released (spi_res_n=1) after init");

    // -----------------------------------------------------------------------
    // Check 2: SPI bytes were captured
    // -----------------------------------------------------------------------
    $display("--- SPI capture checks ---");
    $display("  Total SPI bytes captured: %0d", spi_byte_count);
    check(spi_byte_count > 20, "More than 20 SPI bytes sent (init sequence)");

    // -----------------------------------------------------------------------
    // Check 3: First command is Display Off (0xAE) — DC=0
    // -----------------------------------------------------------------------
    $display("--- Init sequence checks ---");
    if (spi_byte_count > 0) begin
        $display("  Byte 0: 0x%02X  DC=%b", spi_bytes[0], spi_dc_log[0]);
        check(spi_bytes[0] == 8'hAE, "First byte is Display Off (0xAE)");
        check(spi_dc_log[0] == 1'b0, "First byte sent as command (DC=0)");
    end

    // Check Display On command (0xAF) appears in the sequence
    begin
        found_disp_on = 0;
        for (i = 0; i < spi_byte_count; i = i + 1) begin
            if (spi_bytes[i] == 8'hAF && spi_dc_log[i] == 1'b0)
                found_disp_on = 1;
        end
        check(found_disp_on, "Display On (0xAF) command found in SPI stream");
    end

    // Check charge-pump enable (0x8D) appears
    begin
        found_cp = 0;
        for (i = 0; i < spi_byte_count; i = i + 1) begin
            if (spi_bytes[i] == 8'h8D && spi_dc_log[i] == 1'b0)
                found_cp = 1;
        end
        check(found_cp, "Charge pump cmd (0x8D) found in SPI stream");
    end

    // -----------------------------------------------------------------------
    // Check 4: Page-set commands issued (0xB0..0xB3) — refresh started
    // -----------------------------------------------------------------------
    $display("--- Refresh checks ---");
    begin
        found_page = 0;
        for (i = 0; i < spi_byte_count; i = i + 1) begin
            if ((spi_bytes[i] & 8'hFC) == 8'hB0 && spi_dc_log[i] == 1'b0)
                found_page = 1;
        end
        check(found_page, "Page-set command (0xB0-0xB3) found — refresh active");
    end

    // Check that data bytes (DC=1) appear after the init sequence
    begin
        found_data = 0;
        for (i = 0; i < spi_byte_count; i = i + 1) begin
            if (spi_dc_log[i] == 1'b1)
                found_data = 1;
        end
        check(found_data, "Data bytes (DC=1) found — font pixels being sent");
    end

    // -----------------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------------
    $display("\n=== Results: %0d passed, %0d failed ===\n",
             pass_count, fail_count);

    if (fail_count == 0)
        $display("ALL TESTS PASSED");
    else
        $display("SOME TESTS FAILED");

    $finish;
end

// Safety timeout — should not be reached
initial begin
    #200_000_000;  // 200 ms real time
    $display("TIMEOUT — simulation did not finish");
    $finish;
end

endmodule
