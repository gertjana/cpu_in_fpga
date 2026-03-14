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
//   Line 2: "N PC:     XXXX         " flag N + PC as 4-digit hex
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

    // Live CPU flags
    input  wire        flag_c,
    input  wire        flag_z,
    input  wire        flag_n,
    input  wire        flag_v,

    // PmodOLED SPI signals
    output reg         spi_cs_n,   // Chip Select (active low)
    output reg         spi_clk,    // SPI clock (6 MHz)
    output reg         spi_mosi,   // MOSI
    output reg         spi_dc,     // Data(1) / Command(0)
    output reg         spi_res_n,  // Reset (active low)
    output reg         vbat_en,    // VBATC — drive low to power display panel
    output reg         vdd_en      // VDDC  — drive low to power logic
);

// ---------------------------------------------------------------------------
// Font ROM — 5×7 pixels per glyph, stored as 5 bytes (columns), LSB = top.
// Covers ASCII 0x20 (space) through 0x7E (~). Index = ascii - 0x20.
// Each byte is one column of 7 pixels: bit0=top row, bit6=bottom row.
//
// Implemented as a pure combinatorial function (case statement) so that
// Quartus synthesises it as LUT-based ROM with no initial-block dependency.
// ---------------------------------------------------------------------------
function [7:0] font_lookup;
    input [8:0] addr;
    begin
        case (addr)
            // 0x20 space
            9'd0:  font_lookup=8'h00; 9'd1:  font_lookup=8'h00;
            9'd2:  font_lookup=8'h00; 9'd3:  font_lookup=8'h00; 9'd4:  font_lookup=8'h00;
            // 0x21 !
            9'd5:  font_lookup=8'h00; 9'd6:  font_lookup=8'h00;
            9'd7:  font_lookup=8'h5F; 9'd8:  font_lookup=8'h00; 9'd9:  font_lookup=8'h00;
            // 0x22 "
            9'd10: font_lookup=8'h00; 9'd11: font_lookup=8'h07;
            9'd12: font_lookup=8'h00; 9'd13: font_lookup=8'h07; 9'd14: font_lookup=8'h00;
            // 0x23 #
            9'd15: font_lookup=8'h14; 9'd16: font_lookup=8'h7F;
            9'd17: font_lookup=8'h14; 9'd18: font_lookup=8'h7F; 9'd19: font_lookup=8'h14;
            // 0x24 $
            9'd20: font_lookup=8'h24; 9'd21: font_lookup=8'h2A;
            9'd22: font_lookup=8'h7F; 9'd23: font_lookup=8'h2A; 9'd24: font_lookup=8'h12;
            // 0x25 %
            9'd25: font_lookup=8'h23; 9'd26: font_lookup=8'h13;
            9'd27: font_lookup=8'h08; 9'd28: font_lookup=8'h64; 9'd29: font_lookup=8'h62;
            // 0x26 &
            9'd30: font_lookup=8'h36; 9'd31: font_lookup=8'h49;
            9'd32: font_lookup=8'h55; 9'd33: font_lookup=8'h22; 9'd34: font_lookup=8'h50;
            // 0x27 '
            9'd35: font_lookup=8'h00; 9'd36: font_lookup=8'h05;
            9'd37: font_lookup=8'h03; 9'd38: font_lookup=8'h00; 9'd39: font_lookup=8'h00;
            // 0x28 (
            9'd40: font_lookup=8'h00; 9'd41: font_lookup=8'h1C;
            9'd42: font_lookup=8'h22; 9'd43: font_lookup=8'h41; 9'd44: font_lookup=8'h00;
            // 0x29 )
            9'd45: font_lookup=8'h00; 9'd46: font_lookup=8'h41;
            9'd47: font_lookup=8'h22; 9'd48: font_lookup=8'h1C; 9'd49: font_lookup=8'h00;
            // 0x2A *
            9'd50: font_lookup=8'h14; 9'd51: font_lookup=8'h08;
            9'd52: font_lookup=8'h3E; 9'd53: font_lookup=8'h08; 9'd54: font_lookup=8'h14;
            // 0x2B +
            9'd55: font_lookup=8'h08; 9'd56: font_lookup=8'h08;
            9'd57: font_lookup=8'h3E; 9'd58: font_lookup=8'h08; 9'd59: font_lookup=8'h08;
            // 0x2C ,
            9'd60: font_lookup=8'h00; 9'd61: font_lookup=8'h50;
            9'd62: font_lookup=8'h30; 9'd63: font_lookup=8'h00; 9'd64: font_lookup=8'h00;
            // 0x2D -
            9'd65: font_lookup=8'h08; 9'd66: font_lookup=8'h08;
            9'd67: font_lookup=8'h08; 9'd68: font_lookup=8'h08; 9'd69: font_lookup=8'h08;
            // 0x2E .
            9'd70: font_lookup=8'h00; 9'd71: font_lookup=8'h60;
            9'd72: font_lookup=8'h60; 9'd73: font_lookup=8'h00; 9'd74: font_lookup=8'h00;
            // 0x2F /
            9'd75: font_lookup=8'h20; 9'd76: font_lookup=8'h10;
            9'd77: font_lookup=8'h08; 9'd78: font_lookup=8'h04; 9'd79: font_lookup=8'h02;
            // 0x30 0
            9'd80: font_lookup=8'h3E; 9'd81: font_lookup=8'h51;
            9'd82: font_lookup=8'h49; 9'd83: font_lookup=8'h45; 9'd84: font_lookup=8'h3E;
            // 0x31 1
            9'd85: font_lookup=8'h00; 9'd86: font_lookup=8'h42;
            9'd87: font_lookup=8'h7F; 9'd88: font_lookup=8'h40; 9'd89: font_lookup=8'h00;
            // 0x32 2
            9'd90: font_lookup=8'h42; 9'd91: font_lookup=8'h61;
            9'd92: font_lookup=8'h51; 9'd93: font_lookup=8'h49; 9'd94: font_lookup=8'h46;
            // 0x33 3
            9'd95: font_lookup=8'h21; 9'd96: font_lookup=8'h41;
            9'd97: font_lookup=8'h45; 9'd98: font_lookup=8'h4B; 9'd99: font_lookup=8'h31;
            // 0x34 4
            9'd100: font_lookup=8'h18; 9'd101: font_lookup=8'h14;
            9'd102: font_lookup=8'h12; 9'd103: font_lookup=8'h7F; 9'd104: font_lookup=8'h10;
            // 0x35 5
            9'd105: font_lookup=8'h27; 9'd106: font_lookup=8'h45;
            9'd107: font_lookup=8'h45; 9'd108: font_lookup=8'h45; 9'd109: font_lookup=8'h39;
            // 0x36 6
            9'd110: font_lookup=8'h3C; 9'd111: font_lookup=8'h4A;
            9'd112: font_lookup=8'h49; 9'd113: font_lookup=8'h49; 9'd114: font_lookup=8'h30;
            // 0x37 7
            9'd115: font_lookup=8'h01; 9'd116: font_lookup=8'h71;
            9'd117: font_lookup=8'h09; 9'd118: font_lookup=8'h05; 9'd119: font_lookup=8'h03;
            // 0x38 8
            9'd120: font_lookup=8'h36; 9'd121: font_lookup=8'h49;
            9'd122: font_lookup=8'h49; 9'd123: font_lookup=8'h49; 9'd124: font_lookup=8'h36;
            // 0x39 9
            9'd125: font_lookup=8'h06; 9'd126: font_lookup=8'h49;
            9'd127: font_lookup=8'h49; 9'd128: font_lookup=8'h29; 9'd129: font_lookup=8'h1E;
            // 0x3A :
            9'd130: font_lookup=8'h00; 9'd131: font_lookup=8'h36;
            9'd132: font_lookup=8'h36; 9'd133: font_lookup=8'h00; 9'd134: font_lookup=8'h00;
            // 0x3B ;
            9'd135: font_lookup=8'h00; 9'd136: font_lookup=8'h56;
            9'd137: font_lookup=8'h36; 9'd138: font_lookup=8'h00; 9'd139: font_lookup=8'h00;
            // 0x3C <
            9'd140: font_lookup=8'h08; 9'd141: font_lookup=8'h14;
            9'd142: font_lookup=8'h22; 9'd143: font_lookup=8'h41; 9'd144: font_lookup=8'h00;
            // 0x3D =
            9'd145: font_lookup=8'h14; 9'd146: font_lookup=8'h14;
            9'd147: font_lookup=8'h14; 9'd148: font_lookup=8'h14; 9'd149: font_lookup=8'h14;
            // 0x3E >
            9'd150: font_lookup=8'h00; 9'd151: font_lookup=8'h41;
            9'd152: font_lookup=8'h22; 9'd153: font_lookup=8'h14; 9'd154: font_lookup=8'h08;
            // 0x3F ?
            9'd155: font_lookup=8'h02; 9'd156: font_lookup=8'h01;
            9'd157: font_lookup=8'h51; 9'd158: font_lookup=8'h09; 9'd159: font_lookup=8'h06;
            // 0x40 @
            9'd160: font_lookup=8'h32; 9'd161: font_lookup=8'h49;
            9'd162: font_lookup=8'h79; 9'd163: font_lookup=8'h41; 9'd164: font_lookup=8'h3E;
            // 0x41 A
            9'd165: font_lookup=8'h7E; 9'd166: font_lookup=8'h11;
            9'd167: font_lookup=8'h11; 9'd168: font_lookup=8'h11; 9'd169: font_lookup=8'h7E;
            // 0x42 B
            9'd170: font_lookup=8'h7F; 9'd171: font_lookup=8'h49;
            9'd172: font_lookup=8'h49; 9'd173: font_lookup=8'h49; 9'd174: font_lookup=8'h36;
            // 0x43 C
            9'd175: font_lookup=8'h3E; 9'd176: font_lookup=8'h41;
            9'd177: font_lookup=8'h41; 9'd178: font_lookup=8'h41; 9'd179: font_lookup=8'h22;
            // 0x44 D
            9'd180: font_lookup=8'h7F; 9'd181: font_lookup=8'h41;
            9'd182: font_lookup=8'h41; 9'd183: font_lookup=8'h22; 9'd184: font_lookup=8'h1C;
            // 0x45 E
            9'd185: font_lookup=8'h7F; 9'd186: font_lookup=8'h49;
            9'd187: font_lookup=8'h49; 9'd188: font_lookup=8'h49; 9'd189: font_lookup=8'h41;
            // 0x46 F
            9'd190: font_lookup=8'h7F; 9'd191: font_lookup=8'h09;
            9'd192: font_lookup=8'h09; 9'd193: font_lookup=8'h09; 9'd194: font_lookup=8'h01;
            // 0x47 G
            9'd195: font_lookup=8'h3E; 9'd196: font_lookup=8'h41;
            9'd197: font_lookup=8'h49; 9'd198: font_lookup=8'h49; 9'd199: font_lookup=8'h7A;
            // 0x48 H
            9'd200: font_lookup=8'h7F; 9'd201: font_lookup=8'h08;
            9'd202: font_lookup=8'h08; 9'd203: font_lookup=8'h08; 9'd204: font_lookup=8'h7F;
            // 0x49 I
            9'd205: font_lookup=8'h00; 9'd206: font_lookup=8'h41;
            9'd207: font_lookup=8'h7F; 9'd208: font_lookup=8'h41; 9'd209: font_lookup=8'h00;
            // 0x4A J
            9'd210: font_lookup=8'h20; 9'd211: font_lookup=8'h40;
            9'd212: font_lookup=8'h41; 9'd213: font_lookup=8'h3F; 9'd214: font_lookup=8'h01;
            // 0x4B K
            9'd215: font_lookup=8'h7F; 9'd216: font_lookup=8'h08;
            9'd217: font_lookup=8'h14; 9'd218: font_lookup=8'h22; 9'd219: font_lookup=8'h41;
            // 0x4C L
            9'd220: font_lookup=8'h7F; 9'd221: font_lookup=8'h40;
            9'd222: font_lookup=8'h40; 9'd223: font_lookup=8'h40; 9'd224: font_lookup=8'h40;
            // 0x4D M
            9'd225: font_lookup=8'h7F; 9'd226: font_lookup=8'h02;
            9'd227: font_lookup=8'h0C; 9'd228: font_lookup=8'h02; 9'd229: font_lookup=8'h7F;
            // 0x4E N
            9'd230: font_lookup=8'h7F; 9'd231: font_lookup=8'h04;
            9'd232: font_lookup=8'h08; 9'd233: font_lookup=8'h10; 9'd234: font_lookup=8'h7F;
            // 0x4F O
            9'd235: font_lookup=8'h3E; 9'd236: font_lookup=8'h41;
            9'd237: font_lookup=8'h41; 9'd238: font_lookup=8'h41; 9'd239: font_lookup=8'h3E;
            // 0x50 P
            9'd240: font_lookup=8'h7F; 9'd241: font_lookup=8'h09;
            9'd242: font_lookup=8'h09; 9'd243: font_lookup=8'h09; 9'd244: font_lookup=8'h06;
            // 0x51 Q
            9'd245: font_lookup=8'h3E; 9'd246: font_lookup=8'h41;
            9'd247: font_lookup=8'h51; 9'd248: font_lookup=8'h21; 9'd249: font_lookup=8'h5E;
            // 0x52 R
            9'd250: font_lookup=8'h7F; 9'd251: font_lookup=8'h09;
            9'd252: font_lookup=8'h19; 9'd253: font_lookup=8'h29; 9'd254: font_lookup=8'h46;
            // 0x53 S
            9'd255: font_lookup=8'h46; 9'd256: font_lookup=8'h49;
            9'd257: font_lookup=8'h49; 9'd258: font_lookup=8'h49; 9'd259: font_lookup=8'h31;
            // 0x54 T
            9'd260: font_lookup=8'h01; 9'd261: font_lookup=8'h01;
            9'd262: font_lookup=8'h7F; 9'd263: font_lookup=8'h01; 9'd264: font_lookup=8'h01;
            // 0x55 U
            9'd265: font_lookup=8'h3F; 9'd266: font_lookup=8'h40;
            9'd267: font_lookup=8'h40; 9'd268: font_lookup=8'h40; 9'd269: font_lookup=8'h3F;
            // 0x56 V
            9'd270: font_lookup=8'h1F; 9'd271: font_lookup=8'h20;
            9'd272: font_lookup=8'h40; 9'd273: font_lookup=8'h20; 9'd274: font_lookup=8'h1F;
            // 0x57 W
            9'd275: font_lookup=8'h3F; 9'd276: font_lookup=8'h40;
            9'd277: font_lookup=8'h38; 9'd278: font_lookup=8'h40; 9'd279: font_lookup=8'h3F;
            // 0x58 X
            9'd280: font_lookup=8'h63; 9'd281: font_lookup=8'h14;
            9'd282: font_lookup=8'h08; 9'd283: font_lookup=8'h14; 9'd284: font_lookup=8'h63;
            // 0x59 Y
            9'd285: font_lookup=8'h07; 9'd286: font_lookup=8'h08;
            9'd287: font_lookup=8'h70; 9'd288: font_lookup=8'h08; 9'd289: font_lookup=8'h07;
            // 0x5A Z
            9'd290: font_lookup=8'h61; 9'd291: font_lookup=8'h51;
            9'd292: font_lookup=8'h49; 9'd293: font_lookup=8'h45; 9'd294: font_lookup=8'h43;
            // 0x5B [
            9'd295: font_lookup=8'h00; 9'd296: font_lookup=8'h7F;
            9'd297: font_lookup=8'h41; 9'd298: font_lookup=8'h41; 9'd299: font_lookup=8'h00;
            // 0x5C backslash
            9'd300: font_lookup=8'h02; 9'd301: font_lookup=8'h04;
            9'd302: font_lookup=8'h08; 9'd303: font_lookup=8'h10; 9'd304: font_lookup=8'h20;
            // 0x5D ]
            9'd305: font_lookup=8'h00; 9'd306: font_lookup=8'h41;
            9'd307: font_lookup=8'h41; 9'd308: font_lookup=8'h7F; 9'd309: font_lookup=8'h00;
            // 0x5E ^
            9'd310: font_lookup=8'h04; 9'd311: font_lookup=8'h02;
            9'd312: font_lookup=8'h01; 9'd313: font_lookup=8'h02; 9'd314: font_lookup=8'h04;
            // 0x5F _
            9'd315: font_lookup=8'h40; 9'd316: font_lookup=8'h40;
            9'd317: font_lookup=8'h40; 9'd318: font_lookup=8'h40; 9'd319: font_lookup=8'h40;
            // 0x60 `
            9'd320: font_lookup=8'h00; 9'd321: font_lookup=8'h01;
            9'd322: font_lookup=8'h02; 9'd323: font_lookup=8'h04; 9'd324: font_lookup=8'h00;
            // 0x61 a
            9'd325: font_lookup=8'h20; 9'd326: font_lookup=8'h54;
            9'd327: font_lookup=8'h54; 9'd328: font_lookup=8'h54; 9'd329: font_lookup=8'h78;
            // 0x62 b
            9'd330: font_lookup=8'h7F; 9'd331: font_lookup=8'h48;
            9'd332: font_lookup=8'h44; 9'd333: font_lookup=8'h44; 9'd334: font_lookup=8'h38;
            // 0x63 c
            9'd335: font_lookup=8'h38; 9'd336: font_lookup=8'h44;
            9'd337: font_lookup=8'h44; 9'd338: font_lookup=8'h44; 9'd339: font_lookup=8'h20;
            // 0x64 d
            9'd340: font_lookup=8'h38; 9'd341: font_lookup=8'h44;
            9'd342: font_lookup=8'h44; 9'd343: font_lookup=8'h48; 9'd344: font_lookup=8'h7F;
            // 0x65 e
            9'd345: font_lookup=8'h38; 9'd346: font_lookup=8'h54;
            9'd347: font_lookup=8'h54; 9'd348: font_lookup=8'h54; 9'd349: font_lookup=8'h18;
            // 0x66 f
            9'd350: font_lookup=8'h08; 9'd351: font_lookup=8'h7E;
            9'd352: font_lookup=8'h09; 9'd353: font_lookup=8'h01; 9'd354: font_lookup=8'h02;
            // 0x67 g
            9'd355: font_lookup=8'h0C; 9'd356: font_lookup=8'h52;
            9'd357: font_lookup=8'h52; 9'd358: font_lookup=8'h52; 9'd359: font_lookup=8'h3E;
            // 0x68 h
            9'd360: font_lookup=8'h7F; 9'd361: font_lookup=8'h08;
            9'd362: font_lookup=8'h04; 9'd363: font_lookup=8'h04; 9'd364: font_lookup=8'h78;
            // 0x69 i
            9'd365: font_lookup=8'h00; 9'd366: font_lookup=8'h44;
            9'd367: font_lookup=8'h7D; 9'd368: font_lookup=8'h40; 9'd369: font_lookup=8'h00;
            // 0x6A j
            9'd370: font_lookup=8'h20; 9'd371: font_lookup=8'h40;
            9'd372: font_lookup=8'h44; 9'd373: font_lookup=8'h3D; 9'd374: font_lookup=8'h00;
            // 0x6B k
            9'd375: font_lookup=8'h7F; 9'd376: font_lookup=8'h10;
            9'd377: font_lookup=8'h28; 9'd378: font_lookup=8'h44; 9'd379: font_lookup=8'h00;
            // 0x6C l
            9'd380: font_lookup=8'h00; 9'd381: font_lookup=8'h41;
            9'd382: font_lookup=8'h7F; 9'd383: font_lookup=8'h40; 9'd384: font_lookup=8'h00;
            // 0x6D m
            9'd385: font_lookup=8'h7C; 9'd386: font_lookup=8'h04;
            9'd387: font_lookup=8'h18; 9'd388: font_lookup=8'h04; 9'd389: font_lookup=8'h78;
            // 0x6E n
            9'd390: font_lookup=8'h7C; 9'd391: font_lookup=8'h08;
            9'd392: font_lookup=8'h04; 9'd393: font_lookup=8'h04; 9'd394: font_lookup=8'h78;
            // 0x6F o
            9'd395: font_lookup=8'h38; 9'd396: font_lookup=8'h44;
            9'd397: font_lookup=8'h44; 9'd398: font_lookup=8'h44; 9'd399: font_lookup=8'h38;
            // 0x70 p
            9'd400: font_lookup=8'h7C; 9'd401: font_lookup=8'h14;
            9'd402: font_lookup=8'h14; 9'd403: font_lookup=8'h14; 9'd404: font_lookup=8'h08;
            // 0x71 q
            9'd405: font_lookup=8'h08; 9'd406: font_lookup=8'h14;
            9'd407: font_lookup=8'h14; 9'd408: font_lookup=8'h18; 9'd409: font_lookup=8'h7C;
            // 0x72 r
            9'd410: font_lookup=8'h7C; 9'd411: font_lookup=8'h08;
            9'd412: font_lookup=8'h04; 9'd413: font_lookup=8'h04; 9'd414: font_lookup=8'h08;
            // 0x73 s
            9'd415: font_lookup=8'h48; 9'd416: font_lookup=8'h54;
            9'd417: font_lookup=8'h54; 9'd418: font_lookup=8'h54; 9'd419: font_lookup=8'h20;
            // 0x74 t
            9'd420: font_lookup=8'h04; 9'd421: font_lookup=8'h3F;
            9'd422: font_lookup=8'h44; 9'd423: font_lookup=8'h40; 9'd424: font_lookup=8'h20;
            // 0x75 u
            9'd425: font_lookup=8'h3C; 9'd426: font_lookup=8'h40;
            9'd427: font_lookup=8'h40; 9'd428: font_lookup=8'h20; 9'd429: font_lookup=8'h7C;
            // 0x76 v
            9'd430: font_lookup=8'h1C; 9'd431: font_lookup=8'h20;
            9'd432: font_lookup=8'h40; 9'd433: font_lookup=8'h20; 9'd434: font_lookup=8'h1C;
            // 0x77 w
            9'd435: font_lookup=8'h3C; 9'd436: font_lookup=8'h40;
            9'd437: font_lookup=8'h30; 9'd438: font_lookup=8'h40; 9'd439: font_lookup=8'h3C;
            // 0x78 x
            9'd440: font_lookup=8'h44; 9'd441: font_lookup=8'h28;
            9'd442: font_lookup=8'h10; 9'd443: font_lookup=8'h28; 9'd444: font_lookup=8'h44;
            // 0x79 y
            9'd445: font_lookup=8'h0C; 9'd446: font_lookup=8'h50;
            9'd447: font_lookup=8'h50; 9'd448: font_lookup=8'h50; 9'd449: font_lookup=8'h3C;
            // 0x7A z
            9'd450: font_lookup=8'h44; 9'd451: font_lookup=8'h64;
            9'd452: font_lookup=8'h54; 9'd453: font_lookup=8'h4C; 9'd454: font_lookup=8'h44;
            // 0x7B {
            9'd455: font_lookup=8'h00; 9'd456: font_lookup=8'h08;
            9'd457: font_lookup=8'h36; 9'd458: font_lookup=8'h41; 9'd459: font_lookup=8'h00;
            // 0x7C |
            9'd460: font_lookup=8'h00; 9'd461: font_lookup=8'h00;
            9'd462: font_lookup=8'h7F; 9'd463: font_lookup=8'h00; 9'd464: font_lookup=8'h00;
            // 0x7D }
            9'd465: font_lookup=8'h00; 9'd466: font_lookup=8'h41;
            9'd467: font_lookup=8'h36; 9'd468: font_lookup=8'h08; 9'd469: font_lookup=8'h00;
            // 0x7E ~
            9'd470: font_lookup=8'h10; 9'd471: font_lookup=8'h08;
            9'd472: font_lookup=8'h08; 9'd473: font_lookup=8'h10; 9'd474: font_lookup=8'h08;
            default: font_lookup=8'h00;
        endcase
    end
endfunction

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
localparam [4:0]
    ST_RESET        = 5'd0,   // drive RES low
    ST_RESET_WAIT   = 5'd1,   // hold RES low for 3 µs
    ST_VDD_ON       = 5'd2,   // enable VDD logic power
    ST_VDD_WAIT     = 5'd3,   // wait 10 ms for VDD stable
    ST_INIT_START   = 5'd4,   // begin sending init sequence
    ST_INIT_SEND    = 5'd5,   // shift out one byte of init sequence
    ST_INIT_WAIT    = 5'd6,   // wait for SPI to finish
    ST_INIT_NEXT    = 5'd7,   // advance to next byte or finish
    ST_VBAT_ON      = 5'd8,   // enable VBAT display power
    ST_VBAT_WAIT    = 5'd9,   // wait 100 ms
    ST_DISP_ON      = 5'd10,  // send Display On command (0xAF)
    ST_DISP_WAIT    = 5'd11,  // wait for Display On SPI to finish
    ST_REFRESH_START= 5'd12,  // begin screen refresh: rebuild text buffer
    ST_PAGE_CMD     = 5'd13,  // send page-set command sequence
    ST_PAGE_WAIT    = 5'd14,  // wait for SPI
    ST_COL_DATA     = 5'd15,  // send one column of font data
    ST_COL_WAIT     = 5'd16,  // wait for SPI
    ST_NEXT_COL     = 5'd17,  // advance column / character / line
    ST_DONE         = 5'd18;  // loop back to refresh

reg [4:0] state;

// Refresh position tracking
reg [1:0] cur_line;     // 0-3
reg [4:0] cur_char;     // 0-20 (21 chars per line)
reg [2:0] cur_col;      // 0-5  (5 font cols + 1 space col per char)

// Page-command sub-sequence: 3 SPI bytes to set page + col address
// ST_PAGE_CMD sends: 0xB0|page, 0x00, 0x10
reg [1:0] page_cmd_idx;

// ---------------------------------------------------------------------------
// Power-on safe state — Quartus MAX 10 honours `initial` for registers.
// Without this, all regs power up to 0, which means:
//   vdd_en=0 (VDD ON immediately, before FSM controls it — tolerable)
//   vbat_en=0 (VBAT ON immediately, violating VDD→VBAT sequencing)
//   spi_cs_n=0 (CS asserted, garbage SPI to display)
// The synchronous `rst` block sets the same values but `rst` is never
// asserted at power-on (it requires a long button press).
// ---------------------------------------------------------------------------
initial begin
    state       = 5'd0;     // ST_RESET
    spi_cs_n    = 1'b1;     // CS deasserted
    spi_clk     = 1'b0;
    spi_mosi    = 1'b0;
    spi_dc      = 1'b0;
    spi_res_n   = 1'b0;     // hold display in reset at power-on
    vbat_en     = 1'b1;     // VBAT OFF (active-low enable)
    vdd_en      = 1'b1;     // VDD  OFF (active-low enable)
    delay_ctr   = 21'd0;
    spi_bit_ctr = 4'd0;
    seq_idx     = 5'd0;
    cur_line    = 2'd0;
    cur_char    = 5'd0;
    cur_col     = 3'd0;
    page_cmd_idx= 2'd0;
end

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
        // --- Line 2: "N PC:     XXXX       " ---
        2'd2: begin
            case (cur_char)
                5'd0:  cur_ascii = flag_n ? "N" : " ";
                5'd1:  cur_ascii = " ";
                5'd2:  cur_ascii = "P";
                5'd3:  cur_ascii = "C";
                5'd4:  cur_ascii = ":";
                5'd5:  cur_ascii = " ";
                5'd6:  cur_ascii = " ";
                5'd7:  cur_ascii = " ";
                5'd8:  cur_ascii = " ";
                5'd9:  cur_ascii = " ";
                5'd10: cur_ascii = "0";   // PC is 8-bit, zero-pad to 4 digits
                5'd11: cur_ascii = "0";
                5'd12: cur_ascii = hex_char(pc[7:4]);
                5'd13: cur_ascii = hex_char(pc[3:0]);
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
wire [8:0] font_ascii9 = {1'b0, cur_ascii} - 9'h020;
wire [8:0] font_addr   = font_ascii9 * 9'd5 + {6'd0, cur_col[2:0]};
// Column 5, 6, 7 are inter-character gap / padding — always 0x00
wire [7:0] font_byte  = (cur_col >= 3'd5) ? 8'h00 : font_lookup(font_addr[8:0]);

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
        state       <= ST_RESET;
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

            // --- Apply reset pulse to SSD1306 ---
            ST_RESET: begin
                spi_res_n <= 1'b0;          // hold RES low
                delay_ctr <= 21'd36;        // 3 µs at 12 MHz
                state     <= ST_RESET_WAIT;
            end

            ST_RESET_WAIT: begin
                if (!delay_done)
                    delay_ctr <= delay_ctr - 21'd1;
                else begin
                    spi_res_n <= 1'b1;      // release reset
                    state     <= ST_VDD_ON;
                end
            end

            // --- Power on VDD (logic) ---
            ST_VDD_ON: begin
                vdd_en    <= 1'b0;          // VDDC low = power ON
                delay_ctr <= 21'd120_000;   // 10 ms
                state     <= ST_VDD_WAIT;
            end

            ST_VDD_WAIT: begin
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
