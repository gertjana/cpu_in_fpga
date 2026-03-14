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
// ---------------------------------------------------------------------------
reg [7:0] font [0:511]; // 95 chars × 5 columns = 475 entries; padded to 512 for Quartus MIF alignment

// Standard 5×7 font — same bitmap as the classic Arduino/Adafruit GFX font.
initial begin
    // 0x20 space
    font[0]=8'h00; font[1]=8'h00; font[2]=8'h00; font[3]=8'h00; font[4]=8'h00;
    // 0x21 !
    font[5]=8'h00; font[6]=8'h00; font[7]=8'h5F; font[8]=8'h00; font[9]=8'h00;
    // 0x22 "
    font[10]=8'h00; font[11]=8'h07; font[12]=8'h00; font[13]=8'h07; font[14]=8'h00;
    // 0x23 #
    font[15]=8'h14; font[16]=8'h7F; font[17]=8'h14; font[18]=8'h7F; font[19]=8'h14;
    // 0x24 $
    font[20]=8'h24; font[21]=8'h2A; font[22]=8'h7F; font[23]=8'h2A; font[24]=8'h12;
    // 0x25 %
    font[25]=8'h23; font[26]=8'h13; font[27]=8'h08; font[28]=8'h64; font[29]=8'h62;
    // 0x26 &
    font[30]=8'h36; font[31]=8'h49; font[32]=8'h55; font[33]=8'h22; font[34]=8'h50;
    // 0x27 '
    font[35]=8'h00; font[36]=8'h05; font[37]=8'h03; font[38]=8'h00; font[39]=8'h00;
    // 0x28 (
    font[40]=8'h00; font[41]=8'h1C; font[42]=8'h22; font[43]=8'h41; font[44]=8'h00;
    // 0x29 )
    font[45]=8'h00; font[46]=8'h41; font[47]=8'h22; font[48]=8'h1C; font[49]=8'h00;
    // 0x2A *
    font[50]=8'h14; font[51]=8'h08; font[52]=8'h3E; font[53]=8'h08; font[54]=8'h14;
    // 0x2B +
    font[55]=8'h08; font[56]=8'h08; font[57]=8'h3E; font[58]=8'h08; font[59]=8'h08;
    // 0x2C ,
    font[60]=8'h00; font[61]=8'h50; font[62]=8'h30; font[63]=8'h00; font[64]=8'h00;
    // 0x2D -
    font[65]=8'h08; font[66]=8'h08; font[67]=8'h08; font[68]=8'h08; font[69]=8'h08;
    // 0x2E .
    font[70]=8'h00; font[71]=8'h60; font[72]=8'h60; font[73]=8'h00; font[74]=8'h00;
    // 0x2F /
    font[75]=8'h20; font[76]=8'h10; font[77]=8'h08; font[78]=8'h04; font[79]=8'h02;
    // 0x30 0
    font[80]=8'h3E; font[81]=8'h51; font[82]=8'h49; font[83]=8'h45; font[84]=8'h3E;
    // 0x31 1
    font[85]=8'h00; font[86]=8'h42; font[87]=8'h7F; font[88]=8'h40; font[89]=8'h00;
    // 0x32 2
    font[90]=8'h42; font[91]=8'h61; font[92]=8'h51; font[93]=8'h49; font[94]=8'h46;
    // 0x33 3
    font[95]=8'h21; font[96]=8'h41; font[97]=8'h45; font[98]=8'h4B; font[99]=8'h31;
    // 0x34 4
    font[100]=8'h18; font[101]=8'h14; font[102]=8'h12; font[103]=8'h7F; font[104]=8'h10;
    // 0x35 5
    font[105]=8'h27; font[106]=8'h45; font[107]=8'h45; font[108]=8'h45; font[109]=8'h39;
    // 0x36 6
    font[110]=8'h3C; font[111]=8'h4A; font[112]=8'h49; font[113]=8'h49; font[114]=8'h30;
    // 0x37 7
    font[115]=8'h01; font[116]=8'h71; font[117]=8'h09; font[118]=8'h05; font[119]=8'h03;
    // 0x38 8
    font[120]=8'h36; font[121]=8'h49; font[122]=8'h49; font[123]=8'h49; font[124]=8'h36;
    // 0x39 9
    font[125]=8'h06; font[126]=8'h49; font[127]=8'h49; font[128]=8'h29; font[129]=8'h1E;
    // 0x3A :
    font[130]=8'h00; font[131]=8'h36; font[132]=8'h36; font[133]=8'h00; font[134]=8'h00;
    // 0x3B ;
    font[135]=8'h00; font[136]=8'h56; font[137]=8'h36; font[138]=8'h00; font[139]=8'h00;
    // 0x3C <
    font[140]=8'h08; font[141]=8'h14; font[142]=8'h22; font[143]=8'h41; font[144]=8'h00;
    // 0x3D =
    font[145]=8'h14; font[146]=8'h14; font[147]=8'h14; font[148]=8'h14; font[149]=8'h14;
    // 0x3E >
    font[150]=8'h00; font[151]=8'h41; font[152]=8'h22; font[153]=8'h14; font[154]=8'h08;
    // 0x3F ?
    font[155]=8'h02; font[156]=8'h01; font[157]=8'h51; font[158]=8'h09; font[159]=8'h06;
    // 0x40 @
    font[160]=8'h32; font[161]=8'h49; font[162]=8'h79; font[163]=8'h41; font[164]=8'h3E;
    // 0x41 A
    font[165]=8'h7E; font[166]=8'h11; font[167]=8'h11; font[168]=8'h11; font[169]=8'h7E;
    // 0x42 B
    font[170]=8'h7F; font[171]=8'h49; font[172]=8'h49; font[173]=8'h49; font[174]=8'h36;
    // 0x43 C
    font[175]=8'h3E; font[176]=8'h41; font[177]=8'h41; font[178]=8'h41; font[179]=8'h22;
    // 0x44 D
    font[180]=8'h7F; font[181]=8'h41; font[182]=8'h41; font[183]=8'h22; font[184]=8'h1C;
    // 0x45 E
    font[185]=8'h7F; font[186]=8'h49; font[187]=8'h49; font[188]=8'h49; font[189]=8'h41;
    // 0x46 F
    font[190]=8'h7F; font[191]=8'h09; font[192]=8'h09; font[193]=8'h09; font[194]=8'h01;
    // 0x47 G
    font[195]=8'h3E; font[196]=8'h41; font[197]=8'h49; font[198]=8'h49; font[199]=8'h7A;
    // 0x48 H
    font[200]=8'h7F; font[201]=8'h08; font[202]=8'h08; font[203]=8'h08; font[204]=8'h7F;
    // 0x49 I
    font[205]=8'h00; font[206]=8'h41; font[207]=8'h7F; font[208]=8'h41; font[209]=8'h00;
    // 0x4A J
    font[210]=8'h20; font[211]=8'h40; font[212]=8'h41; font[213]=8'h3F; font[214]=8'h01;
    // 0x4B K
    font[215]=8'h7F; font[216]=8'h08; font[217]=8'h14; font[218]=8'h22; font[219]=8'h41;
    // 0x4C L
    font[220]=8'h7F; font[221]=8'h40; font[222]=8'h40; font[223]=8'h40; font[224]=8'h40;
    // 0x4D M
    font[225]=8'h7F; font[226]=8'h02; font[227]=8'h0C; font[228]=8'h02; font[229]=8'h7F;
    // 0x4E N
    font[230]=8'h7F; font[231]=8'h04; font[232]=8'h08; font[233]=8'h10; font[234]=8'h7F;
    // 0x4F O
    font[235]=8'h3E; font[236]=8'h41; font[237]=8'h41; font[238]=8'h41; font[239]=8'h3E;
    // 0x50 P
    font[240]=8'h7F; font[241]=8'h09; font[242]=8'h09; font[243]=8'h09; font[244]=8'h06;
    // 0x51 Q
    font[245]=8'h3E; font[246]=8'h41; font[247]=8'h51; font[248]=8'h21; font[249]=8'h5E;
    // 0x52 R
    font[250]=8'h7F; font[251]=8'h09; font[252]=8'h19; font[253]=8'h29; font[254]=8'h46;
    // 0x53 S
    font[255]=8'h46; font[256]=8'h49; font[257]=8'h49; font[258]=8'h49; font[259]=8'h31;
    // 0x54 T
    font[260]=8'h01; font[261]=8'h01; font[262]=8'h7F; font[263]=8'h01; font[264]=8'h01;
    // 0x55 U
    font[265]=8'h3F; font[266]=8'h40; font[267]=8'h40; font[268]=8'h40; font[269]=8'h3F;
    // 0x56 V
    font[270]=8'h1F; font[271]=8'h20; font[272]=8'h40; font[273]=8'h20; font[274]=8'h1F;
    // 0x57 W
    font[275]=8'h3F; font[276]=8'h40; font[277]=8'h38; font[278]=8'h40; font[279]=8'h3F;
    // 0x58 X
    font[280]=8'h63; font[281]=8'h14; font[282]=8'h08; font[283]=8'h14; font[284]=8'h63;
    // 0x59 Y
    font[285]=8'h07; font[286]=8'h08; font[287]=8'h70; font[288]=8'h08; font[289]=8'h07;
    // 0x5A Z
    font[290]=8'h61; font[291]=8'h51; font[292]=8'h49; font[293]=8'h45; font[294]=8'h43;
    // 0x5B [
    font[295]=8'h00; font[296]=8'h7F; font[297]=8'h41; font[298]=8'h41; font[299]=8'h00;
    // 0x5C backslash
    font[300]=8'h02; font[301]=8'h04; font[302]=8'h08; font[303]=8'h10; font[304]=8'h20;
    // 0x5D ]
    font[305]=8'h00; font[306]=8'h41; font[307]=8'h41; font[308]=8'h7F; font[309]=8'h00;
    // 0x5E ^
    font[310]=8'h04; font[311]=8'h02; font[312]=8'h01; font[313]=8'h02; font[314]=8'h04;
    // 0x5F _
    font[315]=8'h40; font[316]=8'h40; font[317]=8'h40; font[318]=8'h40; font[319]=8'h40;
    // 0x60 `
    font[320]=8'h00; font[321]=8'h01; font[322]=8'h02; font[323]=8'h04; font[324]=8'h00;
    // 0x61 a
    font[325]=8'h20; font[326]=8'h54; font[327]=8'h54; font[328]=8'h54; font[329]=8'h78;
    // 0x62 b
    font[330]=8'h7F; font[331]=8'h48; font[332]=8'h44; font[333]=8'h44; font[334]=8'h38;
    // 0x63 c
    font[335]=8'h38; font[336]=8'h44; font[337]=8'h44; font[338]=8'h44; font[339]=8'h20;
    // 0x64 d
    font[340]=8'h38; font[341]=8'h44; font[342]=8'h44; font[343]=8'h48; font[344]=8'h7F;
    // 0x65 e
    font[345]=8'h38; font[346]=8'h54; font[347]=8'h54; font[348]=8'h54; font[349]=8'h18;
    // 0x66 f
    font[350]=8'h08; font[351]=8'h7E; font[352]=8'h09; font[353]=8'h01; font[354]=8'h02;
    // 0x67 g
    font[355]=8'h0C; font[356]=8'h52; font[357]=8'h52; font[358]=8'h52; font[359]=8'h3E;
    // 0x68 h
    font[360]=8'h7F; font[361]=8'h08; font[362]=8'h04; font[363]=8'h04; font[364]=8'h78;
    // 0x69 i
    font[365]=8'h00; font[366]=8'h44; font[367]=8'h7D; font[368]=8'h40; font[369]=8'h00;
    // 0x6A j
    font[370]=8'h20; font[371]=8'h40; font[372]=8'h44; font[373]=8'h3D; font[374]=8'h00;
    // 0x6B k
    font[375]=8'h7F; font[376]=8'h10; font[377]=8'h28; font[378]=8'h44; font[379]=8'h00;
    // 0x6C l
    font[380]=8'h00; font[381]=8'h41; font[382]=8'h7F; font[383]=8'h40; font[384]=8'h00;
    // 0x6D m
    font[385]=8'h7C; font[386]=8'h04; font[387]=8'h18; font[388]=8'h04; font[389]=8'h78;
    // 0x6E n
    font[390]=8'h7C; font[391]=8'h08; font[392]=8'h04; font[393]=8'h04; font[394]=8'h78;
    // 0x6F o
    font[395]=8'h38; font[396]=8'h44; font[397]=8'h44; font[398]=8'h44; font[399]=8'h38;
    // 0x70 p
    font[400]=8'h7C; font[401]=8'h14; font[402]=8'h14; font[403]=8'h14; font[404]=8'h08;
    // 0x71 q
    font[405]=8'h08; font[406]=8'h14; font[407]=8'h14; font[408]=8'h18; font[409]=8'h7C;
    // 0x72 r
    font[410]=8'h7C; font[411]=8'h08; font[412]=8'h04; font[413]=8'h04; font[414]=8'h08;
    // 0x73 s
    font[415]=8'h48; font[416]=8'h54; font[417]=8'h54; font[418]=8'h54; font[419]=8'h20;
    // 0x74 t
    font[420]=8'h04; font[421]=8'h3F; font[422]=8'h44; font[423]=8'h40; font[424]=8'h20;
    // 0x75 u
    font[425]=8'h3C; font[426]=8'h40; font[427]=8'h40; font[428]=8'h20; font[429]=8'h7C;
    // 0x76 v
    font[430]=8'h1C; font[431]=8'h20; font[432]=8'h40; font[433]=8'h20; font[434]=8'h1C;
    // 0x77 w
    font[435]=8'h3C; font[436]=8'h40; font[437]=8'h30; font[438]=8'h40; font[439]=8'h3C;
    // 0x78 x
    font[440]=8'h44; font[441]=8'h28; font[442]=8'h10; font[443]=8'h28; font[444]=8'h44;
    // 0x79 y
    font[445]=8'h0C; font[446]=8'h50; font[447]=8'h50; font[448]=8'h50; font[449]=8'h3C;
    // 0x7A z
    font[450]=8'h44; font[451]=8'h64; font[452]=8'h54; font[453]=8'h4C; font[454]=8'h44;
    // 0x7B {
    font[455]=8'h00; font[456]=8'h08; font[457]=8'h36; font[458]=8'h41; font[459]=8'h00;
    // 0x7C |
    font[460]=8'h00; font[461]=8'h00; font[462]=8'h7F; font[463]=8'h00; font[464]=8'h00;
    // 0x7D }
    font[465]=8'h00; font[466]=8'h41; font[467]=8'h36; font[468]=8'h08; font[469]=8'h00;
    // 0x7E ~
    font[470]=8'h10; font[471]=8'h08; font[472]=8'h08; font[473]=8'h10; font[474]=8'h08;
end

// ---------------------------------------------------------------------------
// Text buffer — 4 lines × 21 characters (registers sampled each refresh)
// We build the text into a flat array of 84 bytes: [line][col] = text[line*21+col]
// ---------------------------------------------------------------------------
reg [7:0] text [0:83];   // 4 × 21 = 84 bytes

// Hex nibble to ASCII
function [7:0] hex_char;
    input [3:0] nibble;
    begin
        hex_char = (nibble < 4'd10) ? (8'h30 + nibble) : (8'h41 + nibble - 4'd10);
    end
endfunction

// Build all 4 text lines from live CPU state.
//
// Layout (21 chars per line):
//   Line 0: "C R0-R3:  XX XX XX XX"
//   Line 1: "Z R4-R7:  XX XX XX XX"
//   Line 2: "N PC:     XXXX       "
//   Line 3: "V <PROG_NAME 19 chars>"
//
// Flags: letter shown when set, space when clear.
// Register values are 2-digit hex; PC is 4-digit hex (zero-extended).

task build_text_line;
    input [4:0] line;
    input [7:0] r_a, r_b, r_c, r_d;  // 4 registers for lines 0/1; ignored for 2/3
    begin
        case (line)
            // --- Line 0: "C R0-R3:  XX XX XX XX" ---
            5'd0: begin
                text[0]  = flag_c ? "C" : " ";
                text[1]  = " ";
                text[2]  = "R"; text[3]  = "0"; text[4]  = "-";
                text[5]  = "R"; text[6]  = "3"; text[7]  = ":";
                text[8]  = " "; text[9]  = " ";   // two spaces after colon
                text[10] = hex_char(r_a[7:4]); text[11] = hex_char(r_a[3:0]);
                text[12] = " ";
                text[13] = hex_char(r_b[7:4]); text[14] = hex_char(r_b[3:0]);
                text[15] = " ";
                text[16] = hex_char(r_c[7:4]); text[17] = hex_char(r_c[3:0]);
                text[18] = " ";
                text[19] = hex_char(r_d[7:4]); text[20] = hex_char(r_d[3:0]);
            end
            // --- Line 1: "Z R4-R7:  XX XX XX XX" ---
            5'd1: begin
                text[21] = flag_z ? "Z" : " ";
                text[22] = " ";
                text[23] = "R"; text[24] = "4"; text[25] = "-";
                text[26] = "R"; text[27] = "7"; text[28] = ":";
                text[29] = " "; text[30] = " ";   // two spaces after colon
                text[31] = hex_char(r_a[7:4]); text[32] = hex_char(r_a[3:0]);
                text[33] = " ";
                text[34] = hex_char(r_b[7:4]); text[35] = hex_char(r_b[3:0]);
                text[36] = " ";
                text[37] = hex_char(r_c[7:4]); text[38] = hex_char(r_c[3:0]);
                text[39] = " ";
                text[40] = hex_char(r_d[7:4]); text[41] = hex_char(r_d[3:0]);
            end
            // --- Line 2: "N PC:     XXXX       " ---
            5'd2: begin
                text[42] = flag_n ? "N" : " ";
                text[43] = " ";
                text[44] = "P"; text[45] = "C"; text[46] = ":";
                text[47] = " "; text[48] = " "; text[49] = " ";
                text[50] = " "; text[51] = " ";   // five spaces after colon
                text[52] = "0"; text[53] = "0";   // PC is 8-bit; zero-extend to 4 digits
                text[54] = hex_char(pc[7:4]); text[55] = hex_char(pc[3:0]);
                text[56] = " "; text[57] = " "; text[58] = " ";
                text[59] = " "; text[60] = " "; text[61] = " ";
                text[62] = " ";
            end
            // --- Line 3: "V <PROG_NAME, first 19 chars>" ---
            default: begin
                text[63] = flag_v ? "V" : " ";
                text[64] = " ";
                text[65] = PROG_NAME[151:144];
                text[66] = PROG_NAME[143:136];
                text[67] = PROG_NAME[135:128];
                text[68] = PROG_NAME[127:120];
                text[69] = PROG_NAME[119:112];
                text[70] = PROG_NAME[111:104];
                text[71] = PROG_NAME[103:96];
                text[72] = PROG_NAME[95:88];
                text[73] = PROG_NAME[87:80];
                text[74] = PROG_NAME[79:72];
                text[75] = PROG_NAME[71:64];
                text[76] = PROG_NAME[63:56];
                text[77] = PROG_NAME[55:48];
                text[78] = PROG_NAME[47:40];
                text[79] = PROG_NAME[39:32];
                text[80] = PROG_NAME[31:24];
                text[81] = PROG_NAME[23:16];
                text[82] = PROG_NAME[15:8];
                text[83] = PROG_NAME[7:0];
            end
        endcase
    end
endtask

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
// Command/data sequence ROM
// We store the SSD1306 initialisation sequence as a flat array of bytes
// plus a flag byte that marks data-vs-command and end-of-sequence.
//
// Format: {is_data[0], byte[7:0]}  — 9 bits per entry; 0=command, 1=data.
// A sentinel of 9'h1FF marks end-of-sequence.
// ---------------------------------------------------------------------------
localparam SEQ_CMD  = 1'b0;
localparam SEQ_END  = 9'h1FF;

reg [8:0] seq_rom [0:31];
reg [4:0] seq_idx;

initial begin
    // SSD1306 init commands (display already off, VDD already on)
    seq_rom[0]  = {SEQ_CMD, 8'hAE};  // Display off
    seq_rom[1]  = {SEQ_CMD, 8'hD5};  // Set display clock divide
    seq_rom[2]  = {SEQ_CMD, 8'h80};  //   ratio/oscillator = 0x80
    seq_rom[3]  = {SEQ_CMD, 8'hA8};  // Set multiplex ratio
    seq_rom[4]  = {SEQ_CMD, 8'h1F};  //   31 (for 32-row display)
    seq_rom[5]  = {SEQ_CMD, 8'hD3};  // Set display offset
    seq_rom[6]  = {SEQ_CMD, 8'h00};  //   0
    seq_rom[7]  = {SEQ_CMD, 8'h40};  // Set display start line = 0
    seq_rom[8]  = {SEQ_CMD, 8'h8D};  // Charge pump setting
    seq_rom[9]  = {SEQ_CMD, 8'h14};  //   enable charge pump
    seq_rom[10] = {SEQ_CMD, 8'hA1};  // Set segment remap (col 127 = SEG0)
    seq_rom[11] = {SEQ_CMD, 8'hC8};  // Set COM scan direction (remapped)
    seq_rom[12] = {SEQ_CMD, 8'hDA};  // Set COM pins hardware config
    seq_rom[13] = {SEQ_CMD, 8'h02};  //   sequential, no remap (32-row)
    seq_rom[14] = {SEQ_CMD, 8'h81};  // Set contrast
    seq_rom[15] = {SEQ_CMD, 8'h8F};  //   0x8F
    seq_rom[16] = {SEQ_CMD, 8'hD9};  // Set pre-charge period
    seq_rom[17] = {SEQ_CMD, 8'hF1};  //   0xF1
    seq_rom[18] = {SEQ_CMD, 8'hDB};  // Set VCOMH deselect level
    seq_rom[19] = {SEQ_CMD, 8'h40};  //   0x40
    seq_rom[20] = {SEQ_CMD, 8'hA4};  // Entire display ON (normal)
    seq_rom[21] = {SEQ_CMD, 8'hA6};  // Normal display (not inverted)
    seq_rom[22] = {SEQ_CMD, 8'h20};  // Set memory addressing mode
    seq_rom[23] = {SEQ_CMD, 8'h02};  //   page addressing (matches FSM refresh loop)
    seq_rom[24] = SEQ_END;            // Display ON sent separately after VBAT delay
    seq_rom[25] = SEQ_END;            // (padding — unreachable)
    seq_rom[26] = SEQ_END;
    seq_rom[27] = SEQ_END;
    seq_rom[28] = SEQ_END;
    seq_rom[29] = SEQ_END;
    seq_rom[30] = SEQ_END;
    seq_rom[31] = SEQ_END;
end

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

// Current font byte being sent
// text buffer index: line*21 + char (max 3*21+20 = 83, fits in 7 bits)
wire [6:0] cur_text_idx = {5'd0, cur_line} * 7'd21 + {2'd0, cur_char};
wire [7:0] cur_ascii    = text[cur_text_idx];

// Font ROM address: (ascii - 0x20) * 5 + cur_col
// Max address: (0x7E-0x20)*5 + 4 = 94*5 + 4 = 474, fits in 9 bits.
// Use 9-bit arithmetic throughout to avoid Quartus truncation warning.
wire [8:0] font_ascii9 = {1'b0, cur_ascii} - 9'h020;
wire [8:0] font_addr   = font_ascii9 * 9'd5 + {6'd0, cur_col[2:0]};
// Column 5 (6th pixel col) is always 0 (inter-character gap)
wire [7:0] font_byte  = (cur_col == 3'd5) ? 8'h00 : font[font_addr[8:0]];

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
                if (seq_rom[seq_idx] == SEQ_END) begin
                    // Reached end of sequence — move on
                    state <= ST_VBAT_ON;
                end else begin
                    spi_send(seq_rom[seq_idx][7:0], seq_rom[seq_idx][8]);
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
                // Snapshot register values into text buffer
                // (tasks called sequentially — Verilog tasks are synthesisable
                //  when they only write to variables and use no time controls)
                build_text_line(0, r0, r1, r2, r3);
                build_text_line(1, r4, r5, r6, r7);
                build_text_line(2, 8'h0, 8'h0, 8'h0, 8'h0); // flags handled inside task
                build_text_line(3, 8'h0, 8'h0, 8'h0, 8'h0); // PROG_NAME
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
