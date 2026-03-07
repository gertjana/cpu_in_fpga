// =============================================================================
// tb_decoder.v — Testbench for the Instruction Decoder
//
// Instruction field layout used here:
//
//  R-format:  [15:12] group | [11:9] Rd | [8:6] Ra | [5:3] Rb | [2:0] sub
//  I-format:  [15:12] group | [11:9] Rd | [8:6] Ra | [5:0] imm6
//  I8-format: [15:12] group | [11:9] Rd/sub | [8] x | [7:0] imm8
//
// Simulate with:
//   iverilog -o tb_decoder tb/tb_decoder.v rtl/decoder.v && vvp tb_decoder
// =============================================================================

`timescale 1ns/1ps

module tb_decoder;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg  [15:0] instr;
reg         flag_z, flag_c, flag_n, flag_v;

wire [2:0]  rd_addr, ra_addr, rb_addr;
wire        reg_we;
wire [2:0]  alu_op;
wire        alu_src_b;
wire [7:0]  imm;
wire [2:0]  wb_sel;
wire        mem_re, mem_we;
wire        pc_load;
wire [7:0]  pc_target;
wire        stack_push, stack_pop;
wire        flags_we;
wire        halt;
wire        periph_we;
wire [2:0]  periph_port;

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

task apply;
    input [15:0] i;
    begin instr = i; #2; end
endtask

// ---------------------------------------------------------------------------
// Instruction encoders
// All encode to exactly 16 bits.
// ---------------------------------------------------------------------------

// R-format: group(4) | Rd(3) | Ra(3) | Rb(3) | sub(3)
function [15:0] enc_r;
    input [3:0] grp;
    input [2:0] rd, ra, rb, sub;
    enc_r = {grp, rd, ra, rb, sub};
endfunction

// I-format: group(4) | Rd(3) | Ra(3) | imm6(6)
function [15:0] enc_i;
    input [3:0] grp;
    input [2:0] rd, ra;
    input [5:0] imm6;
    enc_i = {grp, rd, ra, imm6};
endfunction

// I8-format: group(4) | sub(3) | 1'b0 | imm8(8)
function [15:0] enc_i8;
    input [3:0] grp;
    input [2:0] sub;
    input [7:0] imm8;
    enc_i8 = {grp, sub, 1'b0, imm8};
endfunction

// LDI: group(4) | sub=000(3) | Rd(3) | 1'b0 | imm8(8)  — 4+3+3+1+8=19? No.
// Correct: 4+3+3+8 = 18. We need 16. Drop the spare bit:
// LDI: 0010 000 ddd iiiiiiii  — sub(3)=000 in [11:9], Rd(3) in [8:6], imm8 in [7:0]
// But [8:6] and [7:0] overlap at bits 7:6. Rd is only 3 bits ([8:6]),
// imm8 is 8 bits ([7:0]). Bits 7 and 6 are shared: Rd[1]=imm8[7], Rd[0]=imm8[6].
// To avoid this: put Rd in bits [8:6] and accept the overlap — the decoder
// extracts Rd from f_ra=[8:6] and imm8 from f_imm8=[7:0] independently.
// For the testbench we just need to encode correctly:
//   instr = {4'h2, 3'b000, rd[2:0], 1'b0, imm8[7:0]}  but that's 4+3+3+1+8=19 bits.
//
// Final clean answer: LDI uses 16 bits as:
//   [15:12]=0010  [11:9]=000  [8:6]=Rd  [5:0]=imm6 (only 6-bit immediate for LDI)
//   OR use imm8 but accept bit overlap, knowing the decoder reads them independently.
//
// We accept the overlap design and encode as:
//   {4'h2, 3'b000, rd, imm8}  = 4+3+3+8 = 18 bits — STILL TOO MANY.
//
// Root fix: LDI immediate is 6 bits (like ADDI). Use I-format for LDI too.
// LDI Rd, imm6: 0010 000 ddd iiiiii  (4+3+3+6=16) ✓
function [15:0] enc_ldi;
    input [2:0] rd;
    input [5:0] imm6;
    // sub=000 in [11:9], Rd in [8:6], imm6 in [5:0]
    enc_ldi = {4'h2, 3'b000, rd, imm6};
endfunction

// LD: 0010 001 ddd aaa xxx  (4+3+3+3+3=16) ✓
// sub=001 in [11:9], Rd in [8:6], Ra_src in [5:3], unused [2:0]
function [15:0] enc_ld;
    input [2:0] rd, ra_src;
    enc_ld = {4'h2, 3'b001, rd, ra_src, 3'bxxx};
endfunction

// ST: 0010 010 xxx aaa bbb  (4+3+3+3+3=16) ✓
// sub=010 in [11:9], unused [8:6], addr in [5:3], data in [2:0]
function [15:0] enc_st;
    input [2:0] addr_reg, data_reg;
    enc_st = {4'h2, 3'b010, 3'bxxx, addr_reg, data_reg};
endfunction

// PUSH: 0101 000 aaa 000000  (Ra in [8:6])
function [15:0] enc_push;
    input [2:0] ra;
    enc_push = {4'h5, 3'b000, ra, 6'b000000};
endfunction

// POP:  0101 001 ddd 000000  (Rd in Ra field [8:6])
function [15:0] enc_pop;
    input [2:0] rd;
    enc_pop = {4'h5, 3'b001, rd, 6'b000000};
endfunction

// RET:  0101 011 000 000000
function [15:0] enc_ret;
    input dummy;
    enc_ret = {4'h5, 3'b011, 9'b000000000};
endfunction

// NOP / HALT
function [15:0] enc_nop;
    input dummy;
    enc_nop = {4'hE, 12'b000000000000};
endfunction

function [15:0] enc_halt;
    input dummy;
    enc_halt = {4'hF, 12'b000000000000};
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
    // Group 0: ALU reg-reg — ADD R2, R3, R5
    // R-format: 0000 sss=000 ddd=010 aaa=011 bbb=101
    // ------------------------------------------------------------------
    $display("--- ALU ADD R2, R3, R5 ---");
    apply(enc_r(4'h0, 3'b000, 3'd2, 3'd3, 3'd5));
    chk3(10, "rd_addr   ", rd_addr,   3'd2);
    chk3(11, "ra_addr   ", ra_addr,   3'd3);
    chk3(12, "rb_addr   ", rb_addr,   3'd5);
    chk3(13, "alu_op    ", alu_op,    3'b000); // ADD
    chk1(14, "alu_src_b ", alu_src_b, 1'b0);
    chk1(15, "reg_we    ", reg_we,    1'b1);
    chk1(16, "flags_we  ", flags_we,  1'b1);
    chk1(17, "mem_re    ", mem_re,    1'b0);
    chk1(18, "mem_we    ", mem_we,    1'b0);
    chk1(19, "pc_load   ", pc_load,   1'b0);
    chk1(20, "halt      ", halt,      1'b0);

    $display("--- ALU SUB R0, R1, R2 ---");
    apply(enc_r(4'h0, 3'b001, 3'd0, 3'd1, 3'd2));
    chk3(21, "alu_op SUB", alu_op,   3'b001);
    chk1(22, "flags_we  ", flags_we, 1'b1);

    $display("--- ALU SHR R7, R7, Rx ---");
    apply(enc_r(4'h0, 3'b111, 3'd7, 3'd7, 3'd0));
    chk3(23, "alu_op SHR", alu_op,   3'b111);
    chk3(24, "rd_addr   ", rd_addr,  3'd7);
    chk3(25, "ra_addr   ", ra_addr,  3'd7);

    $display("--- ALU NOT R4, R6, Rx ---");
    apply(enc_r(4'h0, 3'b101, 3'd4, 3'd6, 3'd0));
    chk3(26, "alu_op NOT", alu_op,   3'b101);
    chk3(27, "rd_addr   ", rd_addr,  3'd4);
    chk3(28, "ra_addr   ", ra_addr,  3'd6);

    // ------------------------------------------------------------------
    // Group 1: ADDI R1, R4, 42  (imm6 = 6'd42 = 6'b101010)
    // I-format: 0001 001 100 101010
    // ------------------------------------------------------------------
    $display("--- ADDI R1, R4, 42 ---");
    apply(enc_i(4'h1, 3'd1, 3'd4, 6'd42));
    chk3(30, "rd_addr   ", rd_addr,   3'd1);
    chk3(31, "ra_addr   ", ra_addr,   3'd4);
    chk8(32, "imm       ", imm,       8'd42);
    chk3(33, "alu_op    ", alu_op,    3'b000); // ADD
    chk1(34, "alu_src_b ", alu_src_b, 1'b1);
    chk1(35, "reg_we    ", reg_we,    1'b1);
    chk1(36, "flags_we  ", flags_we,  1'b1);

    $display("--- ADDI R0, R0, 1 ---");
    apply(enc_i(4'h1, 3'd0, 3'd0, 6'd1));
    chk8(37, "imm=1     ", imm, 8'd1);

    // ------------------------------------------------------------------
    // Group 2a: LDI R3, 63  (imm6 = 6'd63 = max)
    // 0010 000 011 111111
    // ------------------------------------------------------------------
    $display("--- LDI R3, 63 ---");
    apply(enc_ldi(3'd3, 6'd63));
    chk3(40, "rd_addr   ", rd_addr,   3'd3);
    chk8(41, "imm       ", imm,       8'd63);
    chk1(42, "reg_we    ", reg_we,    1'b1);
    chk3(43, "wb_sel    ", wb_sel,    3'b010); // WB_IMM
    chk1(44, "mem_re    ", mem_re,    1'b0);
    chk1(45, "flags_we  ", flags_we,  1'b0);

    // ------------------------------------------------------------------
    // Group 2b: LD R5, [R2]
    // 0010 101 001 010 xxx
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
    // 0010 xxx 010 001 110
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
    // R-format: 0011 010 111 000 000
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
    // Group 4: JMP 0x42
    // I8-format: 0100 000 0 01000010
    // ------------------------------------------------------------------
    $display("--- JMP 0x42 ---");
    flag_z = 0; flag_c = 0; flag_n = 0; flag_v = 0;
    apply(enc_i8(4'h4, 3'b000, 8'h42));
    chk1(80, "pc_load   ", pc_load,   1'b1);
    chk8(81, "pc_target ", pc_target, 8'h42);
    chk1(82, "reg_we    ", reg_we,    1'b0);

    $display("--- JZ 0x10 taken (Z=1) ---");
    flag_z = 1;
    apply(enc_i8(4'h4, 3'b001, 8'h10));
    chk1(90, "pc_load   ", pc_load,   1'b1);
    chk8(91, "pc_target ", pc_target, 8'h10);

    $display("--- JZ 0x10 not taken (Z=0) ---");
    flag_z = 0;
    apply(enc_i8(4'h4, 3'b001, 8'h10));
    chk1(92, "pc_load   ", pc_load,   1'b0);

    $display("--- JNZ 0x20 taken (Z=0) ---");
    flag_z = 0;
    apply(enc_i8(4'h4, 3'b010, 8'h20));
    chk1(93, "pc_load   ", pc_load,   1'b1);

    $display("--- JNZ 0x20 not taken (Z=1) ---");
    flag_z = 1;
    apply(enc_i8(4'h4, 3'b010, 8'h20));
    chk1(94, "pc_load   ", pc_load,   1'b0);
    flag_z = 0;

    $display("--- JC taken (C=1) ---");
    flag_c = 1;
    apply(enc_i8(4'h4, 3'b011, 8'h30));
    chk1(95, "pc_load JC", pc_load,   1'b1);

    $display("--- JNC not taken (C=1) ---");
    apply(enc_i8(4'h4, 3'b100, 8'h30));
    chk1(96, "pc_load JNC", pc_load,  1'b0);

    $display("--- JN taken (N=1) ---");
    flag_c = 0; flag_n = 1;
    apply(enc_i8(4'h4, 3'b101, 8'h30));
    chk1(97, "pc_load JN", pc_load,   1'b1);
    flag_n = 0;

    $display("--- JV taken (V=1) ---");
    flag_v = 1;
    apply(enc_i8(4'h4, 3'b110, 8'h30));
    chk1(98, "pc_load JV", pc_load,   1'b1);
    flag_v = 0;

    // ------------------------------------------------------------------
    // Group 5: PUSH R3
    // 0101 000 011 xxxxxxxxx
    // ------------------------------------------------------------------
    $display("--- PUSH R3 ---");
    apply(enc_push(3'd3));
    chk3(100, "ra_addr    ", ra_addr,    3'd3);
    chk1(101, "stack_push ", stack_push, 1'b1);
    chk1(102, "stack_pop  ", stack_pop,  1'b0);
    chk1(103, "reg_we     ", reg_we,     1'b0);

    // ------------------------------------------------------------------
    // Group 5: POP R4 (Rd encoded in Ra field)
    // 0101 001 100 xxxxxxxxx
    // ------------------------------------------------------------------
    $display("--- POP R4 ---");
    apply(enc_pop(3'd4));
    chk3(110, "rd_addr    ", rd_addr,    3'd4);
    chk1(111, "stack_pop  ", stack_pop,  1'b1);
    chk1(112, "stack_push ", stack_push, 1'b0);
    chk1(113, "reg_we     ", reg_we,     1'b1);
    chk3(114, "wb_sel     ", wb_sel,     3'b011); // WB_STACK

    // ------------------------------------------------------------------
    // Group 5: CALL 0x50
    // 0101 010 0 01010000
    // ------------------------------------------------------------------
    $display("--- CALL 0x50 ---");
    apply(enc_i8(4'h5, 3'b010, 8'h50));
    chk1(120, "stack_push ", stack_push, 1'b1);
    chk1(121, "pc_load    ", pc_load,    1'b1);
    chk8(122, "pc_target  ", pc_target,  8'h50);
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
    // R-format: 0110 xxx 010 101 xxx
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
    // Group 7: CMPI R1, 10  (imm6 = 6'd10)
    // I-format: 0111 xxx 001 001010
    // ------------------------------------------------------------------
    $display("--- CMPI R1, 10 ---");
    apply(enc_i(4'h7, 3'bxxx, 3'd1, 6'd10));
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
    // Group 8: IN R5, port=001  — read hardware PRNG into register
    // Encoding: 1000 101 001 000 000  (group=8, rd=5, port=1)
    // ------------------------------------------------------------------
    $display("--- IN R5 (port=001, PRNG) ---");
    apply(16'h8A40);   // 1000 101 001 000 000  (group=8, rd=5, port=001)
    chk3(180, "rd_addr   ", rd_addr,   3'd5);
    chk1(181, "reg_we    ", reg_we,    1'b1);
    chk3(182, "wb_sel    ", wb_sel,    3'b100); // WB_PRNG
    chk1(183, "mem_we    ", mem_we,    1'b0);
    chk1(184, "pc_load   ", pc_load,   1'b0);
    chk1(185, "halt      ", halt,      1'b0);

    // IN with unknown port (port=000) — must behave as NOP
    $display("--- IN R5 (port=000, undefined) => NOP ---");
    apply(16'h8A00);   // 1000 101 000 000 000  (group=8, rd=5, port=000)
    chk1(186, "reg_we=0  ", reg_we,    1'b0);   // no write-back
    chk1(187, "mem_we=0  ", mem_we,    1'b0);
    chk1(188, "pc_load=0 ", pc_load,   1'b0);

    // IN R2, port=010 — GPIO input
    // Encoding: 1000 010 010 000 000
    //   group=8=1000, rd=2=010, port=2=010, rest=0
    //   1000_0100_1000_0000 = 0x8480
    $display("--- IN R2 (port=010, GPIO) ---");
    apply(16'h8480);
    chk3(189, "rd_addr   ", rd_addr,   3'd2);
    chk1(190, "reg_we    ", reg_we,    1'b1);
    chk3(191, "wb_sel    ", wb_sel,    3'b101); // WB_GPIO
    chk1(192, "mem_we    ", mem_we,    1'b0);
    chk1(193, "pc_load   ", pc_load,   1'b0);

    // IN R6, port=011 — GPIO direction (write-only, IN not supported → NOP)
    // Encoding: 1000 110 011 000 000
    //   group=8=1000, rd=6=110, port=3=011, rest=0
    //   1000_1100_1100_0000 = 0x8CC0
    $display("--- IN R6 (port=011, GPIO dir — NOP) ---");
    apply(16'h8CC0);
    chk1(194, "reg_we=0  ", reg_we,    1'b0);   // write-only port — no read-back
    chk1(195, "mem_we=0  ", mem_we,    1'b0);
    chk1(196, "pc_load=0 ", pc_load,   1'b0);

    // IN R6, port=100 — ADC value
    // Encoding: 1000 110 100 000 000
    //   group=8=1000, rd=6=110, port=4=100, rest=0
    //   1000_1101_0000_0000 = 0x8D00
    $display("--- IN R6 (port=100, ADC) ---");
    apply(16'h8D00);
    chk3(197, "rd_addr   ", rd_addr,   3'd6);
    chk1(198, "reg_we    ", reg_we,    1'b1);
    chk3(199, "wb_sel    ", wb_sel,    3'b110); // WB_ADC
    chk1(200, "mem_we    ", mem_we,    1'b0);
    chk1(201, "pc_load   ", pc_load,   1'b0);

    // ------------------------------------------------------------------
    // Group 9: OUT Ra, port — write register value to hardware peripheral
    //
    // Encoding: 1001 aaa ppp xxxxxxxx
    //   [11:9] Ra   — source register
    //   [8:6]  port — peripheral select
    //
    //  OUT R3, 1 = PRNG seed
    //    1001 011 001 000 000  = 0x9660  ... let's compute:
    //    group=9=1001, Ra=3=011, port=1=001, rest=0
    //    1001_0110_0100_0000 = 0x9640
    //  OUT R0, 2 = GPIO
    //    1001 000 010 000 000 = 0x9080
    //  OUT R7, 3 = DAC
    //    1001 111 011 000 000 = 0x9EC0
    //  OUT R0, 0 = undefined port → NOP
    //    1001 000 000 000 000 = 0x9000
    // ------------------------------------------------------------------
    $display("--- OUT R3 (port=001, PRNG seed) ---");
    apply(16'h9640);   // 1001 011 001 000 000
    chk3(240, "ra_addr   ", ra_addr,    3'd3);   // source reg = R3
    chk1(241, "periph_we ", periph_we,  1'b1);
    chk3(242, "periph_port", periph_port, 3'b001);
    chk1(243, "reg_we=0  ", reg_we,     1'b0);   // OUT never writes back
    chk1(244, "mem_we=0  ", mem_we,     1'b0);
    chk1(245, "pc_load=0 ", pc_load,    1'b0);

    $display("--- OUT R0 (port=010, GPIO) ---");
    apply(16'h9080);   // 1001 000 010 000 000
    chk3(200, "ra_addr   ", ra_addr,    3'd0);
    chk1(201, "periph_we ", periph_we,  1'b1);
    chk3(202, "periph_port", periph_port, 3'b010);
    chk1(203, "reg_we=0  ", reg_we,     1'b0);

    $display("--- OUT R7 (port=011, GPIO direction) ---");
    apply(16'h9EC0);   // 1001 111 011 000 000
    chk3(210, "ra_addr   ", ra_addr,    3'd7);
    chk1(211, "periph_we ", periph_we,  1'b1);
    chk3(212, "periph_port", periph_port, 3'b011);
    chk1(213, "reg_we=0  ", reg_we,     1'b0);

    $display("--- OUT R0 (port=000, undefined) => NOP ---");
    apply(16'h9000);   // 1001 000 000 000 000
    chk1(220, "periph_we=0", periph_we, 1'b0);
    chk1(221, "reg_we=0   ", reg_we,    1'b0);
    chk1(222, "pc_load=0  ", pc_load,   1'b0);

    // OUT R4, port=100 — undefined/NOP (ports 4–7 are reserved)
    // Encoding: 1001 100 100 000 000
    //   group=9=1001, Ra=4=100, port=4=100, rest=0
    //   1001_1001_0000_0000 = 0x9900
    $display("--- OUT R4 (port=100, undefined/NOP) ---");
    apply(16'h9900);
    chk3(230, "ra_addr    ", ra_addr,    3'd4);
    chk1(231, "periph_we=0", periph_we,  1'b0);
    chk3(232, "periph_port", periph_port, 3'b100);
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
