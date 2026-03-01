// =============================================================================
// tb_oled_strict.v — Strict byte-sequence testbench for oled_ctrl + i2c_master
//
// Captures every byte of every I2C transaction and verifies:
//   1. Transaction 0: addr=0x78(W), ctrl=0x00, then exact 19 init bytes
//   2. Transaction 1: addr=0x78(W), ctrl=0x00, then exact 8 addr-setup bytes
//   3. Transaction 2: addr=0x78(W), ctrl=0x40, then exactly 512 data bytes
//
// Prints each transaction's bytes for manual inspection.
// =============================================================================

`timescale 1ns/1ps

module tb_oled_strict;

// ---------------------------------------------------------------------------
// DUT ports
// ---------------------------------------------------------------------------
reg        clk;
reg        rst;
reg  [7:0] pc;
reg        flag_z, flag_c, flag_n, flag_v;
reg  [7:0] r7;
reg  [7:0] stack_top;
reg        stack_empty;
reg        halted;
wire [7:0] ram_dbg_addr;
wire  [7:0] ram_dbg_data;
wire       scl;
wire       sda;

assign ram_dbg_data = 8'h20; // ASCII space

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
oled_ctrl #(
    .T_WAIT   (2),
    .WAIT_BITS(4)
) dut (
    .clk         (clk),
    .rst         (rst),
    .pc          (pc),
    .flag_z      (flag_z),
    .flag_c      (flag_c),
    .flag_n      (flag_n),
    .flag_v      (flag_v),
    .r7          (r7),
    .stack_top   (stack_top),
    .stack_empty (stack_empty),
    .halted      (halted),
    .ram_dbg_addr(ram_dbg_addr),
    .ram_dbg_data(ram_dbg_data),
    .scl         (scl),
    .sda         (sda)
);

// ---------------------------------------------------------------------------
// Clock
// ---------------------------------------------------------------------------
initial clk = 0;
always #5 clk = ~clk;

// ---------------------------------------------------------------------------
// VCD
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("sim/vcd/tb_oled_strict.vcd");
    $dumpvars(0, tb_oled_strict);
end

// ---------------------------------------------------------------------------
// I2C bus capture — store up to 3 transactions × 600 bytes
// ---------------------------------------------------------------------------
reg [7:0] t0 [0:599];
reg [7:0] t1 [0:599];
reg [7:0] t2 [0:599];
integer   tlen [0:2];

reg scl_prev, sda_prev;
always @(posedge clk) begin
    scl_prev <= scl;
    sda_prev <= sda;
end

wire scl_rise   = scl  & ~scl_prev;
wire start_cond = scl  & ~sda & sda_prev;
wire stop_cond  = scl  &  sda & ~sda_prev;

reg     in_txn;
integer bit_cnt;
reg [7:0] rx_byte;
integer txn_count;

integer b;

initial begin
    txn_count = 0;
    in_txn    = 0;
    bit_cnt   = 0;
    rx_byte   = 0;
    tlen[0]   = 0;
    tlen[1]   = 0;
    tlen[2]   = 0;
    for (b = 0; b < 600; b = b + 1) begin
        t0[b] = 8'hXX; t1[b] = 8'hXX; t2[b] = 8'hXX;
    end
end

always @(posedge clk) begin
    if (start_cond) begin
        in_txn  <= 1;
        bit_cnt <= 0;
        rx_byte <= 0;
    end
    if (stop_cond && in_txn) begin
        in_txn    <= 0;
        if (txn_count < 3)
            txn_count <= txn_count + 1;
    end
    if (scl_rise && in_txn) begin
        if ((bit_cnt % 9) != 8)
            rx_byte <= {rx_byte[6:0], sda};
        if ((bit_cnt % 9) == 7) begin
            // Store completed byte
            if (txn_count == 0 && tlen[0] < 600) begin
                t0[tlen[0]] <= {rx_byte[6:0], sda};
                tlen[0]     <= tlen[0] + 1;
            end else if (txn_count == 1 && tlen[1] < 600) begin
                t1[tlen[1]] <= {rx_byte[6:0], sda};
                tlen[1]     <= tlen[1] + 1;
            end else if (txn_count == 2 && tlen[2] < 600) begin
                t2[tlen[2]] <= {rx_byte[6:0], sda};
                tlen[2]     <= tlen[2] + 1;
            end
        end
        bit_cnt <= bit_cnt + 1;
    end
end

// ---------------------------------------------------------------------------
// Expected byte sequences
// ---------------------------------------------------------------------------
localparam ADDR_W   = 8'h78;  // SSD1306 addr 0x3C << 1, W=0
localparam CTRL_CMD = 8'h00;
localparam CTRL_DAT = 8'h40;

// Init: addr + ctrl + 19 bytes = 21
reg [7:0] exp_init [0:20];
// Addr: addr + ctrl + 8 bytes = 10
reg [7:0] exp_addr [0:9];

initial begin
    exp_init[0]  = ADDR_W;
    exp_init[1]  = CTRL_CMD;
    exp_init[2]  = 8'hAE;
    exp_init[3]  = 8'hA8;
    exp_init[4]  = 8'h1F;
    exp_init[5]  = 8'hD3;
    exp_init[6]  = 8'h00;
    exp_init[7]  = 8'h40;
    exp_init[8]  = 8'hA1;
    exp_init[9]  = 8'hC8;
    exp_init[10] = 8'hDA;
    exp_init[11] = 8'h02;
    exp_init[12] = 8'h81;
    exp_init[13] = 8'hFF;
    exp_init[14] = 8'hA4;
    exp_init[15] = 8'hA6;
    exp_init[16] = 8'hD5;
    exp_init[17] = 8'h80;
    exp_init[18] = 8'h8D;
    exp_init[19] = 8'h14;
    exp_init[20] = 8'hAF;

    exp_addr[0] = ADDR_W;
    exp_addr[1] = CTRL_CMD;
    exp_addr[2] = 8'h20;
    exp_addr[3] = 8'h00;
    exp_addr[4] = 8'h21;
    exp_addr[5] = 8'h00;
    exp_addr[6] = 8'h7F;
    exp_addr[7] = 8'h22;
    exp_addr[8] = 8'h00;
    exp_addr[9] = 8'h03;
end

// ---------------------------------------------------------------------------
// Helpers — print transaction bytes
// ---------------------------------------------------------------------------
task print_txn0;
    begin : pt0
        integer j;
        $write("  txn0 (%0d bytes): ", tlen[0]);
        for (j = 0; j < tlen[0] && j < 25; j = j + 1)
            $write("%02X ", t0[j]);
        if (tlen[0] > 25) $write("...");
        $display("");
    end
endtask

task print_txn1;
    begin : pt1
        integer j;
        $write("  txn1 (%0d bytes): ", tlen[1]);
        for (j = 0; j < tlen[1] && j < 25; j = j + 1)
            $write("%02X ", t1[j]);
        if (tlen[1] > 25) $write("...");
        $display("");
    end
endtask

task print_txn2;
    begin : pt2
        integer j;
        $write("  txn2 (%0d bytes): ", tlen[2]);
        for (j = 0; j < tlen[2] && j < 6; j = j + 1)
            $write("%02X ", t2[j]);
        if (tlen[2] > 6) $write("... (%0d total)", tlen[2]);
        $display("");
    end
endtask

// ---------------------------------------------------------------------------
// Checker
// ---------------------------------------------------------------------------
integer errors;
integer timeout;

initial begin
    errors = 0;

    rst        = 1;
    pc         = 8'hA5;
    flag_z     = 1; flag_c = 0; flag_n = 1; flag_v = 0;
    r7         = 8'h42;
    stack_top  = 8'hBE;
    stack_empty= 0;
    halted     = 0;
    @(posedge clk); @(posedge clk);
    rst = 0;

    // Wait for 3 complete transactions
    timeout = 0;
    while (txn_count < 3 && timeout < 10_000_000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end

    if (timeout >= 10_000_000) begin
        $display("TIMEOUT: only %0d transactions complete", txn_count);
        errors = errors + 1;
    end

    $display("--- I2C transaction dump ---");
    print_txn0;
    print_txn1;
    print_txn2;
    $display("----------------------------");

    // -------- Check txn0: INIT (21 bytes) --------
    begin : chk0
        integer j;
        if (tlen[0] !== 21) begin
            $display("FAIL txn0 (INIT): length=%0d, expected 21", tlen[0]);
            errors = errors + 1;
        end else begin
            for (j = 0; j < 21; j = j + 1) begin
                if (t0[j] !== exp_init[j]) begin
                    $display("FAIL txn0 (INIT) byte[%0d]: got 0x%02X, exp 0x%02X",
                             j, t0[j], exp_init[j]);
                    errors = errors + 1;
                end
            end
            if (errors == 0)
                $display("PASS txn0 (INIT): 21 bytes correct");
        end
    end

    // -------- Check txn1: ADDR_CMD (10 bytes) --------
    begin : chk1
        integer j;
        if (tlen[1] !== 10) begin
            $display("FAIL txn1 (ADDR_CMD): length=%0d, expected 10", tlen[1]);
            errors = errors + 1;
        end else begin
            for (j = 0; j < 10; j = j + 1) begin
                if (t1[j] !== exp_addr[j]) begin
                    $display("FAIL txn1 (ADDR_CMD) byte[%0d]: got 0x%02X, exp 0x%02X",
                             j, t1[j], exp_addr[j]);
                    errors = errors + 1;
                end
            end
            if (errors == 0)
                $display("PASS txn1 (ADDR_CMD): 10 bytes correct");
        end
    end

    // -------- Check txn2: FLUSH (514 bytes = addr+ctrl+512) --------
    begin : chk2
        integer nerrs;
        nerrs = 0;
        if (tlen[2] !== 514) begin
            $display("FAIL txn2 (FLUSH): length=%0d, expected 514", tlen[2]);
            errors = errors + 1;
        end else begin
            if (t2[0] !== ADDR_W) begin
                $display("FAIL txn2 (FLUSH) addr byte: got 0x%02X, exp 0x%02X",
                         t2[0], ADDR_W);
                errors = errors + 1;
                nerrs = nerrs + 1;
            end
            if (t2[1] !== CTRL_DAT) begin
                $display("FAIL txn2 (FLUSH) ctrl byte: got 0x%02X, exp 0x%02X",
                         t2[1], CTRL_DAT);
                errors = errors + 1;
                nerrs = nerrs + 1;
            end
            if (nerrs == 0)
                $display("PASS txn2 (FLUSH): 514 bytes (addr=0x78 ctrl=0x40 + 512 data)");
        end
    end

    if (errors == 0)
        $display("PASS — all transactions correct");
    else
        $display("FAIL — %0d error(s) total", errors);

    $finish;
end

// Global timeout
initial begin
    #200_000_000;
    $display("FAIL: global simulation timeout");
    $finish;
end

endmodule
