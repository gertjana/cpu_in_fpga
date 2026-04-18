// =============================================================================
// tb_decoder.v — Testbench for the Instruction Decoder
//
// Instruction field layout (24-bit):
//
//  R-format:   [23:20] group | [19:17] sub/Rd | [16:14] Ra | [13:11] Rb | [10:8] sub | [7:0] unused
//  I8-format:  [23:20] group | [19:17] sub/Rd  | [16:14] Ra | [13:8] unused |          [7:0]  imm8
//  I16-format: [23:20] group | [19:17] sub      | [18] spare |                         [15:0] addr16
//
// All immediate instructions (LDI, ADDI, CMPI) place the 8-bit immediate in [7:0].
//
// ALU group (0) uses an extended 4-bit sub-opcode field:
//  ALU-format: [23:20] group | [19:16] alu_op(4b) | [15:13] Rd | [12:10] Ra | [9:7] Rb | [6:0] unused
//    alu_op[2:0] = operation  (ADD/SUB/AND/OR/XOR/NOT/SHL/SHR)
//    alu_op[3]   = carry-in enable (1 => ADC; 0 => normal)
//
// Simulate with:
//   iverilog -o tb_decoder tb/tb_decoder.v rtl/decoder.v && vvp tb_decoder
// =============================================================================

`timescale 1ns/1ps

module tb_decoder;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg  [23:0] instr;
reg         flag_z, flag_c, flag_n, flag_v;

wire [2:0]  rd_addr, ra_addr, rb_addr;
wire        reg_we;
wire [2:0]  alu_op;
wire        alu_src_b;
wire        alu_cin;
wire [7:0]  imm;
wire [2:0]  wb_sel;
wire        mem_re, mem_we;
wire        pc_load;
wire [15:0] pc_target;
wire        stack_push, stack_pop;
wire        flags_we;
wire        halt;
wire        periph_we;
wire [3:0]  periph_port;

// ---------------------------------------------------------------------------
// Instantiate DUT
// ---------------------------------------------------------------------------
decoder dut (
    .instr      (instr),
    .flag_z     (flag_z),
    .flag_c     (flag_c),
    .flag_n     (flag_n),
    .flag_v     (flag_v),
    .rd_addr    (rd_addr),
    .ra_addr    (ra_addr),
    .rb_addr    (rb_addr),
    .reg_we     (reg_we),
    .alu_op     (alu_op),
    .alu_src_b  (alu_src_b),
    .alu_cin    (alu_cin),
    .imm        (imm),
    .wb_sel     (wb_sel),
    .mem_re     (mem_re),
    .mem_we     (mem_we),
    .pc_load    (pc_load),
    .pc_target  (pc_target),
    .stack_push (stack_push),
    .stack_pop  (stack_pop),
    .flags_we   (flags_we),
    .halt       (halt),
    .periph_we  (periph_we),
    .periph_port(periph_port)
);

// ---------------------------------------------------------------------------
// Test tracking
// ---------------------------------------------------------------------------
integer pass_count;
integer fail_count;

task chk1;
    input [63:0]  id;
    input [127:0] name;
    input         got;
    input         exp;
    begin
        if (got === exp) begin
            $display("  PASS [%0d] %s = %b", id, name, got);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL [%0d] %s = %b (expected %b)", id, name, got, exp);
            fail_count = fail_count + 1;
        end
    end
endtask

task chk2;
    input [63:0]  id;
    input [127:0] name;
    input [1:0]   got;
    input [1:0]   exp;
    begin
        if (got === exp) begin
            $display("  PASS [%0d] %s = %02b", id, name, got);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL [%0d] %s = %02b (expected %02b)", id, name, got, exp);
            fail_count = fail_count + 1;
        end
    end
endtask

task chk3;
    input [63:0]  id;
    input [127:0] name;
    input [2:0]   got;
    input [2:0]   exp;
    begin
        if (got === exp) begin
            $display("  PASS [%0d] %s = %03b", id, name, got);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL [%0d] %s = %03b (expected %03b)", id, name, got, exp);
            fail_count = fail_count + 1;
        end
    end
endtask

task chk4;
    input [63:0]  id;
    input [127:0] name;
    input [3:0]   got;
    input [3:0]   exp;
    begin
        if (got === exp) begin
            $display("  PASS [%0d] %s = %04b", id, name, got);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL [%0d] %s = %04b (expected %04b)", id, name, got, exp);
            fail_count = fail_count + 1;
        end
    end
endtask

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

task chk16;
    input [63:0]  id;
    input [127:0] name;
    input [15:0]  got;
    input [15:0]  exp;
    begin
        if (got === exp) begin
            $display("  PASS [%0d] %s = %04h", id, name, got);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL [%0d] %s = %04h (expected %04h)", id, name, got, exp);
            fail_count = fail_count + 1;
        end
    end
endtask

task apply;
    input [23:0] i;
    begin instr = i; #2; end
endtask

// ---------------------------------------------------------------------------
// Instruction encoders — all produce 24-bit words.
//
// 24-bit field layout (non-ALU groups):
//   [23:20] group
//   [19:17] f_rd  — Rd / sub-opcode
//   [16:14] f_ra  — Ra (source A, or destination for LDI/LD/POP)
//   [13:11] f_rb  — Rb (source B)
//   [10:8]  f_sub — sub / Rb-extra
//   [7:0]   imm8  (I8-format: LDI, ADDI, CMPI)
//   [7:0]   imm8  (I8-format: LDI)
//   [15:0]  addr16 (I16-format: JMP, Jcc, CALL)
//
// ALU group (0) extended layout:
//   [23:20] group=0
//   [19:16] alu_op (4-bit; bit[3]=cin enable)
//   [15:13] Rd
//   [12:10] Ra
//   [9:7]   Rb
// ---------------------------------------------------------------------------

// ALU-format encoder: {group=0, alu_op[3:0], rd[2:0], ra[2:0], rb[2:0], 7'b0}
function [23:0] enc_alu;
    input [3:0] alu_op;
    input [2:0] rd, ra, rb;
    enc_alu = {4'h0, alu_op, rd, ra, rb, 7'h00};
endfunction

// R-format: [23:20] grp | [19:17] sub | [16:14] rd | [13:11] ra | [10:8] rb | [7:0] 00
// (Used for non-ALU groups only)
function [23:0] enc_r;
    input [3:0] grp;
    input [2:0] sub, rd, ra, rb;
    enc_r = {grp, sub, rd, ra, rb, 8'h00};
endfunction

// I8-format (ADDI, CMPI): 0001/0111 ddd aaa xxxxxx iiiiiiii  — imm8 in [7:0]
function [23:0] enc_i;
    input [3:0] grp;
    input [2:0] rd, ra;
    input [7:0] imm8;
    enc_i = {grp, rd, ra, 6'b000000, imm8};
endfunction

// LDI: 0010 000 ddd xxxxxx iiiiiiii  (sub=000, dest in Ra field [16:14], imm8 in [7:0])
function [23:0] enc_ldi;
    input [2:0] rd;
    input [7:0] imm8;
    enc_ldi = {4'h2, 3'b000, rd, 6'b000000, imm8};
endfunction

// LD: 0010 001 ddd aaa xxxxxxxxxx  (dest in Ra [16:14], addr-reg in Rb [13:11])
function [23:0] enc_ld;
    input [2:0] rd, ra_src;
    enc_ld = {4'h2, 3'b001, rd, ra_src, 3'b000, 8'h00};
endfunction

// ST: 0010 010 xxx aaa bbb xxxxxxxx  (addr in Rb [13:11], data in sub [10:8])
function [23:0] enc_st;
    input [2:0] addr_reg, data_reg;
    enc_st = {4'h2, 3'b010, 3'b000, addr_reg, data_reg, 8'h00};
endfunction

// PUSH: 0101 000 aaa 000000000000000  (Ra in Ra field [16:14])
function [23:0] enc_push;
    input [2:0] ra;
    enc_push = {4'h5, 3'b000, ra, 14'b00000000000000};
endfunction

// POP:  0101 001 ddd 000000000000000  (Rd in Ra field [16:14])
function [23:0] enc_pop;
    input [2:0] rd;
    enc_pop = {4'h5, 3'b001, rd, 14'b00000000000000};
endfunction

// RET:  0101 011 000 00000000000000000
function [23:0] enc_ret;
    input dummy;
    enc_ret = {4'h5, 3'b011, 17'b00000000000000000};
endfunction

// I16-format: [23:20] grp | [19:17] sub | [18] spare | [15:0] addr16
// (for JMP, Jcc, CALL)
function [23:0] enc_i16;
    input [3:0] grp;
    input [2:0] sub;
    input [15:0] addr16;
    enc_i16 = {grp, sub, 1'b0, addr16};
endfunction

// NOP / HALT
function [23:0] enc_nop;
    input dummy;
    enc_nop = {4'hE, 20'b00000000000000000000};
endfunction

function [23:0] enc_halt;
    input dummy;
    enc_halt = {4'hF, 20'b00000000000000000000};
endfunction

// ---------------------------------------------------------------------------
// Stimulus
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("sim/vcd/tb_decoder.vcd");
    $dumpvars(0, tb_decoder);

    pass_count = 0;
    fail_count = 0;
    flag_z = 0; flag_c = 0; flag_n = 0; flag_v = 0;

    $display("=== Instruction Decoder Testbench ===");

    // ------------------------------------------------------------------
    // Group 0: ALU reg-reg (4-bit alu_op field)
    // ADD R2, R3, R5: enc_alu(4'b0000, rd=2, ra=3, rb=5)
    //   [19:16]=0 (ADD, cin-off), [15:13]=2, [12:10]=3, [9:7]=5
    // ------------------------------------------------------------------
    $display("--- ALU ADD R2, R3, R5 ---");
    apply(enc_alu(4'b0000, 3'd2, 3'd3, 3'd5));
    chk3(10, "rd_addr   ", rd_addr,   3'd2);
    chk3(11, "ra_addr   ", ra_addr,   3'd3);
    chk3(12, "rb_addr   ", rb_addr,   3'd5);
    chk3(13, "alu_op    ", alu_op,    3'b000); // ADD
    chk1(14, "alu_src_b ", alu_src_b, 1'b0);
    chk1(15, "alu_cin   ", alu_cin,   1'b0);   // no carry-in for ADD
    chk1(16, "reg_we    ", reg_we,    1'b1);
    chk1(17, "flags_we  ", flags_we,  1'b1);
    chk1(18, "mem_re    ", mem_re,    1'b0);
    chk1(19, "mem_we    ", mem_we,    1'b0);
    chk1(20, "pc_load   ", pc_load,   1'b0);
    chk1(21, "halt      ", halt,      1'b0);

    $display("--- ALU SUB R0, R1, R2 ---");
    apply(enc_alu(4'b0001, 3'd0, 3'd1, 3'd2));
    chk3(22, "alu_op SUB", alu_op,   3'b001);
    chk1(23, "alu_cin   ", alu_cin,  1'b0);
    chk1(24, "flags_we  ", flags_we, 1'b1);

    $display("--- ALU SHR R7, R7, Rx ---");
    apply(enc_alu(4'b0111, 3'd7, 3'd7, 3'd0));
    chk3(25, "alu_op SHR", alu_op,   3'b111);
    chk3(26, "rd_addr   ", rd_addr,  3'd7);
    chk3(27, "ra_addr   ", ra_addr,  3'd7);
    chk1(28, "alu_cin   ", alu_cin,  1'b0);

    $display("--- ALU NOT R4, R6, Rx ---");
    apply(enc_alu(4'b0101, 3'd4, 3'd6, 3'd0));
    chk3(29, "alu_op NOT", alu_op,   3'b101);
    chk3(30, "rd_addr   ", rd_addr,  3'd4);
    chk3(31, "ra_addr   ", ra_addr,  3'd6);
    chk1(32, "alu_cin   ", alu_cin,  1'b0);

    // ------------------------------------------------------------------
    // Group 0: ADC R1, R3, R5  (alu_op=4'b1000)
    // alu_op[3]=1 enables carry-in; alu_op[2:0]=000 selects ADD
    // ------------------------------------------------------------------
    $display("--- ALU ADC R1, R3, R5 (alu_op=1000, cin=1) ---");
    apply(enc_alu(4'b1000, 3'd1, 3'd3, 3'd5));
    chk3(33, "rd_addr   ", rd_addr,   3'd1);
    chk3(34, "ra_addr   ", ra_addr,   3'd3);
    chk3(35, "rb_addr   ", rb_addr,   3'd5);
    chk3(36, "alu_op    ", alu_op,    3'b000); // op[2:0] = ADD
    chk1(37, "alu_cin   ", alu_cin,   1'b1);   // op[3]=1 => carry-in enabled
    chk1(38, "alu_src_b ", alu_src_b, 1'b0);
    chk1(39, "reg_we    ", reg_we,    1'b1);
    chk1(40, "flags_we  ", flags_we,  1'b1);

    // ------------------------------------------------------------------
    // Group 1: ADDI R1, R4, 42  (imm8 = 8'd42)
    // I8-format: 0001 001 100 xxxxxx 00101010
    // ------------------------------------------------------------------
    $display("--- ADDI R1, R4, 42 ---");
    apply(enc_i(4'h1, 3'd1, 3'd4, 8'd42));
    chk3(30, "rd_addr   ", rd_addr,   3'd1);
    chk3(31, "ra_addr   ", ra_addr,   3'd4);
    chk8(32, "imm       ", imm,       8'd42);
    chk3(33, "alu_op    ", alu_op,    3'b000); // ADD
    chk1(34, "alu_src_b ", alu_src_b, 1'b1);
    chk1(35, "reg_we    ", reg_we,    1'b1);
    chk1(36, "flags_we  ", flags_we,  1'b1);

    $display("--- ADDI R0, R0, 1 ---");
    apply(enc_i(4'h1, 3'd0, 3'd0, 8'd1));
    chk8(37, "imm=1     ", imm, 8'd1);

    // ------------------------------------------------------------------
    // Group 2a: LDI R3, 200  (imm8 = 8'd200)
    // 0010 000 011 xxxxxx 11001000
    // ------------------------------------------------------------------
    $display("--- LDI R3, 200 ---");
    apply(enc_ldi(3'd3, 8'd200));
    chk3(40, "rd_addr   ", rd_addr,   3'd3);
    chk8(41, "imm       ", imm,       8'd200);
    chk1(42, "reg_we    ", reg_we,    1'b1);
    chk3(43, "wb_sel    ", wb_sel,    3'b010); // WB_IMM
    chk1(44, "mem_re    ", mem_re,    1'b0);
    chk1(45, "flags_we  ", flags_we,  1'b0);

    // ------------------------------------------------------------------
    // Group 2b: LD R5, [R2]
    // 0010 001 101 010 xxx xxxxxxxx
    // ------------------------------------------------------------------
    $display("--- LD R5, [R2] ---");
    apply(enc_ld(3'd5, 3'd2));
    chk3(50, "rd_addr   ", rd_addr,  3'd5);
    chk3(51, "ra_addr   ", ra_addr,  3'd2);
    chk1(52, "mem_re    ", mem_re,   1'b1);
    chk1(53, "reg_we    ", reg_we,   1'b1);
    chk3(54, "wb_sel    ", wb_sel,   3'b001); // WB_MEM
    chk1(55, "mem_we    ", mem_we,   1'b0);

    // ------------------------------------------------------------------
    // Group 2c: ST [R1], R6
    // 0010 010 xxx 001 110 xxxxxxxx
    // ------------------------------------------------------------------
    $display("--- ST [R1], R6 ---");
    apply(enc_st(3'd1, 3'd6));
    chk3(60, "ra_addr   ", ra_addr,  3'd1);
    chk3(61, "rb_addr   ", rb_addr,  3'd6);
    chk1(62, "mem_we    ", mem_we,   1'b1);
    chk1(63, "reg_we    ", reg_we,   1'b0);
    chk1(64, "mem_re    ", mem_re,   1'b0);

    // ------------------------------------------------------------------
    // Group 3: MOV R2, R7
    // R-format: 0011 010 111 000 000 00000000
    // ------------------------------------------------------------------
    $display("--- MOV R2, R7 ---");
    apply(enc_r(4'h3, 3'd2, 3'd7, 3'd0, 3'd0));
    chk3(70, "rd_addr   ", rd_addr,   3'd2);
    chk3(71, "ra_addr   ", ra_addr,   3'd7);
    chk1(72, "alu_src_b ", alu_src_b, 1'b1);
    chk8(73, "imm=0     ", imm,       8'h00);
    chk1(74, "reg_we    ", reg_we,    1'b1);
    chk1(75, "flags_we  ", flags_we,  1'b0);

    // ------------------------------------------------------------------
    // Group 4: JMP 0x0042
    // I16-format: 0100 000 0 0000000001000010
    // ------------------------------------------------------------------
    $display("--- JMP 0x0042 ---");
    flag_z = 0; flag_c = 0; flag_n = 0; flag_v = 0;
    apply(enc_i16(4'h4, 3'b000, 16'h0042));
    chk1(80, "pc_load   ", pc_load,   1'b1);
    chk16(81, "pc_target ", pc_target, 16'h0042);
    chk1(82, "reg_we    ", reg_we,    1'b0);

    $display("--- JZ 0x0010 taken (Z=1) ---");
    flag_z = 1;
    apply(enc_i16(4'h4, 3'b001, 16'h0010));
    chk1(90, "pc_load   ", pc_load,   1'b1);
    chk16(91, "pc_target ", pc_target, 16'h0010);

    $display("--- JZ 0x0010 not taken (Z=0) ---");
    flag_z = 0;
    apply(enc_i16(4'h4, 3'b001, 16'h0010));
    chk1(92, "pc_load   ", pc_load,   1'b0);

    $display("--- JNZ 0x0020 taken (Z=0) ---");
    flag_z = 0;
    apply(enc_i16(4'h4, 3'b010, 16'h0020));
    chk1(93, "pc_load   ", pc_load,   1'b1);

    $display("--- JNZ 0x0020 not taken (Z=1) ---");
    flag_z = 1;
    apply(enc_i16(4'h4, 3'b010, 16'h0020));
    chk1(94, "pc_load   ", pc_load,   1'b0);
    flag_z = 0;

    $display("--- JC taken (C=1) ---");
    flag_c = 1;
    apply(enc_i16(4'h4, 3'b011, 16'h0030));
    chk1(95, "pc_load JC", pc_load,   1'b1);

    $display("--- JNC not taken (C=1) ---");
    apply(enc_i16(4'h4, 3'b100, 16'h0030));
    chk1(96, "pc_load JNC", pc_load,  1'b0);

    $display("--- JN taken (N=1) ---");
    flag_c = 0; flag_n = 1;
    apply(enc_i16(4'h4, 3'b101, 16'h0030));
    chk1(97, "pc_load JN", pc_load,   1'b1);
    flag_n = 0;

    $display("--- JV taken (V=1) ---");
    flag_v = 1;
    apply(enc_i16(4'h4, 3'b110, 16'h0030));
    chk1(98, "pc_load JV", pc_load,   1'b1);
    flag_v = 0;

    // ------------------------------------------------------------------
    // Group 5: PUSH R3
    // 0101 000 011 00000000000000
    // ------------------------------------------------------------------
    $display("--- PUSH R3 ---");
    apply(enc_push(3'd3));
    chk3(100, "ra_addr    ", ra_addr,    3'd3);
    chk1(101, "stack_push ", stack_push, 1'b1);
    chk1(102, "stack_pop  ", stack_pop,  1'b0);
    chk1(103, "reg_we     ", reg_we,     1'b0);

    // ------------------------------------------------------------------
    // Group 5: POP R4 (Rd encoded in Ra field)
    // 0101 001 100 00000000000000
    // ------------------------------------------------------------------
    $display("--- POP R4 ---");
    apply(enc_pop(3'd4));
    chk3(110, "rd_addr    ", rd_addr,    3'd4);
    chk1(111, "stack_pop  ", stack_pop,  1'b1);
    chk1(112, "stack_push ", stack_push, 1'b0);
    chk1(113, "reg_we     ", reg_we,     1'b1);
    chk3(114, "wb_sel     ", wb_sel,     3'b011); // WB_STACK

    // ------------------------------------------------------------------
    // Group 5: CALL 0x0050
    // I16-format: 0101 010 0 0000000001010000
    // ------------------------------------------------------------------
    $display("--- CALL 0x0050 ---");
    apply(enc_i16(4'h5, 3'b010, 16'h0050));
    chk1(120, "stack_push ", stack_push, 1'b1);
    chk1(121, "pc_load    ", pc_load,    1'b1);
    chk16(122, "pc_target  ", pc_target,  16'h0050);
    chk1(123, "reg_we     ", reg_we,     1'b0);

    // ------------------------------------------------------------------
    // Group 5: RET
    // ------------------------------------------------------------------
    $display("--- RET ---");
    apply(enc_ret(1'b0));
    chk1(130, "stack_pop  ", stack_pop,  1'b1);
    chk1(131, "pc_load    ", pc_load,    1'b1);
    chk1(132, "stack_push ", stack_push, 1'b0);
    chk1(133, "reg_we     ", reg_we,     1'b0);

    // ------------------------------------------------------------------
    // Group 6: CMP R2, R5
    // R-format: 0110 000 010 101 000 00000000
    // ------------------------------------------------------------------
    $display("--- CMP R2, R5 ---");
    apply(enc_r(4'h6, 3'bxxx, 3'd2, 3'd5, 3'bxxx));
    chk3(140, "ra_addr   ", ra_addr,   3'd2);
    chk3(141, "rb_addr   ", rb_addr,   3'd5);
    chk3(142, "alu_op    ", alu_op,    3'b001); // SUB
    chk1(143, "alu_src_b ", alu_src_b, 1'b0);
    chk1(144, "flags_we  ", flags_we,  1'b1);
    chk1(145, "reg_we    ", reg_we,    1'b0);

    // ------------------------------------------------------------------
    // Group 7: CMPI R1, 10  (imm8 = 8'd10)
    // I8-format: 0111 xxx 001 xxxxxx 00001010
    // ------------------------------------------------------------------
    $display("--- CMPI R1, 10 ---");
    apply(enc_i(4'h7, 3'bxxx, 3'd1, 8'd10));
    chk3(150, "ra_addr   ", ra_addr,   3'd1);
    chk8(151, "imm       ", imm,       8'd10);
    chk3(152, "alu_op    ", alu_op,    3'b001); // SUB
    chk1(153, "alu_src_b ", alu_src_b, 1'b1);
    chk1(154, "flags_we  ", flags_we,  1'b1);
    chk1(155, "reg_we    ", reg_we,    1'b0);

    // ------------------------------------------------------------------
    // Group 14: NOP
    // ------------------------------------------------------------------
    $display("--- NOP ---");
    apply(enc_nop(1'b0));
    chk1(160, "reg_we    ", reg_we,     1'b0);
    chk1(161, "mem_re    ", mem_re,     1'b0);
    chk1(162, "mem_we    ", mem_we,     1'b0);
    chk1(163, "pc_load   ", pc_load,    1'b0);
    chk1(164, "stack_push", stack_push, 1'b0);
    chk1(165, "stack_pop ", stack_pop,  1'b0);
    chk1(166, "flags_we  ", flags_we,   1'b0);
    chk1(167, "halt      ", halt,       1'b0);

    // ------------------------------------------------------------------
    // Group 15: HALT
    // ------------------------------------------------------------------
    $display("--- HALT ---");
    apply(enc_halt(1'b0));
    chk1(170, "halt      ", halt,    1'b1);
    chk1(171, "reg_we    ", reg_we,  1'b0);
    chk1(172, "mem_we    ", mem_we,  1'b0);
    chk1(173, "pc_load   ", pc_load, 1'b0);

    // ------------------------------------------------------------------
    // Group 8: IN R5, port=1  — read hardware PRNG into register
    // Encoding: port field is 4 bits at [16:13]; Rd at [19:17]
    //   1000 101 0001 0000000000000 = 24'h8A2000
    // ------------------------------------------------------------------
    $display("--- IN R5 (port=001, PRNG) ---");
    apply(24'h8A2000);   // group=8 Rd=5 port=1
    chk3(180, "rd_addr   ", rd_addr,   3'd5);
    chk1(181, "reg_we    ", reg_we,    1'b1);
    chk3(182, "wb_sel    ", wb_sel,    3'b100); // WB_PRNG
    chk1(183, "mem_we    ", mem_we,    1'b0);
    chk1(184, "pc_load   ", pc_load,   1'b0);
    chk1(185, "halt      ", halt,      1'b0);

    // IN with unknown port (port=0) — must behave as NOP
    // Encoding: 1000 101 0000 0000000000000 = 24'h8A0000
    $display("--- IN R5 (port=000, undefined) => NOP ---");
    apply(24'h8A0000);
    chk1(186, "reg_we=0  ", reg_we,    1'b0);   // no write-back
    chk1(187, "mem_we=0  ", mem_we,    1'b0);
    chk1(188, "pc_load=0 ", pc_load,   1'b0);

    // IN R2, port=5 — GPIO input
    // Encoding: 1000 010 0101 0000000000000 = 24'h84A000
    $display("--- IN R2 (port=010, GPIO) ---");
    apply(24'h84A000);
    chk3(189, "rd_addr   ", rd_addr,   3'd2);
    chk1(190, "reg_we    ", reg_we,    1'b1);
    chk3(191, "wb_sel    ", wb_sel,    3'b101); // WB_GPIO
    chk1(192, "mem_we    ", mem_we,    1'b0);
    chk1(193, "pc_load   ", pc_load,   1'b0);

    // IN R6, port=4 — GPIO direction (write-only, IN not supported → NOP)
    // Encoding: 1000 110 0100 0000000000000 = 24'h8C8000
    $display("--- IN R6 (port=011, GPIO dir — NOP) ---");
    apply(24'h8C8000);
    chk1(194, "reg_we=0  ", reg_we,    1'b0);   // write-only port — no read-back
    chk1(195, "mem_we=0  ", mem_we,    1'b0);
    chk1(196, "pc_load=0 ", pc_load,   1'b0);

    // IN R6, port=3 — ADC value
    // Encoding: 1000 110 0011 0000000000000 = 24'h8C6000
    $display("--- IN R6 (port=100, ADC) ---");
    apply(24'h8C6000);
    chk3(197, "rd_addr   ", rd_addr,   3'd6);
    chk1(198, "reg_we    ", reg_we,    1'b1);
    chk3(199, "wb_sel    ", wb_sel,    3'b110); // WB_ADC
    chk1(200, "mem_we    ", mem_we,    1'b0);
    chk1(201, "pc_load   ", pc_load,   1'b0);

    // ------------------------------------------------------------------
    // Group 9: OUT Ra, port — write register value to hardware peripheral
    //
    // Encoding: 1001 aaa pppp 0000000000000
    //   [19:17] Ra   — source register
    //   [16:13] port — peripheral select (4-bit)
    //
    //  OUT R3, 1 = PRNG seed
    //    1001 011 0001 0000000000000 = 24'h962000
    //  OUT R0, 2 = LEDs
    //    1001 000 0010 0000000000000 = 24'h904000
    //  OUT R7, 4 = GPIO direction
    //    1001 111 0100 0000000000000 = 24'h9E8000
    //  OUT R0, 0 = undefined port → NOP
    //    1001 000 0000 0000000000000 = 24'h900000
    // ------------------------------------------------------------------
    $display("--- OUT R3 (port=001, PRNG seed) ---");
    apply(24'h962000);   // 1001 011 0001 0000000000000
    chk3(240, "ra_addr   ", ra_addr,    3'd3);   // source reg = R3
    chk1(241, "periph_we ", periph_we,  1'b1);
    chk4(242, "periph_port", periph_port, 4'd1);
    chk1(243, "reg_we=0  ", reg_we,     1'b0);   // OUT never writes back
    chk1(244, "mem_we=0  ", mem_we,     1'b0);
    chk1(245, "pc_load=0 ", pc_load,    1'b0);

    $display("--- OUT R0 (port=010, GPIO) ---");
    apply(24'h904000);   // 1001 000 0010 0000000000000
    chk3(200, "ra_addr   ", ra_addr,    3'd0);
    chk1(201, "periph_we ", periph_we,  1'b1);
    chk4(202, "periph_port", periph_port, 4'd2);
    chk1(203, "reg_we=0  ", reg_we,     1'b0);

    $display("--- OUT R7 (port=011, GPIO direction) ---");
    apply(24'h9E8000);   // 1001 111 0100 0000000000000
    chk3(210, "ra_addr   ", ra_addr,    3'd7);
    chk1(211, "periph_we ", periph_we,  1'b1);
    chk4(212, "periph_port", periph_port, 4'd4);
    chk1(213, "reg_we=0  ", reg_we,     1'b0);

    $display("--- OUT R0 (port=000, undefined) => NOP ---");
    apply(24'h900000);   // 1001 000 0000 0000000000000
    chk1(220, "periph_we=0", periph_we, 1'b0);
    chk1(221, "reg_we=0   ", reg_we,    1'b0);
    chk1(222, "pc_load=0  ", pc_load,   1'b0);

    // OUT R4, port=7 — reserved/NOP (ports 6–15 are reserved)
    // Encoding: 1001 100 0111 0000000000000 = 24'h98E000
    // For undefined/NOP ports, periph_we must be 0; ra_addr is don't-care.
    $display("--- OUT R4 (port=100, undefined/NOP) ---");
    apply(24'h98E000);
    chk1(231, "periph_we=0", periph_we,  1'b0);
    chk4(232, "periph_port", periph_port, 4'd0); // undefined port → NOP, port stays 0
    chk1(233, "reg_we=0   ", reg_we,     1'b0);
    chk1(234, "mem_we=0   ", mem_we,     1'b0);

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
