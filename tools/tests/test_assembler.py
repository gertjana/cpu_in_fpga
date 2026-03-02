"""
pytest unit tests for tools/assembler.py

Each test assembles a snippet and checks the 16-bit hex word(s) produced.
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

class TestALU:
    def test_add(self):
        # ADD R1, R2, R3  → 0000 001 010 011 000 = 0x0053 ... let's compute
        # group=0, rd=1, ra=2, rb=3, sub=0
        # 0000 001 010 011 000 = 0000_0010_1001_1000 = 0x0298
        assert asm1("ADD R1, R2, R3") == 0x0298

    def test_sub(self):
        # SUB R0, R0, R1  → 0000 000 000 001 001 = 0x0009
        assert asm1("SUB R0, R0, R1") == 0x0009

    def test_and(self):
        # AND R3, R3, R4  → 0000 011 011 100 010 = 0x06E2
        assert asm1("AND R3, R3, R4") == 0x06E2

    def test_or(self):
        # OR R0, R1, R2  → 0000 000 001 010 011 = 0x0053
        assert asm1("OR R0, R1, R2") == 0x0053

    def test_xor(self):
        # XOR R5, R5, R5  → 0000 101 101 101 100 = 0x0B6C
        assert asm1("XOR R5, R5, R5") == 0x0B6C

    def test_not(self):
        # NOT R2, R3  → 0000 010 011 000 101 = 0x04C5
        assert asm1("NOT R2, R3") == 0x04C5

    def test_shl(self):
        # SHL R0, R0  → 0000 000 000 000 110 = 0x0006
        assert asm1("SHL R0, R0") == 0x0006

    def test_shr(self):
        # SHR R7, R7  → 0000 111 111 000 111 = 0x0FC7
        assert asm1("SHR R7, R7") == 0x0FC7

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

class TestADDI:
    def test_addi_basic(self):
        # ADDI R0, R0, 1  → 0001 000 000 000001 = 0x1001
        assert asm1("ADDI R0, R0, 1") == 0x1001

    def test_addi_max_imm(self):
        # ADDI R1, R2, 63  → 0001 001 010 111111 = 0x12BF
        assert asm1("ADDI R1, R2, 63") == 0x12BF

    def test_addi_hex_imm(self):
        assert asm1("ADDI R0, R0, 0x0A") == asm1("ADDI R0, R0, 10")

    def test_addi_imm_overflow(self):
        with pytest.raises(AsmError, match="out of range"):
            asm1("ADDI R0, R0, 64")

    def test_addi_wrong_operand_count(self):
        with pytest.raises(AsmError, match="3 operands"):
            asm1("ADDI R0, R0")


# ---------------------------------------------------------------------------
# Group 2 — Load / Store
# ---------------------------------------------------------------------------

class TestMemory:
    def test_ldi_zero(self):
        # LDI R0, 0  → 0010 000 000 000000 = 0x2000
        # group=2, sub=MEM_LDI=0 in [11:9], Rd=0 in [8:6], imm6=0 in [5:0]
        assert asm1("LDI R0, 0") == 0x2000

    def test_ldi_max(self):
        # LDI R0, 63  → 0010 000 000 111111 = 0x203F
        # max 6-bit immediate = 63
        assert asm1("LDI R0, 63") == 0x203F

    def test_ldi_r1_10(self):
        # LDI R1, 10  → 0010 000 001 001010 = 0x204A
        # group=2, sub=0 in [11:9], Rd=1 in [8:6], imm6=10 in [5:0]
        assert asm1("LDI R1, 10") == 0x204A

    def test_ldi_hex(self):
        # LDI R1, 0x3E  → same as LDI R1, 62 → 0x207E ... wait
        # 0x2000 | (1<<6) | 0x3E = 0x2000 | 0x40 | 0x3E = 0x207E
        assert asm1("LDI R1, 0x3E") == 0x207E

    def test_ldi_imm_overflow(self):
        with pytest.raises(AsmError, match="out of range"):
            asm1("LDI R0, 64")

    def test_ld(self):
        # LD R1, [R2]  → 0010 001 001 010 000 = 0x2250
        # group=2, sub=MEM_LD=1 in [11:9], Rd=1 in [8:6], Ra=2 in [5:3]
        assert asm1("LD R1, [R2]") == 0x2250

    def test_ld_no_brackets(self):
        # LD R0, [R0]  → 0010 001 000 000 000 = 0x2200
        # group=2, sub=MEM_LD=1 in [11:9], Rd=0 in [8:6], Ra=0 in [5:3]
        assert asm1("LD R0, [R0]") == 0x2200

    def test_st(self):
        # ST [R3], R4  → 0010 010 000 011 100 = 0x241C
        # group=2, sub=MEM_ST=2 in [11:9], addr=R3=3 in [5:3], data=R4=4 in [2:0]
        assert asm1("ST [R3], R4") == 0x241C

    def test_st_r0_r0(self):
        # ST [R0], R0  → 0010 010 000 000 000 = 0x2400
        assert asm1("ST [R0], R0") == 0x2400


# ---------------------------------------------------------------------------
# Group 3 — MOV
# ---------------------------------------------------------------------------

class TestMOV:
    def test_mov(self):
        # MOV R2, R5  → 0011 010 101 000000000 = 0x3540 ... wait
        # 0011 010 101 000 000 = 0011_0101_0100_0000 = 0x3540
        assert asm1("MOV R2, R5") == 0x3540

    def test_mov_r0_r0(self):
        # MOV R0, R0  → 0011 000 000 000000000 = 0x3000
        assert asm1("MOV R0, R0") == 0x3000

    def test_mov_wrong_operands(self):
        with pytest.raises(AsmError, match="2 operands"):
            asm1("MOV R0")


# ---------------------------------------------------------------------------
# Group 4 — Jumps
# ---------------------------------------------------------------------------

class TestJumps:
    def test_jmp(self):
        # JMP 0  → 0100 000 0 00000000 = 0x4000
        assert asm1("JMP 0") == 0x4000

    def test_jmp_addr(self):
        # JMP 2  → 0100 000 0 00000010 = 0x4002
        assert asm1("JMP 2") == 0x4002

    def test_jz(self):
        # JZ 5  → 0100 001 0 00000101 = 0x4205
        assert asm1("JZ 5") == 0x4205

    def test_jnz(self):
        # JNZ 2  → 0100 010 0 00000010 = 0x4402
        assert asm1("JNZ 2") == 0x4402

    def test_jc(self):
        # JC 0  → 0100 011 0 00000000 = 0x4600
        assert asm1("JC 0") == 0x4600

    def test_jnc(self):
        # JNC 0  → 0100 100 0 00000000 = 0x4800
        assert asm1("JNC 0") == 0x4800

    def test_jn(self):
        # JN 0  → 0100 101 0 00000000 = 0x4A00
        assert asm1("JN 0") == 0x4A00

    def test_jv(self):
        # JV 0  → 0100 110 0 00000000 = 0x4C00
        assert asm1("JV 0") == 0x4C00

    def test_jr(self):
        # JR R3  → 0100 111 011 00000000 = 0x4EC0 ... wait
        # 0100 111 011 000 00000 — but JR only uses Ra[8:6]
        # = 0100_1110_1100_0000 = 0x4EC0
        assert asm1("JR R3") == 0x4EC0

    def test_jmp_max_addr(self):
        # JMP 255  → 0100 000 0 11111111 = 0x40FF
        assert asm1("JMP 255") == 0x40FF

    def test_jmp_addr_overflow(self):
        with pytest.raises(AsmError, match="out of range"):
            asm1("JMP 256")


# ---------------------------------------------------------------------------
# Group 5 — Stack / subroutines
# ---------------------------------------------------------------------------

class TestStack:
    def test_push(self):
        # PUSH R1  → 0101 000 001 000000000 = 0x5040
        assert asm1("PUSH R1") == 0x5040

    def test_pop(self):
        # POP R2  → 0101 001 010 000000000 = 0x5280
        assert asm1("POP R2") == 0x5280

    def test_call(self):
        # CALL 10  → 0101 010 0 00001010 = 0x540A
        assert asm1("CALL 10") == 0x540A

    def test_ret(self):
        # RET  → 0101 011 000 000000000 = 0x5600
        assert asm1("RET") == 0x5600

    def test_push_all_regs(self):
        for r in range(8):
            w = asm1(f"PUSH R{r}")
            assert (w >> 12) == 0x5        # group 5
            assert (w >> 9) & 0x7 == 0     # sub = PUSH

    def test_ret_no_operands(self):
        with pytest.raises(AsmError, match="no operands"):
            asm1("RET R0")


# ---------------------------------------------------------------------------
# Group 6/7 — CMP / CMPI
# ---------------------------------------------------------------------------

class TestCMP:
    def test_cmp(self):
        # CMP R0, R1  → 0110 000 000 001 000 = 0x6008
        assert asm1("CMP R0, R1") == 0x6008

    def test_cmp_r3_r4(self):
        # CMP R3, R4  → 0110 000 011 100 000 = 0x60E0 ... wait
        # group=6, Rd=000 (unused), ra=3, rb=4, sub=0
        # 0110 000 011 100 000 = 0110_0000_1110_0000 = 0x60E0
        assert asm1("CMP R3, R4") == 0x60E0

    def test_cmpi(self):
        # CMPI R0, 5  → 0111 000 000 000101 = 0x7005
        assert asm1("CMPI R0, 5") == 0x7005

    def test_cmpi_max_imm(self):
        # CMPI R0, 63  → 0111 000 000 111111 = 0x703F
        assert asm1("CMPI R0, 63") == 0x703F

    def test_cmpi_overflow(self):
        with pytest.raises(AsmError, match="out of range"):
            asm1("CMPI R0, 64")


# ---------------------------------------------------------------------------
# Group 8 — IN (read hardware PRNG)
# ---------------------------------------------------------------------------

class TestIN:
    def test_in_r0_port1(self):
        # IN R0, 1  → 1000 000 001 000000 = 0x8040
        assert asm1("IN R0, 1") == 0x8040

    def test_in_r7_port1(self):
        # IN R7, 1  → 1000 111 001 000000 = 0x8E40
        assert asm1("IN R7, 1") == 0x8E40

    def test_in_r3_port1(self):
        # IN R3, 1  → 1000 011 001 000000 = 0x8640
        assert asm1("IN R3, 1") == 0x8640

    def test_in_port2(self):
        # IN R0, 2  → 1000 000 010 000000 = 0x8080
        assert asm1("IN R0, 2") == 0x8080

    def test_in_port7(self):
        # IN R0, 7  → 1000 000 111 000000 = 0x81C0
        assert asm1("IN R0, 7") == 0x81C0

    def test_in_port0(self):
        # IN R0, 0  → 1000 000 000 000000 = 0x8000  (undefined port, assembles fine)
        assert asm1("IN R0, 0") == 0x8000

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
# NOP / HALT
# ---------------------------------------------------------------------------

class TestNopHalt:
    def test_nop(self):
        # NOP  → 1110 xxxxxxxxxxxx, all zeros → 0xE000
        assert asm1("NOP") == 0xE000

    def test_halt(self):
        # HALT → 1111 xxxxxxxxxxxx → 0xF000
        assert asm1("HALT") == 0xF000

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
        # loop is at address 0, JMP 0 = 0x4000
        assert words == [0xE000, 0x4000]

    def test_forward_label(self):
        src = """
    JMP end
    NOP
end:
    HALT
"""
        words = asmn(src)
        # JMP 2 (end is at addr 2)
        assert words[0] == 0x4002
        assert words[2] == 0xF000

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
        # JNZ 1 = 0x4401  (sub=JNZ=2: 0100_010_0_00000001)
        assert words[2] == 0x4401

    def test_label_in_call(self):
        src = """
    CALL sub
    HALT
sub:
    RET
"""
        words = asmn(src)
        # CALL 2  → 0x5402
        assert words[0] == 0x5402

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
        assert asmn(src) == [0x204A]   # LDI R1, 10

    def test_equ_in_addi(self):
        src = """
.equ ONE, 1
    ADDI R0, R0, ONE
"""
        assert asmn(src) == [0x1001]

    def test_equ_in_jump(self):
        src = """
.equ TARGET, 5
    JMP TARGET
"""
        assert asmn(src) == [0x4005]

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
        assert asmn(src) == [0xE000]

    def test_inline_comment(self):
        assert asm1("NOP  ; no-op") == 0xE000

    def test_comment_after_label(self):
        src = """
start: NOP  ; start of program
    JMP start
"""
        assert asmn(src) == [0xE000, 0x4000]


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
# Full program — demo counter loop (matches quartus/program.hex)
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
        assert words == [0x2000, 0x2049, 0x1001, 0x6008, 0x4402, 0x4000]
