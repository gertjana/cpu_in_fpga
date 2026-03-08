"""
pytest unit tests for tools/assembler.py

Each test assembles a snippet and checks the 24-bit hex word(s) produced.
Helper asm1() assembles a single instruction and returns the word as an int.
"""

import sys
import os
import pytest

# Make the tools/ directory importable
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from assembler import assemble, AsmError


def asm1(source: str) -> int:
    """Assemble a single-instruction source, return the word as an int."""
    words, _ = assemble(source.strip())
    assert len(words) == 1, f"expected 1 word, got {len(words)}: {words}"
    return words[0][1]


def asmn(source: str) -> list[int]:
    """Assemble multi-instruction source, return list of ints."""
    words, _ = assemble(source.strip())
    return [w for _, w in words]


# ---------------------------------------------------------------------------
# Group 0 — ALU register-register
# ---------------------------------------------------------------------------
# 24-bit format: [23:20]=group [19:17]=alu_op [16:14]=rd [13:11]=ra [10:8]=rb [7:0]=0
# ADD R1,R2,R3: grp=0 op=0 rd=1 ra=2 rb=3 → 0x005300
# SUB R0,R0,R1: grp=0 op=1 rd=0 ra=0 rb=1 → 0x020100
# AND R3,R3,R4: grp=0 op=2 rd=3 ra=3 rb=4 → 0x04DC00
# OR  R0,R1,R2: grp=0 op=3 rd=0 ra=1 rb=2 → 0x060A00
# XOR R5,R5,R5: grp=0 op=4 rd=5 ra=5 rb=5 → 0x096D00
# NOT R2,R3:    grp=0 op=5 rd=2 ra=3 rb=0 → 0x0A9800
# SHL R0,R0:    grp=0 op=6 rd=0 ra=0 rb=0 → 0x0C0000
# SHR R7,R7:    grp=0 op=7 rd=7 ra=7 rb=0 → 0x0FF800

class TestALU:
    def test_add(self):
        assert asm1("ADD R1, R2, R3") == 0x005300

    def test_sub(self):
        assert asm1("SUB R0, R0, R1") == 0x020100

    def test_and(self):
        assert asm1("AND R3, R3, R4") == 0x04DC00

    def test_or(self):
        assert asm1("OR R0, R1, R2") == 0x060A00

    def test_xor(self):
        assert asm1("XOR R5, R5, R5") == 0x096D00

    def test_not(self):
        assert asm1("NOT R2, R3") == 0x0A9800

    def test_shl(self):
        assert asm1("SHL R0, R0") == 0x0C0000

    def test_shr(self):
        assert asm1("SHR R7, R7") == 0x0FF800

    def test_alu_case_insensitive(self):
        assert asm1("add r0, r1, r2") == asm1("ADD R0, R1, R2")

    def test_add_wrong_operand_count(self):
        with pytest.raises(AsmError, match="3 operands"):
            asm1("ADD R0, R1")

    def test_not_wrong_operand_count(self):
        with pytest.raises(AsmError, match="2 operands"):
            asm1("NOT R0, R1, R2")


# ---------------------------------------------------------------------------
# Group 1 — ADDI
# ---------------------------------------------------------------------------
# 24-bit: [23:20]=1 [19:17]=sub [16:14]=rd [13:8]=imm6 [7:0]=0
# ADDI R0,R0,1:  grp=1 rd=0 ra=0 imm6=1  → 0x100100
# ADDI R1,R2,63: grp=1 rd=1 ra=2 imm6=63 → 0x12BF00

class TestADDI:
    def test_addi_basic(self):
        assert asm1("ADDI R0, R0, 1") == 0x100100

    def test_addi_max_imm(self):
        assert asm1("ADDI R1, R2, 63") == 0x12BF00

    def test_addi_hex_imm(self):
        assert asm1("ADDI R0, R0, 0x0A") == asm1("ADDI R0, R0, 10")

    def test_addi_imm_overflow(self):
        with pytest.raises(AsmError, match="out of range"):
            asm1("ADDI R0, R0, 64")

    def test_addi_wrong_operand_count(self):
        with pytest.raises(AsmError, match="3 operands"):
            asm1("ADDI R0, R0")


# ---------------------------------------------------------------------------
# Group 2 — Load / Store / LDI
# ---------------------------------------------------------------------------
# LDI 24-bit: [23:20]=2 [19:17]=0 [16:14]=rd [13:8]=0 [7:0]=imm8
# LDI R0,0:    → 0x200000
# LDI R0,63:   → 0x20003F
# LDI R0,255:  → 0x2000FF  (max 8-bit immediate)
# LDI R1,10:   rd=1→[16:14]=001 → 0x20400A
# LDI R1,0x3E: → 0x20403E
# LD 24-bit:  [23:20]=2 [19:17]=1 [16:14]=rd [13:11]=ra [10:8]=0 [7:0]=0
# LD R1,[R2]: rd=1 ra=2 → 0x225000
# LD R0,[R0]: rd=0 ra=0 → 0x220000
# ST 24-bit:  [23:20]=2 [19:17]=2 [16:14]=0 [13:11]=ra [10:8]=rb [7:0]=0
# ST [R3],R4: ra=3 rb=4 → 0x241C00
# ST [R0],R0: ra=0 rb=0 → 0x240000

class TestMemory:
    def test_ldi_zero(self):
        assert asm1("LDI R0, 0") == 0x200000

    def test_ldi_max(self):
        # max 8-bit immediate = 255
        assert asm1("LDI R0, 255") == 0x2000FF

    def test_ldi_r1_10(self):
        assert asm1("LDI R1, 10") == 0x20400A

    def test_ldi_hex(self):
        assert asm1("LDI R1, 0x3E") == 0x20403E

    def test_ldi_imm_overflow(self):
        with pytest.raises(AsmError, match="out of range"):
            asm1("LDI R0, 256")

    def test_ld(self):
        assert asm1("LD R1, [R2]") == 0x225000

    def test_ld_no_brackets(self):
        assert asm1("LD R0, [R0]") == 0x220000

    def test_st(self):
        assert asm1("ST [R3], R4") == 0x241C00

    def test_st_r0_r0(self):
        assert asm1("ST [R0], R0") == 0x240000


# ---------------------------------------------------------------------------
# Group 3 — MOV
# ---------------------------------------------------------------------------
# 24-bit: [23:20]=3 [19:17]=0 [16:14]=rd [13:11]=ra [10:0]=0
# MOV R2,R5: rd=2 ra=5 → 0x354000
# MOV R0,R0: rd=0 ra=0 → 0x300000

class TestMOV:
    def test_mov(self):
        assert asm1("MOV R2, R5") == 0x354000

    def test_mov_r0_r0(self):
        assert asm1("MOV R0, R0") == 0x300000

    def test_mov_wrong_operands(self):
        with pytest.raises(AsmError, match="2 operands"):
            asm1("MOV R0")


# ---------------------------------------------------------------------------
# Group 4 — Jumps
# ---------------------------------------------------------------------------
# 24-bit: [23:20]=4 [19:17]=sub [16]=0 [15:0]=addr16
# JMP 0:   sub=0 addr=0x0000 → 0x400000
# JMP 2:   sub=0 addr=0x0002 → 0x400002
# JZ 5:    sub=1 addr=0x0005 → 0x420005
# JNZ 2:   sub=2 addr=0x0002 → 0x440002
# JC 0:    sub=3 addr=0x0000 → 0x460000
# JNC 0:   sub=4 addr=0x0000 → 0x480000
# JN 0:    sub=5 addr=0x0000 → 0x4A0000
# JV 0:    sub=6 addr=0x0000 → 0x4C0000
# JR R3:   sub=7 [16:14]=ra=3 → 0x4EC000
# JMP 0xFFFF: max 16-bit addr → 0x40FFFF

class TestJumps:
    def test_jmp(self):
        assert asm1("JMP 0") == 0x400000

    def test_jmp_addr(self):
        assert asm1("JMP 2") == 0x400002

    def test_jz(self):
        assert asm1("JZ 5") == 0x420005

    def test_jnz(self):
        assert asm1("JNZ 2") == 0x440002

    def test_jc(self):
        assert asm1("JC 0") == 0x460000

    def test_jnc(self):
        assert asm1("JNC 0") == 0x480000

    def test_jn(self):
        assert asm1("JN 0") == 0x4A0000

    def test_jv(self):
        assert asm1("JV 0") == 0x4C0000

    def test_jr(self):
        assert asm1("JR R3") == 0x4EC000

    def test_jmp_max_addr(self):
        # max 16-bit address = 65535
        assert asm1("JMP 65535") == 0x40FFFF

    def test_jmp_addr_overflow(self):
        with pytest.raises(AsmError, match="out of range"):
            asm1("JMP 65536")


# ---------------------------------------------------------------------------
# Group 5 — Stack / subroutines
# ---------------------------------------------------------------------------
# PUSH R1:  sub=0 rd=1→[16:14] → 0x504000
# POP R2:   sub=1 rd=2→[16:14] → 0x528000
# CALL 10:  sub=2 addr=0x000A  → 0x54000A
# RET:      sub=3              → 0x560000

class TestStack:
    def test_push(self):
        assert asm1("PUSH R1") == 0x504000

    def test_pop(self):
        assert asm1("POP R2") == 0x528000

    def test_call(self):
        assert asm1("CALL 10") == 0x54000A

    def test_ret(self):
        assert asm1("RET") == 0x560000

    def test_push_all_regs(self):
        for r in range(8):
            w = asm1(f"PUSH R{r}")
            assert (w >> 20) == 0x5        # group 5
            assert (w >> 17) & 0x7 == 0    # sub = PUSH

    def test_ret_no_operands(self):
        with pytest.raises(AsmError, match="no operands"):
            asm1("RET R0")


# ---------------------------------------------------------------------------
# Group 6/7 — CMP / CMPI
# ---------------------------------------------------------------------------
# CMP R0,R1:  grp=6 sub=0 rd=0 ra=0 rb=1 → 0x600800
# CMP R3,R4:  grp=6 sub=0 rd=0 ra=3 rb=4 → 0x60E000
# CMPI R0,5:  grp=7 sub=0 rd=0 ra=0 imm6=5  → 0x700500
# CMPI R0,63: grp=7 sub=0 rd=0 ra=0 imm6=63 → 0x703F00

class TestCMP:
    def test_cmp(self):
        assert asm1("CMP R0, R1") == 0x600800

    def test_cmp_r3_r4(self):
        assert asm1("CMP R3, R4") == 0x60E000

    def test_cmpi(self):
        assert asm1("CMPI R0, 5") == 0x700500

    def test_cmpi_max_imm(self):
        assert asm1("CMPI R0, 63") == 0x703F00

    def test_cmpi_overflow(self):
        with pytest.raises(AsmError, match="out of range"):
            asm1("CMPI R0, 64")


# ---------------------------------------------------------------------------
# Group 8 — IN (read hardware PRNG)
# ---------------------------------------------------------------------------
# 24-bit: [23:20]=8 [19:17]=rd [16:14]=port [13:0]=0
# IN R0,1: rd=0 port=1→[16:14]=001 → 0x804000
# IN R7,1: rd=7 port=1             → 0x8E4000
# IN R3,1: rd=3 port=1             → 0x864000
# IN R0,2: rd=0 port=2→[16:14]=010 → 0x808000
# IN R0,7: rd=0 port=7→[16:14]=111 → 0x81C000
# IN R0,0: rd=0 port=0             → 0x800000

class TestIN:
    def test_in_r0_port1(self):
        assert asm1("IN R0, 1") == 0x804000

    def test_in_r7_port1(self):
        assert asm1("IN R7, 1") == 0x8E4000

    def test_in_r3_port1(self):
        assert asm1("IN R3, 1") == 0x864000

    def test_in_port2(self):
        assert asm1("IN R0, 2") == 0x808000

    def test_in_port7(self):
        assert asm1("IN R0, 7") == 0x81C000

    def test_in_port0(self):
        # IN R0, 0 → undefined port, assembles fine
        assert asm1("IN R0, 0") == 0x800000

    def test_in_case_insensitive(self):
        assert asm1("in r5, 1") == asm1("IN R5, 1")

    def test_in_port_overflow(self):
        with pytest.raises(AsmError, match="out of range"):
            asm1("IN R0, 8")

    def test_in_wrong_operand_count_one(self):
        with pytest.raises(AsmError, match="2 operands"):
            asm1("IN R0")

    def test_in_wrong_operand_count_three(self):
        with pytest.raises(AsmError, match="2 operands"):
            asm1("IN R0, 1, 2")

    def test_in_no_operands(self):
        with pytest.raises(AsmError, match="2 operands"):
            asm1("IN")


# ---------------------------------------------------------------------------
# Group 9 — OUT (write hardware peripheral)
# ---------------------------------------------------------------------------
# 24-bit: [23:20]=9 [19:17]=rd [16:14]=port [13:0]=0
# OUT R0,1: rd=0 port=1 → 0x904000
# OUT R3,1: rd=3 port=1 → 0x964000
# OUT R7,1: rd=7 port=1 → 0x9E4000
# OUT R0,2: rd=0 port=2 → 0x908000
# OUT R0,3: rd=0 port=3 → 0x90C000
# OUT R0,7: rd=0 port=7 → 0x91C000
# OUT R0,0: rd=0 port=0 → 0x900000

class TestOUT:
    def test_out_r0_port1(self):
        assert asm1("OUT R0, 1") == 0x904000

    def test_out_r3_port1(self):
        assert asm1("OUT R3, 1") == 0x964000

    def test_out_r7_port1(self):
        assert asm1("OUT R7, 1") == 0x9E4000

    def test_out_port2_gpio(self):
        assert asm1("OUT R0, 2") == 0x908000

    def test_out_port3_gpio_dir(self):
        assert asm1("OUT R0, 3") == 0x90C000

    def test_out_port7(self):
        assert asm1("OUT R0, 7") == 0x91C000

    def test_out_port0(self):
        # OUT R0, 0 → undefined port, assembles fine
        assert asm1("OUT R0, 0") == 0x900000

    def test_out_case_insensitive(self):
        assert asm1("out r5, 1") == asm1("OUT R5, 1")

    def test_out_port_overflow(self):
        with pytest.raises(AsmError, match="out of range"):
            asm1("OUT R0, 8")

    def test_out_wrong_operand_count_one(self):
        with pytest.raises(AsmError, match="2 operands"):
            asm1("OUT R0")

    def test_out_wrong_operand_count_three(self):
        with pytest.raises(AsmError, match="2 operands"):
            asm1("OUT R0, 1, 2")

    def test_out_no_operands(self):
        with pytest.raises(AsmError, match="2 operands"):
            asm1("OUT")


# ---------------------------------------------------------------------------
# NOP / HALT
# ---------------------------------------------------------------------------
# NOP:  grp=E → 0xE00000
# HALT: grp=F → 0xF00000

class TestNopHalt:
    def test_nop(self):
        assert asm1("NOP") == 0xE00000

    def test_halt(self):
        assert asm1("HALT") == 0xF00000

    def test_nop_no_operands(self):
        with pytest.raises(AsmError, match="no operands"):
            asm1("NOP R0")

    def test_halt_no_operands(self):
        with pytest.raises(AsmError, match="no operands"):
            asm1("HALT R0")


# ---------------------------------------------------------------------------
# Labels
# ---------------------------------------------------------------------------

class TestLabels:
    def test_backward_label(self):
        src = """
loop:
    NOP
    JMP loop
"""
        words = asmn(src)
        # loop is at address 0, JMP 0 = 0x400000
        assert words == [0xE00000, 0x400000]

    def test_forward_label(self):
        src = """
    JMP end
    NOP
end:
    HALT
"""
        words = asmn(src)
        # JMP 2 (end is at addr 2) → 0x400002
        assert words[0] == 0x400002
        assert words[2] == 0xF00000

    def test_label_on_own_line(self):
        src = """
start:
    LDI R0, 0
loop:
    ADDI R0, R0, 1
    JNZ loop
"""
        words = asmn(src)
        # start=0, loop=1
        # JNZ 1 → sub=JNZ=2: 0x440001
        assert words[2] == 0x440001

    def test_label_in_call(self):
        src = """
    CALL sub
    HALT
sub:
    RET
"""
        words = asmn(src)
        # CALL 2 → 0x540002
        assert words[0] == 0x540002

    def test_undefined_label(self):
        with pytest.raises(AsmError, match="undefined"):
            asmn("JMP nowhere")

    def test_duplicate_label(self):
        with pytest.raises(AsmError, match="duplicate"):
            asmn("foo:\nfoo:\n NOP")


# ---------------------------------------------------------------------------
# .equ constants
# ---------------------------------------------------------------------------

class TestEqu:
    def test_equ_in_ldi(self):
        src = """
.equ LIMIT, 10
    LDI R1, LIMIT
"""
        assert asmn(src) == [0x20400A]   # LDI R1, 10

    def test_equ_in_addi(self):
        src = """
.equ ONE, 1
    ADDI R0, R0, ONE
"""
        assert asmn(src) == [0x100100]

    def test_equ_in_jump(self):
        src = """
.equ TARGET, 5
    JMP TARGET
"""
        assert asmn(src) == [0x400005]

    def test_equ_expression(self):
        src = """
.equ BASE, 10
    LDI R0, BASE+5
"""
        assert asmn(src) == [asm1("LDI R0, 15")]

    def test_equ_case_insensitive(self):
        src = """
.equ limit, 42
    LDI R0, LIMIT
"""
        assert asmn(src) == [asm1("LDI R0, 42")]


# ---------------------------------------------------------------------------
# Comments
# ---------------------------------------------------------------------------

class TestComments:
    def test_full_line_comment(self):
        src = """
; this is a comment
    NOP
"""
        assert asmn(src) == [0xE00000]

    def test_inline_comment(self):
        assert asm1("NOP  ; no-op") == 0xE00000

    def test_comment_after_label(self):
        src = """
start: NOP  ; start of program
    JMP start
"""
        assert asmn(src) == [0xE00000, 0x400000]


# ---------------------------------------------------------------------------
# Expressions in immediates
# ---------------------------------------------------------------------------

class TestExpressions:
    def test_addition(self):
        assert asm1("LDI R0, 10+5") == asm1("LDI R0, 15")

    def test_subtraction(self):
        assert asm1("LDI R0, 20-3") == asm1("LDI R0, 17")

    def test_hex_in_expr(self):
        assert asm1("LDI R0, 0x10+5") == asm1("LDI R0, 21")


# ---------------------------------------------------------------------------
# Error reporting
# ---------------------------------------------------------------------------

class TestErrors:
    def test_unknown_mnemonic(self):
        with pytest.raises(AsmError, match="unknown mnemonic"):
            asm1("BLAH R0")

    def test_unknown_register(self):
        with pytest.raises(AsmError, match="unknown register"):
            asm1("MOV R8, R0")

    def test_bad_immediate_symbol(self):
        with pytest.raises(AsmError, match="undefined"):
            asm1("LDI R0, NOTDEFINED")

    def test_error_has_lineno(self):
        src = "NOP\nBLAH R0\nHALT"
        try:
            asmn(src)
            assert False, "should have raised"
        except AsmError as e:
            assert e.lineno == 2
            assert "2" in str(e)


# ---------------------------------------------------------------------------
# Full program — demo counter loop
# ---------------------------------------------------------------------------

class TestFullProgram:
    def test_counter_loop(self):
        src = """
; Counter: R0 counts 0..8, compare to 9, loop, restart
        LDI  R0, 0       ; addr 0
        LDI  R1, 9       ; addr 1
loop:
        ADDI R0, R0, 1   ; addr 2
        CMP  R0, R1      ; addr 3
        JNZ  loop        ; addr 4  — loop is addr 2
        JMP  0           ; addr 5
"""
        words = asmn(src)
        assert words == [0x200000, 0x204009, 0x100100, 0x600800, 0x440002, 0x400000]
