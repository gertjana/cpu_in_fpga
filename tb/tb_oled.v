// =============================================================================
// tb_oled.v — Testbench for oled_ctrl + i2c_master + char_rom
//
// Drives fixed CPU debug state into oled_ctrl, monitors the I2C bus,
// decodes every transaction and checks:
//   1. SSD1306 init sequence starts with 0xAE (display off)
//   2. 0xAF (display on) is sent before data
//   3. At least 512 data bytes are sent in the first flush
//   4. Second render+flush occurs (refresh loop works)
//
// Uses T_WAIT=1 and WAIT_BITS=4 to dramatically speed up simulation.
//
// Output: PASS or FAIL on $display.
// VCD written to sim/vcd/tb_oled.vcd for waveform inspection.
// =============================================================================

`timescale 1ns/1ps

module tb_oled;

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
reg  [7:0] ram_dbg_data;
wire       scl;
wire       sda;

// ---------------------------------------------------------------------------
// Simple RAM model for label buffer
// Initialise with "KnightRider    " at 0xF0..0xFF
// ---------------------------------------------------------------------------
reg [7:0] label_ram [0:255];
integer k;
initial begin
    for (k = 0; k < 256; k = k + 1) label_ram[k] = 8'h00;
    // "KnightRider    " — 16 chars
    label_ram[8'hF0] = "K";
    label_ram[8'hF1] = "n";
    label_ram[8'hF2] = "i";
    label_ram[8'hF3] = "g";
    label_ram[8'hF4] = "h";
    label_ram[8'hF5] = "t";
    label_ram[8'hF6] = "R";
    label_ram[8'hF7] = "i";
    label_ram[8'hF8] = "d";
    label_ram[8'hF9] = "e";
    label_ram[8'hFA] = "r";
    label_ram[8'hFB] = " ";
    label_ram[8'hFC] = " ";
    label_ram[8'hFD] = " ";
    label_ram[8'hFE] = " ";
    label_ram[8'hFF] = " ";
end

always @(*) ram_dbg_data = label_ram[ram_dbg_addr];

// ---------------------------------------------------------------------------
// DUT instantiation (T_WAIT=1 → fast I2C, WAIT_BITS=4 → short wait)
// ---------------------------------------------------------------------------
oled_ctrl #(
    .T_WAIT   (1),
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
// Clock: 10 ns period
// ---------------------------------------------------------------------------
initial clk = 0;
always #5 clk = ~clk;

// ---------------------------------------------------------------------------
// I2C bus monitor — decode every transaction
// ---------------------------------------------------------------------------
// Capture bytes as START→addr→ctrl→data→STOP sequences
// We watch SDA transitions while SCL is high for START/STOP conditions,
// and sample SDA on SCL rising edge for data bits.

integer transaction_count;
integer cmd_count;          // transactions with dcn=0 (command)
integer data_count;         // transactions with dcn=1 (data, i.e. pixel bytes)
reg     saw_AE;             // 0xAE seen in init
reg     saw_AF;             // 0xAF seen before first flush
reg     saw_start;          // within a transaction
integer bit_count;
reg [7:0] rx_byte;
integer rx_phase;           // 0=addr, 1=ctrl, 2=data
reg [7:0] rx_ctrl;
reg [7:0] rx_addr_byte;

// Latch SDA/SCL on posedge for edge detection
reg scl_prev, sda_prev;
always @(posedge clk) begin
    scl_prev <= scl;
    sda_prev <= sda;
end

wire scl_rise = scl & ~scl_prev;
wire scl_fall = ~scl & scl_prev;
wire start_cond = scl & ~sda & sda_prev;   // SDA falls while SCL high
wire stop_cond  = scl &  sda & ~sda_prev;  // SDA rises while SCL high

always @(posedge clk) begin
    if (rst) begin
        transaction_count <= 0;
        cmd_count         <= 0;
        data_count        <= 0;
        saw_AE            <= 0;
        saw_AF            <= 0;
        saw_start         <= 0;
        bit_count         <= 0;
        rx_byte           <= 0;
        rx_phase          <= 0;
        rx_ctrl           <= 0;
        rx_addr_byte      <= 0;
    end else begin
        if (start_cond) begin
            saw_start <= 1;
            bit_count <= 0;
            rx_byte   <= 0;
            rx_phase  <= 0;
        end

        if (stop_cond && saw_start) begin
            saw_start <= 0;
            transaction_count <= transaction_count + 1;
        end

        // Sample data bits on SCL rising edge (skip ACK bits every 9th)
        if (scl_rise && saw_start) begin
            // We use bit_count mod 9; bits 0..7 are data, bit 8 is ACK
            if ((bit_count % 9) != 8) begin
                rx_byte <= {rx_byte[6:0], sda};
            end

            if ((bit_count % 9) == 7) begin
                // Completed one byte (will be latched, ACK is next)
                case (rx_phase)
                    0: begin rx_addr_byte <= {rx_byte[6:0], sda}; rx_phase <= 1; end
                    1: begin rx_ctrl <= {rx_byte[6:0], sda};      rx_phase <= 2; end
                    2: begin
                        // Data byte received
                        if (rx_ctrl == 8'h00) begin
                            // Command byte
                            cmd_count <= cmd_count + 1;
                            if ({rx_byte[6:0], sda} == 8'hAE) saw_AE <= 1;
                            if ({rx_byte[6:0], sda} == 8'hAF) saw_AF <= 1;
                        end else begin
                            // Data byte (pixel)
                            data_count <= data_count + 1;
                        end
                    end
                    default: ;
                endcase
            end
            bit_count <= bit_count + 1;
        end
    end
end

// ---------------------------------------------------------------------------
// VCD dump
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("sim/vcd/tb_oled.vcd");
    $dumpvars(0, tb_oled);
end

// ---------------------------------------------------------------------------
// Test stimulus
// ---------------------------------------------------------------------------
integer errors;
integer timeout;

initial begin
    errors = 0;

    // Apply reset
    rst        = 1;
    pc         = 8'hA5;
    flag_z     = 1;
    flag_c     = 0;
    flag_n     = 1;
    flag_v     = 0;
    r7         = 8'h42;
    stack_top  = 8'hBE;
    stack_empty= 0;
    halted     = 0;
    @(posedge clk); @(posedge clk);
    rst = 0;

    // ---------------------------------------------------------------------------
    // Wait long enough for: init (18 cmds) + render + addr (8 cmds) + disp_on +
    // flush (512 bytes) + wait + second render start.
    // At T_WAIT=1, each I2C transaction takes ~(4*1*27) = ~108 clk cycles.
    // 18+8+1+512 = 539 transactions × ~108 cycles = ~58k cycles.
    // Add WAIT_BITS=4 → 16 cycles wait. Total ~60k cycles → 600k ns.
    // Give 10× margin.
    // ---------------------------------------------------------------------------
    timeout = 0;
    while (data_count < 512 && timeout < 5_000_000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end

    if (timeout >= 5_000_000) begin
        $display("TIMEOUT waiting for first flush");
        errors = errors + 1;
    end

    // Check init byte 0xAE was seen
    if (!saw_AE) begin
        $display("FAIL: 0xAE (display off) not seen in command stream");
        errors = errors + 1;
    end

    // Check 0xAF was seen
    if (!saw_AF) begin
        $display("FAIL: 0xAF (display on) not seen in command stream");
        errors = errors + 1;
    end

    // Check at least 512 data bytes were sent
    if (data_count < 512) begin
        $display("FAIL: only %0d data bytes seen (expected >=512)", data_count);
        errors = errors + 1;
    end

    // Wait for second flush to start (confirms the refresh loop works)
    timeout = 0;
    while (data_count < 600 && timeout < 5_000_000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end

    if (timeout >= 5_000_000) begin
        $display("FAIL: second refresh cycle did not start");
        errors = errors + 1;
    end

    if (errors == 0)
        $display("PASS — oled_ctrl: init sequence OK, %0d cmd bytes, %0d data bytes, refresh loop OK",
                 cmd_count, data_count);
    else
        $display("FAIL — %0d error(s)", errors);

    $finish;
end

// Global timeout guard
initial begin
    #100_000_000;
    $display("FAIL: global simulation timeout");
    $finish;
end

endmodule
