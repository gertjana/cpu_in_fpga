// =============================================================================
// oled_monitor.v — Hardware OLED Debug Monitor for PmodOLED (SSD1306, 128x32)
//
// Clocked entirely from the 12 MHz board clock. The CPU registers and flags
// are read-only inputs — the CPU never has to write to any port to update
// the display.
//
// Display layout (4 lines × 21 characters at 6×8 px per char, 128 px wide):
//   Line 0: "C R0-R3:  XX XX XX XX"  flag C + R0..R3 in hex
//   Line 1: "Z R4-R7:  XX XX XX XX"  flag Z + R4..R7 in hex
//   Line 2: "N PC: XXXX  ST: XX   "  flag N + PC as 4-digit hex + stack depth as 2-digit hex
//   Line 3: "V <PROGRAM_NAME 19c>  " flag V + up to 19-char program name
//
// SPI interface (SSD1306 write-only):
//   spi_clk  — SCLK, derived as clk_12m toggled every cycle → 6 MHz
//   spi_mosi — MOSI (SDIN on PmodOLED)
//   spi_cs_n — Chip Select, active low
//   spi_dc   — Data/Command (1=data, 0=command)
//   spi_res_n — Reset, active low
//   vbat_en  — VBATC: drive low to enable display power  (active low on PMOD)
//   vdd_en   — VDDC: drive low to enable logic power     (active low on PMOD)
//
// PMOD Pin mapping (MAX1000 PMOD header → PmodOLED connector):
//   PMOD Pin 1  PIN_M3  CS
//   PMOD Pin 2  PIN_L3  SDIN (MOSI)
//   PMOD Pin 3  PIN_M2  (unused)
//   PMOD Pin 4  PIN_M1  SCLK
//   PMOD Pin 7  PIN_N3  D/C
//   PMOD Pin 8  PIN_N2  RES
//   PMOD Pin 9  PIN_K2  VBATC
//   PMOD Pin 10 PIN_K1  VDDC
//
// Power-on sequence (from Digilent PmodOLED reference manual):
//   1. VDD on (VDDC low)
//   2. Send Display Off command (0xAE)
//   3. Send init commands
//   4. Clear display RAM
//   5. VBAT on (VBATC low)
//   6. Delay 100 ms
//   7. Send Display On command (0xAF)
//
// After init the module continuously refreshes all 4 text lines using
// the SSD1306 page-addressing mode.
// =============================================================================

module oled_monitor #(
    // Up to 19 ASCII characters for the program name shown on line 3
    // (2 characters are used by the flag letter and a space prefix).
    // Pad with spaces on the right if shorter.
    parameter [151:0] PROG_NAME = "UNKNOWN            "  // 19 chars
) (
    input  wire        clk,        // 12 MHz board clock
    input  wire        rst,        // synchronous reset (active high)

    // Live register values from the CPU register file
    input  wire [7:0]  r0,
    input  wire [7:0]  r1,
    input  wire [7:0]  r2,
    input  wire [7:0]  r3,
    input  wire [7:0]  r4,
    input  wire [7:0]  r5,
    input  wire [7:0]  r6,
    input  wire [7:0]  r7,

    // Live program counter
    input  wire [7:0]  pc,

    // Live stack depth (number of entries currently on the stack, 0..16)
    input  wire [4:0]  stack_depth,

    // Live CPU flags
    input  wire        flag_c,
    input  wire        flag_z,
    input  wire        flag_n,
    input  wire        flag_v,

    // PmodOLED SPI signals
    output reg         spi_cs_n  = 1'b1,  // Chip Select (active low)
    output reg         spi_clk   = 1'b0,  // SPI clock (6 MHz)
    output reg         spi_mosi  = 1'b0,  // MOSI
    output reg         spi_dc    = 1'b0,  // Data(1) / Command(0)
    output reg         spi_res_n = 1'b0,  // Reset (active low) — held in reset at power-on
    output reg         vbat_en = 1'b1,  // VBATC — drive low to power display panel
    output reg         vdd_en  = 1'b1   // VDDC  — drive low to power logic
);

// ---------------------------------------------------------------------------
// Font ROM — 5×7 pixels per glyph, stored as 5 bytes (columns), LSB = top.
// Covers ASCII 0x20 (space) through 0x7E (~). 95 glyphs × 5 bytes = 475 bytes.
// Each byte is one column of 7 pixels: bit0=top row, bit6=bottom row.
//
// Packed localparam: glyph 0 (0x20) in the most-significant 40 bits,
// glyph 94 (0x7E) in the least-significant 40 bits.
// Index = (ascii - 0x20); column byte within glyph = cur_col (0=leftmost).
// Quartus synthesises this as LUT-based ROM identical to a case version.
// ---------------------------------------------------------------------------
localparam [475*8-1:0] FONT_ROM = {
    40'h00_00_00_00_00,  // 0x20 space
    40'h00_00_5F_00_00,  // 0x21 !
    40'h00_07_00_07_00,  // 0x22 "
    40'h14_7F_14_7F_14,  // 0x23 #
    40'h24_2A_7F_2A_12,  // 0x24 $
    40'h23_13_08_64_62,  // 0x25 %
    40'h36_49_55_22_50,  // 0x26 &
    40'h00_05_03_00_00,  // 0x27 '
    40'h00_1C_22_41_00,  // 0x28 (
    40'h00_41_22_1C_00,  // 0x29 )
    40'h14_08_3E_08_14,  // 0x2A *
    40'h08_08_3E_08_08,  // 0x2B +
    40'h00_50_30_00_00,  // 0x2C ,
    40'h08_08_08_08_08,  // 0x2D -
    40'h00_60_60_00_00,  // 0x2E .
    40'h20_10_08_04_02,  // 0x2F /
    40'h3E_51_49_45_3E,  // 0x30 0
    40'h00_42_7F_40_00,  // 0x31 1
    40'h42_61_51_49_46,  // 0x32 2
    40'h21_41_45_4B_31,  // 0x33 3
    40'h18_14_12_7F_10,  // 0x34 4
    40'h27_45_45_45_39,  // 0x35 5
    40'h3C_4A_49_49_30,  // 0x36 6
    40'h01_71_09_05_03,  // 0x37 7
    40'h36_49_49_49_36,  // 0x38 8
    40'h06_49_49_29_1E,  // 0x39 9
    40'h00_36_36_00_00,  // 0x3A :
    40'h00_56_36_00_00,  // 0x3B ;
    40'h08_14_22_41_00,  // 0x3C <
    40'h14_14_14_14_14,  // 0x3D =
    40'h00_41_22_14_08,  // 0x3E >
    40'h02_01_51_09_06,  // 0x3F ?
    40'h32_49_79_41_3E,  // 0x40 @
    40'h7E_11_11_11_7E,  // 0x41 A
    40'h7F_49_49_49_36,  // 0x42 B
    40'h3E_41_41_41_22,  // 0x43 C
    40'h7F_41_41_22_1C,  // 0x44 D
    40'h7F_49_49_49_41,  // 0x45 E
    40'h7F_09_09_09_01,  // 0x46 F
    40'h3E_41_49_49_7A,  // 0x47 G
    40'h7F_08_08_08_7F,  // 0x48 H
    40'h00_41_7F_41_00,  // 0x49 I
    40'h20_40_41_3F_01,  // 0x4A J
    40'h7F_08_14_22_41,  // 0x4B K
    40'h7F_40_40_40_40,  // 0x4C L
    40'h7F_02_0C_02_7F,  // 0x4D M
    40'h7F_04_08_10_7F,  // 0x4E N
    40'h3E_41_41_41_3E,  // 0x4F O
    40'h7F_09_09_09_06,  // 0x50 P
    40'h3E_41_51_21_5E,  // 0x51 Q
    40'h7F_09_19_29_46,  // 0x52 R
    40'h46_49_49_49_31,  // 0x53 S
    40'h01_01_7F_01_01,  // 0x54 T
    40'h3F_40_40_40_3F,  // 0x55 U
    40'h1F_20_40_20_1F,  // 0x56 V
    40'h3F_40_38_40_3F,  // 0x57 W
    40'h63_14_08_14_63,  // 0x58 X
    40'h07_08_70_08_07,  // 0x59 Y
    40'h61_51_49_45_43,  // 0x5A Z
    40'h00_7F_41_41_00,  // 0x5B [
    40'h02_04_08_10_20,  // 0x5C backslash
    40'h00_41_41_7F_00,  // 0x5D ]
    40'h04_02_01_02_04,  // 0x5E ^
    40'h40_40_40_40_40,  // 0x5F _
    40'h00_01_02_04_00,  // 0x60 `
    40'h20_54_54_54_78,  // 0x61 a
    40'h7F_48_44_44_38,  // 0x62 b
    40'h38_44_44_44_20,  // 0x63 c
    40'h38_44_44_48_7F,  // 0x64 d
    40'h38_54_54_54_18,  // 0x65 e
    40'h08_7E_09_01_02,  // 0x66 f
    40'h0C_52_52_52_3E,  // 0x67 g
    40'h7F_08_04_04_78,  // 0x68 h
    40'h00_44_7D_40_00,  // 0x69 i
    40'h20_40_44_3D_00,  // 0x6A j
    40'h7F_10_28_44_00,  // 0x6B k
    40'h00_41_7F_40_00,  // 0x6C l
    40'h7C_04_18_04_78,  // 0x6D m
    40'h7C_08_04_04_78,  // 0x6E n
    40'h38_44_44_44_38,  // 0x6F o
    40'h7C_14_14_14_08,  // 0x70 p
    40'h08_14_14_18_7C,  // 0x71 q
    40'h7C_08_04_04_08,  // 0x72 r
    40'h48_54_54_54_20,  // 0x73 s
    40'h04_3F_44_40_20,  // 0x74 t
    40'h3C_40_40_20_7C,  // 0x75 u
    40'h1C_20_40_20_1C,  // 0x76 v
    40'h3C_40_30_40_3C,  // 0x77 w
    40'h44_28_10_28_44,  // 0x78 x
    40'h0C_50_50_50_3C,  // 0x79 y
    40'h44_64_54_4C_44,  // 0x7A z
    40'h00_08_36_41_00,  // 0x7B {
    40'h00_00_7F_00_00,  // 0x7C |
    40'h00_41_36_08_00,  // 0x7D }
    40'h10_08_08_10_08   // 0x7E ~
};

// ---------------------------------------------------------------------------
// Hex nibble to ASCII — pure combinatorial function used in cur_ascii logic.
// ---------------------------------------------------------------------------
function [7:0] hex_char;
    input [3:0] nibble;
    begin
        hex_char = (nibble < 4'd10) ? (8'h30 + {4'd0, nibble}) : (8'h37 + {4'd0, nibble});
    end
endfunction

// ---------------------------------------------------------------------------
// Delay counter — used throughout the FSM for timed waits.
// At 12 MHz, 1 cycle = 83.3 ns.
//   3 µs   =    36 cycles
//   10 ms  = 120000 cycles
//   100 ms = 1200000 cycles — needs 21 bits
// ---------------------------------------------------------------------------
reg [20:0] delay_ctr;
wire       delay_done = (delay_ctr == 21'd0);

// ---------------------------------------------------------------------------
// SPI shift register — sends 8 bits MSB-first at 6 MHz.
// One SPI bit takes 2 system cycles (clk_high + clk_low).
// Total 8 bits = 16 system cycles.
// ---------------------------------------------------------------------------
reg [7:0]  spi_shift;    // byte currently being shifted out
reg [3:0]  spi_bit_ctr;  // counts from 15 down to 0 (2 cycles per bit)
wire       spi_done = (spi_bit_ctr == 4'd0);

// ---------------------------------------------------------------------------
// Command/data sequence ROM — SSD1306 initialisation sequence.
//
// Format: {is_data[0], byte[7:0]}  — 9 bits per entry; 0=command, 1=data.
// A sentinel of 9'h1FF marks end-of-sequence.
//
// Implemented as a pure combinatorial function so Quartus synthesises it
// as LUT-based ROM with no initial-block dependency.
// ---------------------------------------------------------------------------
localparam SEQ_END  = 9'h1FF;

reg [4:0] seq_idx;
// Current init sequence entry — wire avoids inline bit-select on function calls
wire [8:0] seq_entry = seq_lookup(seq_idx);

function [8:0] seq_lookup;
    input [4:0] idx;
    begin
        case (idx)
            5'd0:  seq_lookup = {1'b0, 8'hAE};  // Display off
            5'd1:  seq_lookup = {1'b0, 8'hD5};  // Set display clock divide
            5'd2:  seq_lookup = {1'b0, 8'h80};  //   ratio/oscillator = 0x80
            5'd3:  seq_lookup = {1'b0, 8'hA8};  // Set multiplex ratio
            5'd4:  seq_lookup = {1'b0, 8'h1F};  //   31 (for 32-row display)
            5'd5:  seq_lookup = {1'b0, 8'hD3};  // Set display offset
            5'd6:  seq_lookup = {1'b0, 8'h00};  //   0
            5'd7:  seq_lookup = {1'b0, 8'h40};  // Set display start line = 0
            5'd8:  seq_lookup = {1'b0, 8'h8D};  // Charge pump setting
            5'd9:  seq_lookup = {1'b0, 8'h14};  //   enable charge pump
            5'd10: seq_lookup = {1'b0, 8'hA1};  // Set segment remap (col 127 = SEG0)
            5'd11: seq_lookup = {1'b0, 8'hC8};  // Set COM scan direction (remapped)
            5'd12: seq_lookup = {1'b0, 8'hDA};  // Set COM pins hardware config
            5'd13: seq_lookup = {1'b0, 8'h02};  //   sequential, no remap (32-row)
            5'd14: seq_lookup = {1'b0, 8'h81};  // Set contrast
            5'd15: seq_lookup = {1'b0, 8'h8F};  //   0x8F
            5'd16: seq_lookup = {1'b0, 8'hD9};  // Set pre-charge period
            5'd17: seq_lookup = {1'b0, 8'hF1};  //   0xF1
            5'd18: seq_lookup = {1'b0, 8'hDB};  // Set VCOMH deselect level
            5'd19: seq_lookup = {1'b0, 8'h40};  //   0x40
            5'd20: seq_lookup = {1'b0, 8'hA4};  // Entire display ON (normal)
            5'd21: seq_lookup = {1'b0, 8'hA6};  // Normal display (not inverted)
            5'd22: seq_lookup = {1'b0, 8'h20};  // Set memory addressing mode
            5'd23: seq_lookup = {1'b0, 8'h02};  //   page addressing
            default: seq_lookup = SEQ_END;       // Display ON sent separately after VBAT delay
        endcase
    end
endfunction

// ---------------------------------------------------------------------------
// Main FSM
// ---------------------------------------------------------------------------
// Power-on sequence (matches Digilent PmodOLED reference driver):
//   1. VDD on (VDDC low)                          — ST_VDD_ON
//   2. Wait 1 ms for VDD to stabilise             — ST_VDD_WAIT
//   3. Release RES (high) for 1 ms                — ST_RES_HIGH
//   4. Send Display Off (0xAE)                    — (first entry in seq_lookup)
//   5. Assert RES (low) for 1 ms                  — ST_RESET
//   6. Release RES (high)                         — ST_RESET_WAIT
//   7. Send init sequence                         — ST_INIT_START / ST_INIT_WAIT
//   8. VBAT on (VBATC low)                        — ST_VBAT_ON
//   9. Wait 100 ms                                — ST_VBAT_WAIT
//  10. Send Display On (0xAF)                     — ST_DISP_ON / ST_DISP_WAIT
//  11. Continuously refresh all 4 text lines      — ST_REFRESH_START … ST_DONE
// ---------------------------------------------------------------------------
localparam [4:0]
    ST_VDD_ON       = 5'd0,   // enable VDD logic power  (first state at power-up)
    ST_VDD_WAIT     = 5'd1,   // wait 1 ms for VDD stable
    ST_RES_HIGH     = 5'd2,   // release RES for 1 ms (SSD1306 sees rising edge)
    ST_RESET        = 5'd3,   // drive RES low again for 1 ms (proper reset pulse)
    ST_RESET_WAIT   = 5'd4,   // release RES, wait for SSD1306 to come out of reset
    ST_INIT_START   = 5'd5,   // begin sending init sequence
    ST_INIT_SEND    = 5'd6,   // (unused — kept for numbering continuity)
    ST_INIT_WAIT    = 5'd7,   // wait for SPI to finish
    ST_INIT_NEXT    = 5'd8,   // (unused)
    ST_VBAT_ON      = 5'd9,   // enable VBAT display power
    ST_VBAT_WAIT    = 5'd10,  // wait 100 ms
    ST_DISP_ON      = 5'd11,  // send Display On command (0xAF)
    ST_DISP_WAIT    = 5'd12,  // wait for Display On SPI to finish
    ST_REFRESH_START= 5'd13,  // begin screen refresh: rebuild text buffer
    ST_PAGE_CMD     = 5'd14,  // send page-set command sequence
    ST_PAGE_WAIT    = 5'd15,  // wait for SPI
    ST_COL_DATA     = 5'd16,  // send one column of font data
    ST_COL_WAIT     = 5'd17,  // wait for SPI
    ST_NEXT_COL     = 5'd18,  // advance column / character / line
    ST_DONE         = 5'd19;  // loop back to refresh

reg [4:0] state;

// Refresh position tracking
reg [1:0] cur_line;     // 0-3
reg [4:0] cur_char;     // 0-20 (21 chars per line)
reg [2:0] cur_col;      // 0-5  (5 font cols + 1 space col per char)

// Page-command sub-sequence: 3 SPI bytes to set page + col address
// ST_PAGE_CMD sends: 0xB0|page, 0x00, 0x10
reg [1:0] page_cmd_idx;

// ---------------------------------------------------------------------------
// Power-on reset is handled by two complementary mechanisms:
//   1. Inline initial values on output registers:
//        vdd_en=1, vbat_en=1 (both supplies OFF — prevents VBAT before VDD)
//        spi_cs_n=1 (CS deasserted), spi_res_n=0 (display held in reset)
//      Quartus synthesises inline `= value` initial values for simple scalar
//      registers as the FF power-up state, reliably and independently of the
//      synchronous reset path.
//   2. The synchronous rst input (driven by a 32-cycle POR counter in top.v)
//      drives all FSM state to known values within 3 µs of configuration.
// Together these ensure correct power sequencing even if the POR counter
// itself powers up in an unexpected state.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Combinatorial ASCII character lookup — no register array, no tasks.
// Computed directly from cur_line, cur_char and live CPU inputs.
//
// Layout (21 chars per line, 0-indexed):
//   Line 0: "C R0-R3:  XX XX XX XX"
//   Line 1: "Z R4-R7:  XX XX XX XX"
//   Line 2: "N PC:     XXXX       "
//   Line 3: "V <PROG_NAME 19 chars>"
// ---------------------------------------------------------------------------
reg [7:0] cur_ascii;

always @(*) begin
    case (cur_line)
        // --- Line 0: "C R0-R3:  XX XX XX XX" ---
        2'd0: begin
            case (cur_char)
                5'd0:  cur_ascii = flag_c ? "C" : " ";
                5'd1:  cur_ascii = " ";
                5'd2:  cur_ascii = "R";
                5'd3:  cur_ascii = "0";
                5'd4:  cur_ascii = "-";
                5'd5:  cur_ascii = "R";
                5'd6:  cur_ascii = "3";
                5'd7:  cur_ascii = ":";
                5'd8:  cur_ascii = " ";
                5'd9:  cur_ascii = " ";
                5'd10: cur_ascii = hex_char(r0[7:4]);
                5'd11: cur_ascii = hex_char(r0[3:0]);
                5'd12: cur_ascii = " ";
                5'd13: cur_ascii = hex_char(r1[7:4]);
                5'd14: cur_ascii = hex_char(r1[3:0]);
                5'd15: cur_ascii = " ";
                5'd16: cur_ascii = hex_char(r2[7:4]);
                5'd17: cur_ascii = hex_char(r2[3:0]);
                5'd18: cur_ascii = " ";
                5'd19: cur_ascii = hex_char(r3[7:4]);
                5'd20: cur_ascii = hex_char(r3[3:0]);
                default: cur_ascii = " ";
            endcase
        end
        // --- Line 1: "Z R4-R7:  XX XX XX XX" ---
        2'd1: begin
            case (cur_char)
                5'd0:  cur_ascii = flag_z ? "Z" : " ";
                5'd1:  cur_ascii = " ";
                5'd2:  cur_ascii = "R";
                5'd3:  cur_ascii = "4";
                5'd4:  cur_ascii = "-";
                5'd5:  cur_ascii = "R";
                5'd6:  cur_ascii = "7";
                5'd7:  cur_ascii = ":";
                5'd8:  cur_ascii = " ";
                5'd9:  cur_ascii = " ";
                5'd10: cur_ascii = hex_char(r4[7:4]);
                5'd11: cur_ascii = hex_char(r4[3:0]);
                5'd12: cur_ascii = " ";
                5'd13: cur_ascii = hex_char(r5[7:4]);
                5'd14: cur_ascii = hex_char(r5[3:0]);
                5'd15: cur_ascii = " ";
                5'd16: cur_ascii = hex_char(r6[7:4]);
                5'd17: cur_ascii = hex_char(r6[3:0]);
                5'd18: cur_ascii = " ";
                5'd19: cur_ascii = hex_char(r7[7:4]);
                5'd20: cur_ascii = hex_char(r7[3:0]);
                default: cur_ascii = " ";
            endcase
        end
        // --- Line 2: "N PC: XXXX  ST: XX   " ---
        2'd2: begin
            case (cur_char)
                5'd0:  cur_ascii = flag_n ? "N" : " ";
                5'd1:  cur_ascii = " ";
                5'd2:  cur_ascii = "P";
                5'd3:  cur_ascii = "C";
                5'd4:  cur_ascii = ":";
                5'd5:  cur_ascii = " ";
                5'd6:  cur_ascii = "0";   // PC is 8-bit, zero-pad to 4 digits
                5'd7:  cur_ascii = "0";
                5'd8:  cur_ascii = hex_char(pc[7:4]);
                5'd9:  cur_ascii = hex_char(pc[3:0]);
                5'd10: cur_ascii = " ";
                5'd11: cur_ascii = " ";
                5'd12: cur_ascii = "S";
                5'd13: cur_ascii = "T";
                5'd14: cur_ascii = ":";
                5'd15: cur_ascii = " ";
                5'd16: cur_ascii = hex_char({3'b0, stack_depth[4]});
                5'd17: cur_ascii = hex_char(stack_depth[3:0]);
                default: cur_ascii = " ";
            endcase
        end
        // --- Line 3: "V <PROG_NAME 19 chars>" ---
        default: begin
            case (cur_char)
                5'd0:  cur_ascii = flag_v ? "V" : " ";
                5'd1:  cur_ascii = " ";
                5'd2:  cur_ascii = PROG_NAME[151:144];
                5'd3:  cur_ascii = PROG_NAME[143:136];
                5'd4:  cur_ascii = PROG_NAME[135:128];
                5'd5:  cur_ascii = PROG_NAME[127:120];
                5'd6:  cur_ascii = PROG_NAME[119:112];
                5'd7:  cur_ascii = PROG_NAME[111:104];
                5'd8:  cur_ascii = PROG_NAME[103:96];
                5'd9:  cur_ascii = PROG_NAME[95:88];
                5'd10: cur_ascii = PROG_NAME[87:80];
                5'd11: cur_ascii = PROG_NAME[79:72];
                5'd12: cur_ascii = PROG_NAME[71:64];
                5'd13: cur_ascii = PROG_NAME[63:56];
                5'd14: cur_ascii = PROG_NAME[55:48];
                5'd15: cur_ascii = PROG_NAME[47:40];
                5'd16: cur_ascii = PROG_NAME[39:32];
                5'd17: cur_ascii = PROG_NAME[31:24];
                5'd18: cur_ascii = PROG_NAME[23:16];
                5'd19: cur_ascii = PROG_NAME[15:8];
                5'd20: cur_ascii = PROG_NAME[7:0];
                default: cur_ascii = " ";
            endcase
        end
    endcase
end

// Font ROM address: (ascii - 0x20) * 5 + cur_col
// Max address: (0x7E-0x20)*5 + 4 = 94*5 + 4 = 474, fits in 9 bits.
// Use 9-bit arithmetic throughout to avoid Quartus truncation warning.
// FONT_ROM is packed MSB-first: glyph 0 at the top, so byte at index i is
// bits [(474-i)*8 +: 8].
wire [8:0] font_ascii9 = {1'b0, cur_ascii} - 9'h020;
wire [8:0] font_addr   = font_ascii9 * 9'd5 + {6'd0, cur_col[2:0]};
// Column 5, 6, 7 are inter-character gap / padding — always 0x00
wire [7:0] font_byte  = (cur_col >= 3'd5) ? 8'h00 : FONT_ROM[(474 - font_addr) * 8 +: 8];

// Helper: start an SPI transaction
task spi_send;
    input [7:0] byte_val;
    input       is_data;
    begin
        spi_dc    <= is_data;
        spi_cs_n  <= 1'b0;
        spi_shift <= byte_val;
        spi_bit_ctr <= 4'd15;
    end
endtask

always @(posedge clk) begin
    if (rst) begin
        state       <= ST_VDD_ON;  // ST_VDD_ON=5'd0 is the first state
        spi_cs_n    <= 1'b1;
        spi_clk     <= 1'b0;
        spi_mosi    <= 1'b0;
        spi_dc      <= 1'b0;
        spi_res_n   <= 1'b0;
        vbat_en     <= 1'b1;   // VBATC high = display power OFF
        vdd_en      <= 1'b1;   // VDDC  high = logic  power OFF
        delay_ctr   <= 21'd0;
        spi_bit_ctr <= 4'd0;
        seq_idx     <= 5'd0;
        cur_line    <= 2'd0;
        cur_char    <= 5'd0;
        cur_col     <= 3'd0;
        page_cmd_idx<= 2'd0;
    end else begin

        // ---------------------------------------------------------------
        // SPI clock & shift engine — runs independently of FSM state.
        // When spi_bit_ctr > 0, we are mid-transaction.
        // ---------------------------------------------------------------
        if (!spi_done) begin
            // Toggle SPI clock every system cycle
            spi_clk <= ~spi_clk;
            if (spi_clk == 1'b0) begin
                // Rising edge: present next bit (MSB first)
                spi_mosi    <= spi_shift[7];
                spi_shift   <= {spi_shift[6:0], 1'b0};
            end
            spi_bit_ctr <= spi_bit_ctr - 4'd1;
        end else begin
            spi_clk <= 1'b0;
            // De-assert CS after each byte (FSM controls when to re-assert)
            spi_cs_n <= 1'b1;
        end

        // ---------------------------------------------------------------
        // FSM
        // ---------------------------------------------------------------
        case (state)

            // --- Power on VDD (logic), keep RES low during ramp ---
            ST_VDD_ON: begin
                vdd_en    <= 1'b0;          // VDDC low = power ON
                spi_res_n <= 1'b0;          // hold RES low during power ramp
                delay_ctr <= 21'd12_000;    // 1 ms at 12 MHz
                state     <= ST_VDD_WAIT;
            end

            ST_VDD_WAIT: begin
                if (!delay_done)
                    delay_ctr <= delay_ctr - 21'd1;
                else begin
                    // VDD stable — release RES high briefly
                    spi_res_n <= 1'b1;
                    delay_ctr <= 21'd12_000; // 1 ms
                    state     <= ST_RES_HIGH;
                end
            end

            // --- RES high for 1 ms, then pulse low for 1 ms ---
            ST_RES_HIGH: begin
                if (!delay_done)
                    delay_ctr <= delay_ctr - 21'd1;
                else begin
                    spi_res_n <= 1'b0;      // assert RES low
                    delay_ctr <= 21'd12_000; // 1 ms
                    state     <= ST_RESET;
                end
            end

            // --- Apply reset pulse to SSD1306 ---
            ST_RESET: begin
                if (!delay_done)
                    delay_ctr <= delay_ctr - 21'd1;
                else begin
                    spi_res_n <= 1'b1;      // release RES
                    delay_ctr <= 21'd12_000; // 1 ms settle
                    state     <= ST_RESET_WAIT;
                end
            end

            ST_RESET_WAIT: begin
                if (!delay_done)
                    delay_ctr <= delay_ctr - 21'd1;
                else begin
                    seq_idx <= 5'd0;
                    state   <= ST_INIT_START;
                end
            end

            // --- Send init sequence (all commands up to but not including Display On) ---
            ST_INIT_START: begin
                if (seq_entry == SEQ_END) begin
                    // Reached end of sequence — move on
                    state <= ST_VBAT_ON;
                end else begin
                    spi_send(seq_entry[7:0], seq_entry[8]);
                    state <= ST_INIT_WAIT;
                end
            end

            ST_INIT_WAIT: begin
                if (spi_done) begin
                    seq_idx <= seq_idx + 5'd1;
                    state   <= ST_INIT_START;
                end
            end

            // --- Power on VBAT (display panel) ---
            ST_VBAT_ON: begin
                vbat_en   <= 1'b0;          // VBATC low = power ON
                delay_ctr <= 21'd1_200_000; // 100 ms
                state     <= ST_VBAT_WAIT;
            end

            ST_VBAT_WAIT: begin
                if (!delay_done)
                    delay_ctr <= delay_ctr - 21'd1;
                else
                    state <= ST_DISP_ON;
            end

            // --- Send Display On command (0xAF) after VBAT + 100 ms delay ---
            ST_DISP_ON: begin
                spi_send(8'hAF, 1'b0);  // Display ON, DC=0 (command)
                state <= ST_DISP_WAIT;
            end

            ST_DISP_WAIT: begin
                if (spi_done)
                    state <= ST_REFRESH_START;
            end

            // --- Begin a fresh screen refresh cycle ---
            ST_REFRESH_START: begin
                // cur_ascii is now purely combinatorial from cur_line/cur_char,
                // so no text buffer snapshot is needed — just reset scan position.
                cur_line     <= 2'd0;
                cur_char     <= 5'd0;
                cur_col      <= 3'd0;
                page_cmd_idx <= 2'd0;
                state        <= ST_PAGE_CMD;
            end

            // --- Set page address (3 bytes: 0xB0|page, 0x00, 0x10) ---
            ST_PAGE_CMD: begin
                case (page_cmd_idx)
                    2'd0: spi_send(8'hB0 | {6'd0, cur_line}, 1'b0);
                    2'd1: spi_send(8'h00, 1'b0);   // lower nibble of col start
                    2'd2: spi_send(8'h10, 1'b0);   // upper nibble of col start
                    default: ; // unreachable
                endcase
                state <= ST_PAGE_WAIT;
            end

            ST_PAGE_WAIT: begin
                if (spi_done) begin
                    if (page_cmd_idx == 2'd2) begin
                        page_cmd_idx <= 2'd0;
                        spi_dc       <= 1'b1;  // pre-set DC=data one cycle before CS falls
                        state        <= ST_COL_DATA;
                    end else begin
                        page_cmd_idx <= page_cmd_idx + 2'd1;
                        state <= ST_PAGE_CMD;
                    end
                end
            end

            // --- Send one column byte of font data ---
            ST_COL_DATA: begin
                spi_send(font_byte, 1'b1);   // DC=1: data
                state <= ST_COL_WAIT;
            end

            ST_COL_WAIT: begin
                if (spi_done)
                    state <= ST_NEXT_COL;
            end

            // --- Advance position: col → char → line → next refresh ---
            ST_NEXT_COL: begin
                // The last character (char 20) gets 2 extra zero-byte padding
                // columns (indices 6 and 7) so that all 128 display columns are
                // written and the 2 rightmost GDDRAM cells are cleared.
                // font_byte already returns 0x00 for cur_col >= 5, so no extra
                // logic is needed for the data value.
                // Total per line: 20 chars × 6 cols + 1 char × 8 cols = 128.
                if (cur_col == (cur_char == 5'd20 ? 3'd7 : 3'd5)) begin
                    // Finished all columns of this character
                    cur_col <= 3'd0;
                    if (cur_char == 5'd20) begin
                        // Finished all 21 chars on this line (128 columns sent)
                        cur_char <= 5'd0;
                        if (cur_line == 2'd3) begin
                            // Finished all 4 lines — restart refresh
                            state <= ST_REFRESH_START;
                        end else begin
                            cur_line     <= cur_line + 2'd1;
                            page_cmd_idx <= 2'd0;
                            state        <= ST_PAGE_CMD;
                        end
                    end else begin
                        cur_char <= cur_char + 5'd1;
                        state    <= ST_COL_DATA;
                    end
                end else begin
                    cur_col <= cur_col + 3'd1;
                    state   <= ST_COL_DATA;
                end
            end

            default: state <= ST_RESET;

        endcase
    end
end

endmodule
