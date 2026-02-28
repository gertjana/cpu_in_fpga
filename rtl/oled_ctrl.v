// =============================================================================
// oled_ctrl.v — SSD1306 128×32 OLED controller
//
// Displays CPU debug state on a 4-page (128×32 pixel) SSD1306 display.
// Uses a full 512-byte framebuffer (4 pages × 128 columns) in block RAM.
//
// Display layout (6×8 per character, one space column between chars):
//
//   Page 0 (row 0..7):   PC:xx  Z:x C:x
//   Page 1 (row 8..15):  R7:xx  N:x V:x
//   Page 2 (row 16..23): SK:xx  HLT:x
//   Page 3 (row 24..31): <16 ASCII chars from RAM[0xF0..0xFF]>
//
// The label buffer (page 3) is read from the CPU's data RAM via a debug
// read port.  Programs write their name there at startup:
//   RAM[0xF0] = first char, RAM[0xFF] = last char (16 bytes total).
//   Characters are 7-bit ASCII; 0x00 is treated as space.
//
// FSM phases:
//   INIT    — send SSD1306 initialisation commands over I2C
//   RENDER  — build framebuffer from live CPU state
//   FLUSH   — stream framebuffer to display over I2C (512 data bytes)
//   WAIT    — idle ~100 ms before next refresh
//
// Verilog-2005.
// =============================================================================

module oled_ctrl #(
    // I2C master quarter-period (T_WAIT=15 → ~200 kHz at 12 MHz)
    parameter T_WAIT = 15,
    // Refresh wait: 12_000_000 / 2^WAIT_BITS ≈ refresh rate
    // 2^20 = ~1M cycles → ~83 ms at 12 MHz
    parameter WAIT_BITS = 20
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
    // RAM label buffer (oled_ctrl drives dbg_addr, cpu/ram returns dbg_data)
    output [7:0] ram_dbg_addr,
    input  [7:0] ram_dbg_data,
    // I2C outputs
    output       scl,
    output       sda
);

// ---------------------------------------------------------------------------
// Character index constants (must match char_rom.v)
// ---------------------------------------------------------------------------
localparam CH_0     = 5'd0;
localparam CH_P     = 5'd16;
localparam CH_C_LBL = 5'd17;  // C label (same glyph as hex C but cleaner naming)
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

// Hex digit: index = value (0–9 → 0–9, A–F → 10–15)

// ---------------------------------------------------------------------------
// Framebuffer: 4 pages × 128 columns = 512 bytes
// Addressed as fb[page*128 + col]
// ---------------------------------------------------------------------------
reg [7:0] fb [0:511];

// ---------------------------------------------------------------------------
// char_rom instance
// ---------------------------------------------------------------------------
// We drive ch/row combinationally during RENDER to look up glyph bits.
reg  [4:0] rom_ch;
reg  [2:0] rom_row;
wire [4:0] rom_bits;

char_rom u_char_rom (
    .ch   (rom_ch),
    .row  (rom_row),
    .bits (rom_bits)
);

// ---------------------------------------------------------------------------
// i2c_master instance
// ---------------------------------------------------------------------------
reg       i2c_start;
reg       i2c_dcn;
reg [7:0] i2c_data;
wire      i2c_busy;

i2c_master #(.T_WAIT(T_WAIT)) u_i2c (
    .clk   (clk),
    .rst   (rst),
    .start (i2c_start),
    .dcn   (i2c_dcn),
    .data  (i2c_data),
    .busy  (i2c_busy),
    .scl   (scl),
    .sda   (sda)
);

// ---------------------------------------------------------------------------
// SSD1306 init sequence
// 18 command bytes (each sent individually as i2c_dcn=0 transaction)
// ---------------------------------------------------------------------------
// Init sequence for 128×32 display (mux=0x1F, com_pins=0x02):
//   If using 128×64, change mux to 0x3F and com_pins to 0x12.
localparam INIT_LEN = 18;
reg [7:0] init_seq [0:INIT_LEN-1];

initial begin
    init_seq[0]  = 8'hAE;  // display off
    init_seq[1]  = 8'hA8;  // set multiplex ratio
    init_seq[2]  = 8'h1F;  // 0x1F = 32 rows (128×32); use 0x3F for 128×64
    init_seq[3]  = 8'hD3;  // set display offset
    init_seq[4]  = 8'h00;  // no offset
    init_seq[5]  = 8'h40;  // set display start line = 0
    init_seq[6]  = 8'hA1;  // segment re-map (col 127 = SEG0 for correct orientation)
    init_seq[7]  = 8'hC8;  // COM scan direction: remapped (for correct orientation)
    init_seq[8]  = 8'hDA;  // set COM pins hardware config
    init_seq[9]  = 8'h02;  // 0x02 for 128×32; use 0x12 for 128×64
    init_seq[10] = 8'h81;  // set contrast
    init_seq[11] = 8'h7F;  // medium contrast
    init_seq[12] = 8'hA4;  // entire display ON (output follows RAM)
    init_seq[13] = 8'hA6;  // normal display (not inverted)
    init_seq[14] = 8'hD5;  // set display clock divide ratio / oscillator freq
    init_seq[15] = 8'h80;  // default ratio
    init_seq[16] = 8'h8D;  // charge pump setting
    init_seq[17] = 8'h14;  // enable charge pump
    // Note: display-on (0xAF) is sent as the first command of every FLUSH
    // after the address setup, so the display stays off during init sequencing
    // and lights up cleanly on first frame.
end

// ---------------------------------------------------------------------------
// Top-level FSM
// ---------------------------------------------------------------------------
localparam ST_INIT         = 4'd0;
localparam ST_INIT_WAIT    = 4'd1;
localparam ST_RENDER       = 4'd2;
localparam ST_ADDR_CMD     = 4'd3;  // send page address setup commands
localparam ST_ADDR_WAIT    = 4'd4;
localparam ST_DISP_ON      = 4'd5;  // send 0xAF (display on)
localparam ST_DISP_ON_WAIT = 4'd6;
localparam ST_FLUSH        = 4'd7;  // stream framebuffer bytes
localparam ST_FLUSH_WAIT   = 4'd8;
localparam ST_WAIT         = 4'd9;

reg [3:0] state;

// Init command counter
reg [4:0] init_idx;

// Address-setup command sequence:
//   0x20 0x00  — horizontal addressing mode
//   0x21 0x00 0x7F — column start/end = 0..127
//   0x22 0x00 0x03 — page start/end = 0..3
// Sent as 6 separate command transactions
localparam ADDR_LEN = 6;
reg [7:0] addr_seq [0:ADDR_LEN-1];
reg [2:0] addr_idx;

initial begin
    addr_seq[0] = 8'h20;  // set memory addressing mode
    addr_seq[1] = 8'h00;  // horizontal mode
    addr_seq[2] = 8'h21;  // set column address
    addr_seq[3] = 8'h00;  // column start = 0
    addr_seq[4] = 8'h7F;  // column end = 127
    addr_seq[5] = 8'h22;  // set page address
    // page start / end sent inline in ST_ADDR_CMD because we need two more
end

// We need 8 commands for addressing: 0x20,0x00, 0x21,0x00,0x7F, 0x22,0x00,0x03
// Use a flat 8-entry sequence:
localparam ADDR2_LEN = 8;
reg [7:0] addr2_seq [0:ADDR2_LEN-1];
reg [3:0] addr2_idx;

initial begin
    addr2_seq[0] = 8'h20;  // addressing mode
    addr2_seq[1] = 8'h00;  // horizontal
    addr2_seq[2] = 8'h21;  // column address
    addr2_seq[3] = 8'h00;  // col start
    addr2_seq[4] = 8'h7F;  // col end
    addr2_seq[5] = 8'h22;  // page address
    addr2_seq[6] = 8'h00;  // page start
    addr2_seq[7] = 8'h03;  // page end
end

// Flush counter: 512 bytes (10 bits to hold 0..511 without overflow)
reg [9:0] flush_idx;  // 0..511

// Refresh wait counter
reg [WAIT_BITS-1:0] wait_ctr;

// ---------------------------------------------------------------------------
// RENDER logic — build framebuffer from CPU state
//
// Layout (6 pixels wide per char including 1-pixel gap column):
//   Page 0: "PC:XX  Z:X C:X  " — positions 0..20 chars
//   Page 1: "R7:XX  N:X V:X  "
//   Page 2: "SK:XX  HLT:X    "
//   Page 3: 16 ASCII chars from RAM[0xF0..0xFF]
//
// Each character occupies 6 columns: 5 glyph bits + 1 blank column.
// At 6px/char, 21 chars = 126 px (fits in 128 with 2 spare columns).
//
// Rendering is done in a sub-FSM that runs inside ST_RENDER.
// We iterate: page 0..3, char 0..20 (or 0..15 for page 3), row 0..7,
// col 0..4 within char — writing one fb[] entry per clock.
// ---------------------------------------------------------------------------

// Render sub-FSM
localparam RS_IDLE     = 3'd0;
localparam RS_FETCH    = 3'd1;  // latch char index for current cell
localparam RS_ROMWAIT  = 3'd2;  // one-cycle wait for combinational rom lookup
localparam RS_WRITE    = 3'd3;  // write 8 row-bits packed into fb byte
localparam RS_DONE     = 3'd4;

reg [2:0] r_state;

// Render counters
reg [1:0] r_page;   // 0..3
reg [4:0] r_char;   // 0..20 (pages 0–2) or 0..15 (page 3)
reg [2:0] r_row;    // 0..7

// The fb column for the left edge of the current character
// r_char is 5 bits (0..20), multiplied by 6 → max 126, needs 7 bits.
wire [6:0] r_col_base = {2'b00, r_char} * 3'd6;

// ---------------------------------------------------------------------------
// Character selection: given (page, char position), return char_rom index
// and handle hex digit lookup.
// ---------------------------------------------------------------------------
// Latched CPU state (captured at start of RENDER to keep display consistent)
reg [7:0] snap_pc;
reg       snap_fz, snap_fc, snap_fn, snap_fv;
reg [7:0] snap_r7;
reg [7:0] snap_stk;
reg       snap_empty;
reg       snap_halt;

// RAM label buffer scan
// During RENDER of page 3, we scan RAM[0xF0 + r_char] for up to 16 chars.
assign ram_dbg_addr = 8'hF0 + {3'b000, r_char[3:0]};

// char_sel: the char_rom index for the current (r_page, r_char) cell.
// We compute this combinationally; it feeds rom_ch in RS_FETCH.
reg [4:0] char_sel;

always @(*) begin
    char_sel = CH_SPACE;  // default: blank

    case (r_page)
        // ------------------------------------------------------------------
        // Page 0: P C : x x _ _ Z : x _ C : x
        //  pos:   0 1 2 3 4 5 6 7 8 9 ...
        // ------------------------------------------------------------------
        2'd0: begin
            case (r_char)
                5'd0:  char_sel = CH_P;
                5'd1:  char_sel = CH_C_LBL;
                5'd2:  char_sel = CH_COLON;
                5'd3:  char_sel = snap_pc[7:4];   // PC high nibble (hex digit)
                5'd4:  char_sel = snap_pc[3:0];   // PC low nibble
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
        end

        // ------------------------------------------------------------------
        // Page 1: R 7 : x x _ _ N : x _ V : x
        // ------------------------------------------------------------------
        2'd1: begin
            case (r_char)
                5'd0:  char_sel = 5'd0;           // we'll use a workaround: no 'R' glyph
                                                   // repurpose as space — see note below
                5'd1:  char_sel = 5'd7;            // '7' glyph (index 7)
                5'd2:  char_sel = CH_COLON;
                5'd3:  char_sel = snap_r7[7:4];
                5'd4:  char_sel = snap_r7[3:0];
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
        end

        // ------------------------------------------------------------------
        // Page 2: S K : x x _ _ H L T : x
        // (SK = stack top, -- if empty; HLT = halted flag)
        // ------------------------------------------------------------------
        2'd2: begin
            case (r_char)
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
        end

        // ------------------------------------------------------------------
        // Page 3: 16 ASCII chars from RAM[0xF0..0xFF]
        // ram_dbg_addr is already set to 0xF0 + r_char.
        // We convert the ASCII byte to a char_rom index:
        //   '0'..'9' → 0..9
        //   'A'..'F','a'..'f' → 10..15
        //   'P','p' → 16   'C','c' → 17   'Z','z' → 18
        //   'N','n' → 19   'V','v' → 20   'S','s' → 21
        //   'H','h' → 22   'T','t' → 23   'K','k' → 24
        //   'L','l' → 25   ':' → 26
        //   everything else / 0x00 → space (27)
        // ------------------------------------------------------------------
        2'd3: begin
            if (r_char >= 5'd16) begin
                char_sel = CH_SPACE;
            end else begin
                // ASCII decode
                if (ram_dbg_data >= 8'h30 && ram_dbg_data <= 8'h39)
                    char_sel = ram_dbg_data[3:0];        // '0'..'9'
                else if (ram_dbg_data >= 8'h41 && ram_dbg_data <= 8'h46)
                    char_sel = 5'd10 + (ram_dbg_data - 8'h41); // 'A'..'F'
                else if (ram_dbg_data >= 8'h61 && ram_dbg_data <= 8'h66)
                    char_sel = 5'd10 + (ram_dbg_data - 8'h61); // 'a'..'f'
                else if (ram_dbg_data == 8'h50 || ram_dbg_data == 8'h70)
                    char_sel = CH_P;
                else if (ram_dbg_data == 8'h43 || ram_dbg_data == 8'h63)
                    char_sel = CH_C_LBL;
                else if (ram_dbg_data == 8'h5A || ram_dbg_data == 8'h7A)
                    char_sel = CH_Z;
                else if (ram_dbg_data == 8'h4E || ram_dbg_data == 8'h6E)
                    char_sel = CH_N;
                else if (ram_dbg_data == 8'h56 || ram_dbg_data == 8'h76)
                    char_sel = CH_V;
                else if (ram_dbg_data == 8'h53 || ram_dbg_data == 8'h73)
                    char_sel = CH_S;
                else if (ram_dbg_data == 8'h48 || ram_dbg_data == 8'h68)
                    char_sel = CH_H;
                else if (ram_dbg_data == 8'h54 || ram_dbg_data == 8'h74)
                    char_sel = CH_T;
                else if (ram_dbg_data == 8'h4B || ram_dbg_data == 8'h6B)
                    char_sel = CH_K;
                else if (ram_dbg_data == 8'h4C || ram_dbg_data == 8'h6C)
                    char_sel = CH_L;
                else if (ram_dbg_data == 8'h45 || ram_dbg_data == 8'h65)
                    char_sel = CH_E;
                else if (ram_dbg_data == 8'h3A)
                    char_sel = CH_COLON;
                else if (ram_dbg_data == 8'h2D)
                    char_sel = CH_DASH;
                else if (ram_dbg_data == 8'h47 || ram_dbg_data == 8'h67)
                    char_sel = 5'd16; // G — not in ROM, show P as placeholder
                else
                    char_sel = CH_SPACE;
            end
        end

        default: char_sel = CH_SPACE;
    endcase
end

// ---------------------------------------------------------------------------
// Render sub-FSM
// We write 8 rows for each character column in one pass.
// For each (page, char, col_within_char=0..4):
//   fb[page*128 + col_base + col] = {row7_bit, row6_bit, ... row0_bit}
// That is: for a given column we pack all 8 rows into one byte.
//
// Simplified: iterate page→char→column_in_char, look up each row bit from
// char_rom, pack into a byte, write to fb.
//
// To keep it simple we use a linear pass:
//   for each (page, char):
//     latch char_sel → rom_ch
//     for row in 0..7:
//       rom_row = row → rom_bits gives 5 bits for this row
//     pack: fb_byte[row] = rom_bits[4] (leftmost pixel of this col-within-char)
//   actually we need to iterate over col within char too.
//
// Cleaner approach:
//   iterate (page, char, col_in_char 0..5):
//     if col_in_char == 5: write 0x00 (spacer column)
//     else:
//       for each row 0..7: bit[row] = char_rom(ch, row)[4 - col_in_char]
//       pack into byte and write to fb
// We do this one (page,char,col) per clock, needing 7 row lookups.
// We use a small sub-counter to iterate rows and build the byte.
// ---------------------------------------------------------------------------

reg [2:0] r_col;       // column within character (0..5; 5 = spacer)
reg [7:0] r_byte;      // accumulator for the 8-row bits of one column
reg [2:0] r_row_sub;   // row sub-counter for column packing
reg       r_packing;   // 1 = we are accumulating rows for current col

// Counters for page-3 chars: only 16 chars (0..15)
wire [4:0] r_char_max = (r_page == 2'd3) ? 5'd15 : 5'd13;

// ---------------------------------------------------------------------------
// Main render state machine (runs inside ST_RENDER)
// ---------------------------------------------------------------------------
// We drive rom_ch / rom_row combinationally, read rom_bits combinationally.

always @(*) begin
    rom_ch  = char_sel;    // char_sel is combinational on (r_page, r_char)
    rom_row = r_row_sub;
end

// Framebuffer write
reg        fb_we;
reg [8:0]  fb_waddr;
reg [7:0]  fb_wdata;

always @(posedge clk) begin
    if (fb_we)
        fb[fb_waddr] <= fb_wdata;
end

// ---------------------------------------------------------------------------
// Main FSM
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        state      <= ST_INIT;
        init_idx   <= 5'd0;
        addr2_idx  <= 4'd0;
        flush_idx  <= 10'd0;
        wait_ctr   <= {WAIT_BITS{1'b0}};
        i2c_start  <= 1'b0;
        i2c_dcn    <= 1'b0;
        i2c_data   <= 8'h00;
        r_state    <= RS_IDLE;
        r_page     <= 2'd0;
        r_char     <= 5'd0;
        r_col      <= 3'd0;
        r_row_sub  <= 3'd0;
        r_byte     <= 8'h00;
        r_packing  <= 1'b0;
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
        // Defaults
        i2c_start <= 1'b0;
        fb_we     <= 1'b0;

        case (state)

            // =================================================================
            // INIT: send all 18 init commands
            // =================================================================
            ST_INIT: begin
                if (!i2c_busy) begin
                    if (init_idx < INIT_LEN) begin
                        i2c_start <= 1'b1;
                        i2c_dcn   <= 1'b0;          // command
                        i2c_data  <= init_seq[init_idx];
                        init_idx  <= init_idx + 1'b1;
                        state     <= ST_INIT_WAIT;
                    end else begin
                        // Init done — start first render
                        state <= ST_RENDER;
                    end
                end
            end

            ST_INIT_WAIT: begin
                // Wait for i2c_master to go busy (1 cycle), then wait for it to finish
                if (i2c_busy) begin
                    state <= ST_INIT;
                end
            end

            // =================================================================
            // RENDER: build framebuffer from CPU state
            // =================================================================
            ST_RENDER: begin
                case (r_state)

                    RS_IDLE: begin
                        // Snapshot CPU state
                        snap_pc    <= pc;
                        snap_fz    <= flag_z;
                        snap_fc    <= flag_c;
                        snap_fn    <= flag_n;
                        snap_fv    <= flag_v;
                        snap_r7    <= r7;
                        snap_stk   <= stack_top;
                        snap_empty <= stack_empty;
                        snap_halt  <= halted;
                        // Reset render counters
                        r_page    <= 2'd0;
                        r_char    <= 5'd0;
                        r_col     <= 3'd0;
                        r_row_sub <= 3'd0;
                        r_byte    <= 8'h00;
                        r_packing <= 1'b0;
                        r_state   <= RS_FETCH;
                    end

                    RS_FETCH: begin
                        // char_sel is already computed combinationally.
                        // rom_ch/rom_row driven combinationally.
                        // For the spacer column (r_col==5), write 0 directly.
                        if (r_col == 3'd5) begin
                            // Spacer column
                            fb_we    <= 1'b1;
                            fb_waddr <= {r_page, 7'b0} + {2'b00, r_col_base} + 9'd5;
                            fb_wdata <= 8'h00;
                            r_state  <= RS_WRITE;  // advance to next char/page
                        end else begin
                            // Start packing rows for this column
                            r_row_sub <= 3'd0;
                            r_byte    <= 8'h00;
                            r_packing <= 1'b1;
                            r_state   <= RS_ROMWAIT;
                        end
                    end

                    RS_ROMWAIT: begin
                        // rom_bits is combinational — valid this cycle.
                        // Pack bit [4 - r_col] of this row into r_byte.
                        // SSD1306 page format: byte bit 0 = topmost row of the page.
                        // r_row_sub=0 is the top row → bit 0 of the fb byte.
                        case (r_col)
                            3'd0: r_byte[r_row_sub] <= rom_bits[4];
                            3'd1: r_byte[r_row_sub] <= rom_bits[3];
                            3'd2: r_byte[r_row_sub] <= rom_bits[2];
                            3'd3: r_byte[r_row_sub] <= rom_bits[1];
                            3'd4: r_byte[r_row_sub] <= rom_bits[0];
                            default: r_byte[r_row_sub] <= 1'b0;
                        endcase

                        if (r_row_sub == 3'd7) begin
                            // All 8 rows packed — write to fb
                            r_packing <= 1'b0;
                            r_state   <= RS_WRITE;
                        end else begin
                            r_row_sub <= r_row_sub + 1'b1;
                            // Stay in RS_ROMWAIT (combinational rom still valid)
                        end
                    end

                    RS_WRITE: begin
                        // Write packed byte to framebuffer (unless it was the spacer,
                        // which was written in RS_FETCH)
                        if (r_col != 3'd5) begin
                            fb_we    <= 1'b1;
                            fb_waddr <= ({7'b0, r_page} << 7) + {2'b00, r_col_base} + {6'b0, r_col};
                            fb_wdata <= r_byte;
                        end

                        // Advance col → char → page
                        if (r_col == 3'd5) begin
                            r_col <= 3'd0;
                            if (r_char == r_char_max) begin
                                r_char <= 5'd0;
                                if (r_page == 2'd3) begin
                                    // Render complete
                                    r_state <= RS_DONE;
                                end else begin
                                    r_page  <= r_page + 1'b1;
                                    r_state <= RS_FETCH;
                                end
                            end else begin
                                r_char  <= r_char + 1'b1;
                                r_state <= RS_FETCH;
                            end
                        end else begin
                            r_col   <= r_col + 1'b1;
                            r_state <= RS_FETCH;
                        end
                    end

                    RS_DONE: begin
                        r_state   <= RS_IDLE;
                        addr2_idx <= 4'd0;
                        state     <= ST_ADDR_CMD;
                    end

                    default: r_state <= RS_IDLE;
                endcase
            end

            // =================================================================
            // ADDR_CMD: send 8 address-setup commands (horizontal mode, full screen)
            // =================================================================
            ST_ADDR_CMD: begin
                if (!i2c_busy) begin
                    if (addr2_idx < ADDR2_LEN) begin
                        i2c_start <= 1'b1;
                        i2c_dcn   <= 1'b0;
                        i2c_data  <= addr2_seq[addr2_idx];
                        addr2_idx <= addr2_idx + 1'b1;
                        state     <= ST_ADDR_WAIT;
                    end else begin
                        // Send display-on command
                        state <= ST_DISP_ON;
                    end
                end
            end

            ST_ADDR_WAIT: begin
                if (i2c_busy) state <= ST_ADDR_CMD;
            end

            // =================================================================
            // DISP_ON: send 0xAF once per frame
            // =================================================================
            ST_DISP_ON: begin
                if (!i2c_busy) begin
                    i2c_start <= 1'b1;
                    i2c_dcn   <= 1'b0;
                    i2c_data  <= 8'hAF;
                    state     <= ST_DISP_ON_WAIT;
                end
            end

            ST_DISP_ON_WAIT: begin
                if (i2c_busy) begin
                    flush_idx <= 10'd0;
                    state     <= ST_FLUSH;
                end
            end

            // =================================================================
            // FLUSH: stream 512 framebuffer bytes as I2C data
            // =================================================================
            ST_FLUSH: begin
                if (!i2c_busy) begin
                    if (flush_idx < 10'd512) begin
                        i2c_start <= 1'b1;
                        i2c_dcn   <= 1'b1;          // data
                        i2c_data  <= fb[flush_idx[8:0]];
                        flush_idx <= flush_idx + 1'b1;
                        state     <= ST_FLUSH_WAIT;
                    end else begin
                        // Frame done — wait before next refresh
                        wait_ctr <= {WAIT_BITS{1'b0}};
                        state    <= ST_WAIT;
                    end
                end
            end

            ST_FLUSH_WAIT: begin
                if (i2c_busy) state <= ST_FLUSH;
            end

            // =================================================================
            // WAIT: ~100 ms idle before next render
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
