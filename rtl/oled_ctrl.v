// =============================================================================
// oled_ctrl.v — SSD1306 128×32 OLED controller
//
// Displays CPU debug state on a 4-page (128×32 pixel) SSD1306 display.
//
// Display layout (6 pixels wide per char, 5-pixel glyph + 1-pixel gap):
//
//   Page 0 (row 0..7):   PC:XX  Z:X C:X
//   Page 1 (row 8..15):   7:XX  N:X V:X   (no R glyph; shows space+7)
//   Page 2 (row 16..23): SK:XX  HLT:X
//   Page 3 (row 24..31): 16 ASCII chars from RAM[0xF0..0xFF]
//
// FSM:  INIT → RENDER → ADDR_CMD → FLUSH → WAIT → RENDER → ...
//
//   INIT      : stream 18+1 SSD1306 init bytes in a single I2C transaction
//   RENDER    : build 512-byte framebuffer from CPU state snapshot
//   ADDR_CMD  : send 8 addressing-setup command bytes (horizontal mode)
//   FLUSH     : stream all 512 framebuffer bytes as one I2C data transaction
//   WAIT      : ~83 ms idle (~12 Hz refresh)
//
// The i2c_master uses a streaming interface (req/last).
//
// Verilog-2005.
// =============================================================================

module oled_ctrl #(
    parameter T_WAIT   = 15,   // i2c_master quarter-period (~200 kHz at 12 MHz)
    parameter WAIT_BITS = 20   // refresh wait: 2^20 cycles ≈ 83 ms at 12 MHz
) (
    input        clk,
    input        rst,
    // CPU debug inputs
    input  [7:0] pc,
    input        flag_z,
    input        flag_c,
    input        flag_n,
    input        flag_v,
    input  [7:0] r7,
    input  [7:0] stack_top,
    input        stack_empty,
    input        halted,
    // RAM label buffer
    output [7:0] ram_dbg_addr,
    input  [7:0] ram_dbg_data,
    // I2C
    output       scl,
    output       sda
);

// ---------------------------------------------------------------------------
// Character indices (must match char_rom.v)
// ---------------------------------------------------------------------------
localparam CH_0     = 5'd0;
localparam CH_P     = 5'd16;
localparam CH_C_LBL = 5'd17;
localparam CH_Z     = 5'd18;
localparam CH_N     = 5'd19;
localparam CH_V     = 5'd20;
localparam CH_S     = 5'd21;
localparam CH_H     = 5'd22;
localparam CH_T     = 5'd23;
localparam CH_K     = 5'd24;
localparam CH_L     = 5'd25;
localparam CH_COLON = 5'd26;
localparam CH_SPACE = 5'd27;
localparam CH_DASH  = 5'd28;
localparam CH_E     = 5'd29;

// ---------------------------------------------------------------------------
// Framebuffer: 512 bytes (4 pages × 128 columns)
// ---------------------------------------------------------------------------
reg [7:0] fb [0:511];

// ---------------------------------------------------------------------------
// char_rom
// ---------------------------------------------------------------------------
reg  [4:0] rom_ch;
reg  [2:0] rom_row;
wire [4:0] rom_bits;

char_rom u_char_rom (
    .ch   (rom_ch),
    .row  (rom_row),
    .bits (rom_bits)
);

// ---------------------------------------------------------------------------
// i2c_master (streaming)
// ---------------------------------------------------------------------------
reg       i2c_start;
reg       i2c_dcn;
reg [7:0] i2c_data;
reg       i2c_last;
wire      i2c_busy;
wire      i2c_req;

i2c_master #(.T_WAIT(T_WAIT)) u_i2c (
    .clk   (clk),
    .rst   (rst),
    .start (i2c_start),
    .dcn   (i2c_dcn),
    .data  (i2c_data),
    .last  (i2c_last),
    .busy  (i2c_busy),
    .req   (i2c_req),
    .scl   (scl),
    .sda   (sda)
);

// ---------------------------------------------------------------------------
// SSD1306 init sequence (19 bytes sent in one command transaction)
// Command control byte 0x00 means: everything that follows is a command byte.
// Bytes: AE A8 1F D3 00 40 A1 C8 DA 02 81 7F A4 A6 D5 80 8D 14 AF
//  (AE=display off, …, AF=display on at end)
// ---------------------------------------------------------------------------
localparam INIT_LEN = 19;
reg [7:0] init_seq [0:INIT_LEN-1];

initial begin
    init_seq[0]  = 8'hAE;  // display off
    init_seq[1]  = 8'hA8;  // set multiplex ratio
    init_seq[2]  = 8'h1F;  // 32 rows
    init_seq[3]  = 8'hD3;  // set display offset
    init_seq[4]  = 8'h00;  // offset = 0
    init_seq[5]  = 8'h40;  // start line = 0
    init_seq[6]  = 8'hA1;  // segment remap
    init_seq[7]  = 8'hC8;  // COM scan remap
    init_seq[8]  = 8'hDA;  // COM pins config
    init_seq[9]  = 8'h02;  // 128×32 value
    init_seq[10] = 8'h81;  // contrast
    init_seq[11] = 8'hFF;  // max contrast
    init_seq[12] = 8'hA4;  // display follows RAM
    init_seq[13] = 8'hA6;  // normal (not inverted)
    init_seq[14] = 8'hD5;  // clock divide / osc freq
    init_seq[15] = 8'h80;  // default
    init_seq[16] = 8'h8D;  // charge pump
    init_seq[17] = 8'h14;  // enable charge pump
    init_seq[18] = 8'hAF;  // display ON
end

// Addressing setup: horizontal mode, col 0-127, page 0-3 (8 bytes, one transaction)
localparam ADDR_LEN = 8;
reg [7:0] addr_seq [0:ADDR_LEN-1];

initial begin
    addr_seq[0] = 8'h20;  // set memory addressing mode
    addr_seq[1] = 8'h00;  // horizontal mode
    addr_seq[2] = 8'h21;  // set column address
    addr_seq[3] = 8'h00;  // col start = 0
    addr_seq[4] = 8'h7F;  // col end = 127
    addr_seq[5] = 8'h22;  // set page address
    addr_seq[6] = 8'h00;  // page start = 0
    addr_seq[7] = 8'h03;  // page end = 3
end

// ---------------------------------------------------------------------------
// Top-level FSM states
// ---------------------------------------------------------------------------
localparam ST_INIT      = 3'd0;  // send init sequence
localparam ST_INIT_WAIT = 3'd1;  // wait for init transaction to finish
localparam ST_RENDER    = 3'd2;  // build framebuffer
localparam ST_ADDR      = 3'd3;  // send addressing commands
localparam ST_ADDR_WAIT = 3'd4;  // wait for addr transaction
localparam ST_FLUSH     = 3'd5;  // stream framebuffer
localparam ST_FLUSH_WAIT= 3'd6;  // wait for flush transaction
localparam ST_WAIT      = 3'd7;  // refresh idle

reg [2:0] state;

// ---------------------------------------------------------------------------
// Sequence counters
// ---------------------------------------------------------------------------
reg [4:0] seq_idx;     // index into init_seq or addr_seq (5 bits covers 19)
reg [9:0] flush_idx;   // 0..511 for framebuffer flush

// Refresh wait counter
reg [WAIT_BITS-1:0] wait_ctr;

// ---------------------------------------------------------------------------
// Snapshotted CPU state (captured at RENDER entry)
// ---------------------------------------------------------------------------
reg [7:0] snap_pc;
reg       snap_fz, snap_fc, snap_fn, snap_fv;
reg [7:0] snap_r7;
reg [7:0] snap_stk;
reg       snap_empty;
reg       snap_halt;

// ---------------------------------------------------------------------------
// RENDER sub-FSM
// ---------------------------------------------------------------------------
localparam RS_START   = 3'd0;  // snapshot and init counters
localparam RS_CHAR    = 3'd1;  // start a new character cell
localparam RS_COL     = 3'd2;  // iterate rows for one glyph column
localparam RS_SPACER  = 3'd3;  // write spacer column
localparam RS_ADVANCE = 3'd4;  // advance col/char/page
localparam RS_DONE    = 3'd5;

reg [2:0] r_state;

reg [1:0] r_page;
reg [4:0] r_char;
reg [2:0] r_col;      // 0..4 = glyph col, 5 = spacer
reg [2:0] r_row;      // 0..7

// Glyph column base: r_char * 6  (max 15*6=90 for page3, 13*6=78 for others)
// r_char is 5 bits; result needs 7 bits (max 20*6=120 < 128)
wire [6:0] col_base = {2'b0, r_char} * 4'd6;

// RAM label address (page 3)
assign ram_dbg_addr = 8'hF0 + {3'b0, r_char[3:0]};

// Character selection (combinational)
reg [4:0] char_sel;

always @(*) begin
    char_sel = CH_SPACE;
    case (r_page)
        2'd0: case (r_char)
            5'd0:  char_sel = CH_P;
            5'd1:  char_sel = CH_C_LBL;
            5'd2:  char_sel = CH_COLON;
            5'd3:  char_sel = {1'b0, snap_pc[7:4]};
            5'd4:  char_sel = {1'b0, snap_pc[3:0]};
            5'd5:  char_sel = CH_SPACE;
            5'd6:  char_sel = CH_SPACE;
            5'd7:  char_sel = CH_Z;
            5'd8:  char_sel = CH_COLON;
            5'd9:  char_sel = snap_fz ? 5'd1 : 5'd0;
            5'd10: char_sel = CH_SPACE;
            5'd11: char_sel = CH_C_LBL;
            5'd12: char_sel = CH_COLON;
            5'd13: char_sel = snap_fc ? 5'd1 : 5'd0;
            default: char_sel = CH_SPACE;
        endcase
        2'd1: case (r_char)
            5'd0:  char_sel = CH_SPACE;   // no 'R' glyph
            5'd1:  char_sel = 5'd7;        // '7'
            5'd2:  char_sel = CH_COLON;
            5'd3:  char_sel = {1'b0, snap_r7[7:4]};
            5'd4:  char_sel = {1'b0, snap_r7[3:0]};
            5'd5:  char_sel = CH_SPACE;
            5'd6:  char_sel = CH_SPACE;
            5'd7:  char_sel = CH_N;
            5'd8:  char_sel = CH_COLON;
            5'd9:  char_sel = snap_fn ? 5'd1 : 5'd0;
            5'd10: char_sel = CH_SPACE;
            5'd11: char_sel = CH_V;
            5'd12: char_sel = CH_COLON;
            5'd13: char_sel = snap_fv ? 5'd1 : 5'd0;
            default: char_sel = CH_SPACE;
        endcase
        2'd2: case (r_char)
            5'd0:  char_sel = CH_S;
            5'd1:  char_sel = CH_K;
            5'd2:  char_sel = CH_COLON;
            5'd3:  char_sel = snap_empty ? CH_DASH : {1'b0, snap_stk[7:4]};
            5'd4:  char_sel = snap_empty ? CH_DASH : {1'b0, snap_stk[3:0]};
            5'd5:  char_sel = CH_SPACE;
            5'd6:  char_sel = CH_SPACE;
            5'd7:  char_sel = CH_H;
            5'd8:  char_sel = CH_L;
            5'd9:  char_sel = CH_T;
            5'd10: char_sel = CH_COLON;
            5'd11: char_sel = snap_halt ? 5'd1 : 5'd0;
            default: char_sel = CH_SPACE;
        endcase
        2'd3: begin
            if (r_char >= 5'd16)
                char_sel = CH_SPACE;
            else begin
                if      (ram_dbg_data >= 8'h30 && ram_dbg_data <= 8'h39)
                    char_sel = {1'b0, ram_dbg_data[3:0]};
                else if (ram_dbg_data >= 8'h41 && ram_dbg_data <= 8'h46)
                    char_sel = 5'd10 + {2'b0, ram_dbg_data[2:0]} - 5'd1;
                else if (ram_dbg_data >= 8'h61 && ram_dbg_data <= 8'h66)
                    char_sel = 5'd10 + {2'b0, ram_dbg_data[2:0]} - 5'd1;
                else if (ram_dbg_data == 8'h50 || ram_dbg_data == 8'h70) char_sel = CH_P;
                else if (ram_dbg_data == 8'h43 || ram_dbg_data == 8'h63) char_sel = CH_C_LBL;
                else if (ram_dbg_data == 8'h5A || ram_dbg_data == 8'h7A) char_sel = CH_Z;
                else if (ram_dbg_data == 8'h4E || ram_dbg_data == 8'h6E) char_sel = CH_N;
                else if (ram_dbg_data == 8'h56 || ram_dbg_data == 8'h76) char_sel = CH_V;
                else if (ram_dbg_data == 8'h53 || ram_dbg_data == 8'h73) char_sel = CH_S;
                else if (ram_dbg_data == 8'h48 || ram_dbg_data == 8'h68) char_sel = CH_H;
                else if (ram_dbg_data == 8'h54 || ram_dbg_data == 8'h74) char_sel = CH_T;
                else if (ram_dbg_data == 8'h4B || ram_dbg_data == 8'h6B) char_sel = CH_K;
                else if (ram_dbg_data == 8'h4C || ram_dbg_data == 8'h6C) char_sel = CH_L;
                else if (ram_dbg_data == 8'h45 || ram_dbg_data == 8'h65) char_sel = CH_E;
                else if (ram_dbg_data == 8'h3A)                           char_sel = CH_COLON;
                else if (ram_dbg_data == 8'h2D)                           char_sel = CH_DASH;
                else                                                        char_sel = CH_SPACE;
            end
        end
        default: char_sel = CH_SPACE;
    endcase
end

// char_rom is combinational
always @(*) begin
    rom_ch  = char_sel;
    rom_row = r_row;
end

// Framebuffer write port
reg        fb_we;
reg [8:0]  fb_waddr;
reg [7:0]  fb_wdata;

always @(posedge clk) begin
    if (fb_we)
        fb[fb_waddr] <= fb_wdata;
end

// Accumulator for packing 8 row-bits into one fb byte
reg [7:0] r_byte;

// ---------------------------------------------------------------------------
// Max char index per page (inclusive)
// ---------------------------------------------------------------------------
wire [4:0] char_max = (r_page == 2'd3) ? 5'd15 : 5'd13;

// ---------------------------------------------------------------------------
// Main FSM
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        state      <= ST_INIT;
        seq_idx    <= 5'd0;
        flush_idx  <= 10'd0;
        wait_ctr   <= {WAIT_BITS{1'b0}};
        i2c_start  <= 1'b0;
        i2c_dcn    <= 1'b0;
        i2c_data   <= 8'h00;
        i2c_last   <= 1'b0;
        r_state    <= RS_START;
        r_page     <= 2'd0;
        r_char     <= 5'd0;
        r_col      <= 3'd0;
        r_row      <= 3'd0;
        r_byte     <= 8'h00;
        fb_we      <= 1'b0;
        fb_waddr   <= 9'd0;
        fb_wdata   <= 8'h00;
        snap_pc    <= 8'h00;
        snap_fz    <= 1'b0;
        snap_fc    <= 1'b0;
        snap_fn    <= 1'b0;
        snap_fv    <= 1'b0;
        snap_r7    <= 8'h00;
        snap_stk   <= 8'h00;
        snap_empty <= 1'b1;
        snap_halt  <= 1'b0;
    end else begin
        i2c_start <= 1'b0;
        fb_we     <= 1'b0;

        case (state)

            // =================================================================
            // INIT: start one command transaction with all init bytes streamed
            // =================================================================
            ST_INIT: begin
                if (!i2c_busy) begin
                    // Fire first byte
                    i2c_start <= 1'b1;
                    i2c_dcn   <= 1'b0;               // command stream
                    i2c_data  <= init_seq[0];
                    i2c_last  <= (INIT_LEN == 1);
                    seq_idx   <= 5'd1;
                    state     <= ST_INIT_WAIT;
                end
            end

            ST_INIT_WAIT: begin
                // Feed subsequent bytes on req, then wait for busy to fall
                if (i2c_req && seq_idx < INIT_LEN) begin
                    i2c_data <= init_seq[seq_idx];
                    i2c_last <= (seq_idx == INIT_LEN - 1);
                    seq_idx  <= seq_idx + 1'b1;
                end
                if (!i2c_busy && seq_idx == INIT_LEN) begin
                    // Transaction complete
                    state <= ST_RENDER;
                end
            end

            // =================================================================
            // RENDER: build framebuffer
            // =================================================================
            ST_RENDER: begin
                case (r_state)

                    RS_START: begin
                        snap_pc    <= pc;
                        snap_fz    <= flag_z;
                        snap_fc    <= flag_c;
                        snap_fn    <= flag_n;
                        snap_fv    <= flag_v;
                        snap_r7    <= r7;
                        snap_stk   <= stack_top;
                        snap_empty <= stack_empty;
                        snap_halt  <= halted;
                        r_page  <= 2'd0;
                        r_char  <= 5'd0;
                        r_col   <= 3'd0;
                        r_row   <= 3'd0;
                        r_byte  <= 8'h00;
                        r_state <= RS_CHAR;
                    end

                    RS_CHAR: begin
                        // char_sel and rom_ch/rom_row are combinational.
                        // Begin packing rows for column r_col.
                        if (r_col == 3'd5) begin
                            r_state <= RS_SPACER;
                        end else begin
                            r_byte  <= 8'h00;
                            r_row   <= 3'd0;
                            r_state <= RS_COL;
                        end
                    end

                    RS_COL: begin
                        // Pack one row bit into r_byte.
                        // rom_bits[4 - r_col] is the pixel for column r_col.
                        // SSD1306: byte bit 0 = top row of page.
                        case (r_col)
                            3'd0: r_byte[r_row] <= rom_bits[4];
                            3'd1: r_byte[r_row] <= rom_bits[3];
                            3'd2: r_byte[r_row] <= rom_bits[2];
                            3'd3: r_byte[r_row] <= rom_bits[1];
                            3'd4: r_byte[r_row] <= rom_bits[0];
                            default: ;
                        endcase

                        if (r_row == 3'd7) begin
                            // All rows packed — go to RS_ADVANCE to write fb
                            // (write happens in RS_ADVANCE so r_byte is fully committed)
                            r_state <= RS_ADVANCE;
                        end else begin
                            r_row <= r_row + 1'b1;
                        end
                    end

                    RS_SPACER: begin
                        fb_we    <= 1'b1;
                        fb_waddr <= {1'b0, r_page, 7'b0} + {2'b0, col_base} + 9'd5;
                        fb_wdata <= 8'h00;
                        r_state  <= RS_ADVANCE;
                    end

                    RS_ADVANCE: begin
                        // Write completed glyph column byte to framebuffer
                        if (r_col != 3'd5) begin
                            fb_we    <= 1'b1;
                            fb_waddr <= {1'b0, r_page, 7'b0} + {2'b0, col_base} + {6'b0, r_col};
                            fb_wdata <= r_byte;
                        end

                        // Advance col → char → page
                        if (r_col == 3'd5) begin
                            r_col <= 3'd0;
                            if (r_char == char_max) begin
                                r_char <= 5'd0;
                                if (r_page == 2'd3) begin
                                    r_state <= RS_DONE;
                                end else begin
                                    r_page  <= r_page + 1'b1;
                                    r_state <= RS_CHAR;
                                end
                            end else begin
                                r_char  <= r_char + 1'b1;
                                r_state <= RS_CHAR;
                            end
                        end else begin
                            r_col   <= r_col + 1'b1;
                            r_state <= RS_CHAR;
                        end
                    end

                    RS_DONE: begin
                        r_state  <= RS_START;
                        seq_idx  <= 5'd0;
                        state    <= ST_ADDR;
                    end

                    default: r_state <= RS_START;
                endcase
            end

            // =================================================================
            // ADDR: send 8 address-setup commands in one transaction
            // =================================================================
            ST_ADDR: begin
                if (!i2c_busy) begin
                    i2c_start <= 1'b1;
                    i2c_dcn   <= 1'b0;
                    i2c_data  <= addr_seq[0];
                    i2c_last  <= (ADDR_LEN == 1);
                    seq_idx   <= 5'd1;
                    state     <= ST_ADDR_WAIT;
                end
            end

            ST_ADDR_WAIT: begin
                if (i2c_req && seq_idx < ADDR_LEN) begin
                    i2c_data <= addr_seq[seq_idx];
                    i2c_last <= (seq_idx == ADDR_LEN - 1);
                    seq_idx  <= seq_idx + 1'b1;
                end
                if (!i2c_busy && seq_idx == ADDR_LEN) begin
                    flush_idx <= 10'd0;
                    state     <= ST_FLUSH;
                end
            end

            // =================================================================
            // FLUSH: stream all 512 framebuffer bytes in one data transaction
            // =================================================================
            ST_FLUSH: begin
                if (!i2c_busy) begin
                    i2c_start <= 1'b1;
                    i2c_dcn   <= 1'b1;                  // data stream
                    i2c_data  <= fb[0];
                    i2c_last  <= (10'd512 == 10'd1);     // false (512 bytes)
                    flush_idx <= 10'd1;
                    state     <= ST_FLUSH_WAIT;
                end
            end

            ST_FLUSH_WAIT: begin
                if (i2c_req && flush_idx < 10'd512) begin
                    i2c_data  <= fb[flush_idx[8:0]];
                    i2c_last  <= (flush_idx == 10'd511);
                    flush_idx <= flush_idx + 1'b1;
                end
                if (!i2c_busy && flush_idx == 10'd512) begin
                    wait_ctr <= {WAIT_BITS{1'b0}};
                    state    <= ST_WAIT;
                end
            end

            // =================================================================
            // WAIT: ~83 ms before next render
            // =================================================================
            ST_WAIT: begin
                if (wait_ctr == {WAIT_BITS{1'b1}}) begin
                    state <= ST_RENDER;
                end else begin
                    wait_ctr <= wait_ctr + 1'b1;
                end
            end

            default: state <= ST_INIT;
        endcase
    end
end

endmodule
