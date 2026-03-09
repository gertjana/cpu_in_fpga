#!/usr/bin/env python3
"""
assembler.py — Two-pass assembler for the CPU (8-bit data path, 16-bit address space).

All instructions are 24 bits wide.

Instruction format summary (non-ALU groups):
  Bits [23:20] — group (4 bits)
  Bits [19:17] — Rd / sub-opcode (3 bits)
  Bits [16:14] — Ra (3 bits)
  Bits [13:11] — Rb (3 bits)
  Bits [10:8]  — sub / extra Rb (3 bits)
  Bits [13:8]  — imm6  (I6-format: ADDI, CMPI)
  Bits [7:0]   — imm8  (I8-format: LDI)
  Bits [15:0]  — addr16 (I16-format: JMP, Jcc, CALL)

ALU group (0) uses an extended 4-bit sub-opcode field:
  Bits [19:16] — alu_op (4 bits; bit[3]=carry-in enable for ADC)
  Bits [15:13] — Rd (3 bits)
  Bits [12:10] — Ra (3 bits)
  Bits [9:7]   — Rb (3 bits)

Usage:
    python tools/assembler.py program.asm
    python tools/assembler.py -l program.asm          # also writes .lst
    python tools/assembler.py -o out.hex program.asm

Output: readmemh-compatible hex (one 6-digit hex word per line).
Errors are written to stderr with file:line: error: message format.
Exit code 0 = success, 1 = assembly error.
"""

import sys
import os
import re
import argparse
from typing import Optional


# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

class AsmError(Exception):
    """Assembly error with source location."""
    def __init__(self, message: str, filename: str = "", lineno: int = 0):
        self.message = message
        self.filename = filename
        self.lineno = lineno

    def __str__(self):
        if self.filename and self.lineno:
            return f"{self.filename}:{self.lineno}: error: {self.message}"
        elif self.filename:
            return f"{self.filename}: error: {self.message}"
        return f"error: {self.message}"


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REGISTERS = {f"R{i}": i for i in range(8)}

# Group encodings (bits [23:20])
GRP_ALU   = 0x0
GRP_ADDI  = 0x1
GRP_MEM   = 0x2
GRP_MOV   = 0x3
GRP_JUMP  = 0x4
GRP_STACK = 0x5
GRP_CMP   = 0x6
GRP_CMPI  = 0x7
GRP_IN    = 0x8
GRP_OUT   = 0x9
GRP_NOP   = 0xE
GRP_HALT  = 0xF

# ALU sub-opcodes (bits [19:16], 4-bit field)
# bit[3]=0: normal ops; bit[3]=1: carry-enabled variants
ALU_SUB = {
    "ADD": 0, "SUB": 1, "AND": 2, "OR": 3,
    "XOR": 4, "NOT": 5, "SHL": 6, "SHR": 7,
    "ADC": 8,   # Add with carry: alu_op=0b1000 → ADD with cin=flag_c
}

# Jump sub-opcodes (bits [19:17])
JUMP_SUB = {
    "JMP": 0, "JZ": 1, "JNZ": 2, "JC": 3,
    "JNC": 4, "JN": 5, "JV": 6, "JR": 7,
}

# Stack/subroutine sub-opcodes (bits [19:17])
STACK_SUB = {"PUSH": 0, "POP": 1, "CALL": 2, "RET": 3}

# MEM sub-opcodes (in Rd field, bits [19:17])
MEM_LDI  = 0  # handled specially — Rd is destination
MEM_LD   = 1  # handled specially
MEM_ST   = 2  # handled specially

# Field shift amounts for 24-bit encoding (non-ALU groups)
_SH_GRP  = 20   # group:   bits [23:20]
_SH_RD   = 17   # Rd/sub:  bits [19:17]
_SH_RA   = 14   # Ra:      bits [16:14]
_SH_RB   = 11   # Rb:      bits [13:11]
_SH_SUB  = 8    # sub/Rb:  bits [10:8]
_SH_IMM6 = 8    # imm6:    bits [13:8]
# imm8:   bits [7:0]  — no shift
# addr16: bits [15:0] — no shift

# ALU group (0) uses a 4-bit sub-opcode; register fields shift down by 1 bit
_SH_ALUOP = 16  # alu_op:  bits [19:16]
_SH_ALU_RD = 13 # Rd:      bits [15:13]
_SH_ALU_RA = 10 # Ra:      bits [12:10]
_SH_ALU_RB = 7  # Rb:      bits [9:7]


# ---------------------------------------------------------------------------
# Token / line parsing helpers
# ---------------------------------------------------------------------------

def strip_comment(line: str) -> str:
    """Remove ; comment from a line, respecting the whole line."""
    idx = line.find(";")
    return line[:idx] if idx >= 0 else line


def tokenize(line: str):
    """Return (mnemonic, [operands]) or (None, []) for blank lines."""
    line = strip_comment(line).strip()
    if not line:
        return None, []
    # Split on first whitespace to get mnemonic, then split rest on commas
    parts = line.split(None, 1)
    mnemonic = parts[0].upper()
    if len(parts) == 1:
        return mnemonic, []
    operands = [op.strip() for op in parts[1].split(",")]
    return mnemonic, operands


# ---------------------------------------------------------------------------
# Operand parsing
# ---------------------------------------------------------------------------

def parse_reg(token: str, filename: str, lineno: int) -> int:
    key = token.upper()
    if key not in REGISTERS:
        raise AsmError(f"unknown register '{token}'", filename, lineno)
    return REGISTERS[key]


def parse_imm(token: str, symbols: dict, filename: str, lineno: int,
              bits: int, signed_ok: bool = False) -> int:
    """
    Parse an immediate value.  token may be:
      - decimal literal: 42
      - hex literal:     0xFF
      - binary literal:  0b1010
      - symbol name:     LIMIT
      - simple expression: LIMIT-1, addr+2  (only +/- on two atoms)
    Result is checked to fit in `bits` unsigned bits.
    """
    token = token.strip()
    value = _eval_expr(token, symbols, filename, lineno)
    lo, hi = 0, (1 << bits) - 1
    if signed_ok:
        lo = -(1 << (bits - 1))
    if not (lo <= value <= hi):
        raise AsmError(
            f"immediate {value} out of range [{lo}, {hi}] for {bits}-bit field",
            filename, lineno)
    return value & ((1 << bits) - 1)


def _eval_atom(token: str, symbols: dict, filename: str, lineno: int) -> int:
    token = token.strip()
    # Symbol lookup
    if token in symbols:
        return symbols[token]
    if token.upper() in symbols:
        return symbols[token.upper()]
    # Numeric literal
    try:
        return int(token, 0)  # auto-detects 0x, 0b, 0o, decimal
    except ValueError:
        raise AsmError(f"undefined symbol or bad literal '{token}'", filename, lineno)


def _eval_expr(expr: str, symbols: dict, filename: str, lineno: int) -> int:
    """Evaluate a simple expression: atom  |  atom+atom  |  atom-atom."""
    expr = expr.strip()
    # Try splitting on + or - (but not inside 0x…)
    # We walk right-to-left to handle negative literals (0 - x)
    for op, i in _find_binary_op(expr):
        left  = _eval_atom(expr[:i].strip(), symbols, filename, lineno)
        right = _eval_atom(expr[i+1:].strip(), symbols, filename, lineno)
        return left + right if op == "+" else left - right
    return _eval_atom(expr, symbols, filename, lineno)


def _find_binary_op(expr: str):
    """
    Yield (op, index) for the last top-level +/- in expr (right-to-left),
    skipping 0x… hex prefixes.
    """
    i = len(expr) - 1
    while i > 0:
        ch = expr[i]
        if ch in "+-":
            # Make sure it's not the 'x' in '0x' or a leading sign
            prev = expr[:i].rstrip()
            if prev and not prev.endswith(("0x", "0X", "0b", "0B")):
                yield ch, i
                return
        i -= 1


# ---------------------------------------------------------------------------
# Instruction encoders
# All functions return a 24-bit integer.
#
# 24-bit field layout (non-ALU groups):
#   [23:20] group
#   [19:17] Rd / sub-opcode
#   [16:14] Ra
#   [13:11] Rb
#   [10:8]  sub / Rb-extra
#   [13:8]  imm6  (I6-format)
#   [7:0]   imm8  (I8-format)
#   [15:0]  addr16 (I16-format: JMP/Jcc/CALL)
#
# ALU group (0) layout:
#   [23:20] group=0
#   [19:16] alu_op (4-bit; bit[3]=cin enable)
#   [15:13] Rd
#   [12:10] Ra
#   [9:7]   Rb
# ---------------------------------------------------------------------------

def encode_alu(mnemonic, operands, symbols, filename, lineno) -> int:
    # ALU-format: 0000 ssss ddd aaa bbb 0000000
    #   [19:16] ALU sub-opcode (4 bits; bit[3]=carry-in enable)
    #   [15:13] Rd (destination)
    #   [12:10] Ra (source A)
    #   [9:7]   Rb (source B)
    sub = ALU_SUB[mnemonic]
    if mnemonic in ("NOT", "SHL", "SHR"):
        # Two-operand: Rd, Ra
        if len(operands) != 2:
            raise AsmError(f"{mnemonic} requires 2 operands: Rd, Ra", filename, lineno)
        rd = parse_reg(operands[0], filename, lineno)
        ra = parse_reg(operands[1], filename, lineno)
        rb = 0
    else:
        # Three-operand: Rd, Ra, Rb
        if len(operands) != 3:
            raise AsmError(f"{mnemonic} requires 3 operands: Rd, Ra, Rb", filename, lineno)
        rd = parse_reg(operands[0], filename, lineno)
        ra = parse_reg(operands[1], filename, lineno)
        rb = parse_reg(operands[2], filename, lineno)
    return (GRP_ALU << _SH_GRP) | (sub << _SH_ALUOP) | (rd << _SH_ALU_RD) | (ra << _SH_ALU_RA) | (rb << _SH_ALU_RB)


def encode_addi(operands, symbols, filename, lineno) -> int:
    # I6-format: 0001 ddd aaa iiiiii 00000000
    #   [19:17] Rd
    #   [16:14] Ra
    #   [13:8]  imm6
    if len(operands) != 3:
        raise AsmError("ADDI requires 3 operands: Rd, Ra, imm6", filename, lineno)
    rd  = parse_reg(operands[0], filename, lineno)
    ra  = parse_reg(operands[1], filename, lineno)
    imm = parse_imm(operands[2], symbols, filename, lineno, bits=6)
    return (GRP_ADDI << _SH_GRP) | (rd << _SH_RD) | (ra << _SH_RA) | (imm << _SH_IMM6)


def encode_ldi(operands, symbols, filename, lineno) -> int:
    # LDI Rd, imm8  →  0010 000 ddd xxxxxx iiiiiiii
    # Decoder: sub=MEM_LDI in [19:17], dest=f_ra in [16:14], imm8 in [7:0]
    if len(operands) != 2:
        raise AsmError("LDI requires 2 operands: Rd, imm8", filename, lineno)
    rd  = parse_reg(operands[0], filename, lineno)
    imm = parse_imm(operands[1], symbols, filename, lineno, bits=8)
    return (GRP_MEM << _SH_GRP) | (MEM_LDI << _SH_RD) | (rd << _SH_RA) | imm


def encode_ld(operands, symbols, filename, lineno) -> int:
    # LD Rd, [Ra]  →  0010 001 ddd aaa 00000000000
    # Decoder: sub=MEM_LD in [19:17], dest=f_ra in [16:14], addr=f_rb in [13:11]
    if len(operands) != 2:
        raise AsmError("LD requires 2 operands: Rd, [Ra]", filename, lineno)
    rd = parse_reg(operands[0], filename, lineno)
    ra_tok = operands[1].strip().lstrip("[").rstrip("]")
    ra = parse_reg(ra_tok, filename, lineno)
    return (GRP_MEM << _SH_GRP) | (MEM_LD << _SH_RD) | (rd << _SH_RA) | (ra << _SH_RB)


def encode_st(operands, symbols, filename, lineno) -> int:
    # ST [Ra], Rb  →  0010 010 xxx aaa bbb 00000000
    # Decoder: sub=MEM_ST in [19:17], addr=f_rb in [13:11], data=f_sub in [10:8]
    if len(operands) != 2:
        raise AsmError("ST requires 2 operands: [Ra], Rb", filename, lineno)
    ra_tok = operands[0].strip().lstrip("[").rstrip("]")
    ra = parse_reg(ra_tok, filename, lineno)
    rb = parse_reg(operands[1], filename, lineno)
    return (GRP_MEM << _SH_GRP) | (MEM_ST << _SH_RD) | (ra << _SH_RB) | (rb << _SH_SUB)


def encode_mov(operands, symbols, filename, lineno) -> int:
    # MOV Rd, Ra  →  0011 ddd aaa 000000000000000
    if len(operands) != 2:
        raise AsmError("MOV requires 2 operands: Rd, Ra", filename, lineno)
    rd = parse_reg(operands[0], filename, lineno)
    ra = parse_reg(operands[1], filename, lineno)
    return (GRP_MOV << _SH_GRP) | (rd << _SH_RD) | (ra << _SH_RA)


def encode_jump(mnemonic, operands, symbols, filename, lineno) -> int:
    sub = JUMP_SUB[mnemonic]
    if mnemonic == "JR":
        # JR Ra  →  0100 111 aaa 000000000000000
        if len(operands) != 1:
            raise AsmError("JR requires 1 operand: Ra", filename, lineno)
        ra = parse_reg(operands[0], filename, lineno)
        return (GRP_JUMP << _SH_GRP) | (sub << _SH_RD) | (ra << _SH_RA)
    else:
        # JMP/Jcc addr16  →  0100 sub x aaaaaaaaaaaaaaaa
        if len(operands) != 1:
            raise AsmError(f"{mnemonic} requires 1 operand: addr16", filename, lineno)
        addr = parse_imm(operands[0], symbols, filename, lineno, bits=16)
        return (GRP_JUMP << _SH_GRP) | (sub << _SH_RD) | addr


def encode_push(operands, symbols, filename, lineno) -> int:
    # PUSH Ra  →  0101 000 aaa 000000000000000
    if len(operands) != 1:
        raise AsmError("PUSH requires 1 operand: Ra", filename, lineno)
    ra = parse_reg(operands[0], filename, lineno)
    return (GRP_STACK << _SH_GRP) | (STACK_SUB["PUSH"] << _SH_RD) | (ra << _SH_RA)


def encode_pop(operands, symbols, filename, lineno) -> int:
    # POP Rd  →  0101 001 ddd 000000000000000
    if len(operands) != 1:
        raise AsmError("POP requires 1 operand: Rd", filename, lineno)
    rd = parse_reg(operands[0], filename, lineno)
    return (GRP_STACK << _SH_GRP) | (STACK_SUB["POP"] << _SH_RD) | (rd << _SH_RA)


def encode_call(operands, symbols, filename, lineno) -> int:
    # CALL addr16  →  0101 010 x aaaaaaaaaaaaaaaa
    if len(operands) != 1:
        raise AsmError("CALL requires 1 operand: addr16", filename, lineno)
    addr = parse_imm(operands[0], symbols, filename, lineno, bits=16)
    return (GRP_STACK << _SH_GRP) | (STACK_SUB["CALL"] << _SH_RD) | addr


def encode_ret(operands, symbols, filename, lineno) -> int:
    # RET  →  0101 011 000 000000000000000
    if operands:
        raise AsmError("RET takes no operands", filename, lineno)
    return (GRP_STACK << _SH_GRP) | (STACK_SUB["RET"] << _SH_RD)


def encode_cmp(operands, symbols, filename, lineno) -> int:
    # CMP Ra, Rb  →  0110 000 aaa bbb 00000000000
    #   [16:14] Ra
    #   [13:11] Rb
    if len(operands) != 2:
        raise AsmError("CMP requires 2 operands: Ra, Rb", filename, lineno)
    ra = parse_reg(operands[0], filename, lineno)
    rb = parse_reg(operands[1], filename, lineno)
    return (GRP_CMP << _SH_GRP) | (ra << _SH_RA) | (rb << _SH_RB)


def encode_cmpi(operands, symbols, filename, lineno) -> int:
    # CMPI Ra, imm6  →  0111 000 aaa iiiiii 00000000
    #   [16:14] Ra
    #   [13:8]  imm6
    if len(operands) != 2:
        raise AsmError("CMPI requires 2 operands: Ra, imm6", filename, lineno)
    ra  = parse_reg(operands[0], filename, lineno)
    imm = parse_imm(operands[1], symbols, filename, lineno, bits=6)
    return (GRP_CMPI << _SH_GRP) | (ra << _SH_RA) | (imm << _SH_IMM6)


def encode_in(operands, symbols, filename, lineno) -> int:
    # IN Rd, port  →  1000 ddd ppp 000000000000000  (port in bits [16:14])
    if len(operands) != 2:
        raise AsmError("IN requires 2 operands: Rd, port", filename, lineno)
    rd   = parse_reg(operands[0], filename, lineno)
    port = parse_imm(operands[1], symbols, filename, lineno, bits=3)
    return (GRP_IN << _SH_GRP) | (rd << _SH_RD) | (port << _SH_RA)


def encode_out(operands, symbols, filename, lineno) -> int:
    # OUT Ra, port  →  1001 aaa ppp 000000000000000  (Ra in [19:17], port in [16:14])
    if len(operands) != 2:
        raise AsmError("OUT requires 2 operands: Ra, port", filename, lineno)
    ra   = parse_reg(operands[0], filename, lineno)
    port = parse_imm(operands[1], symbols, filename, lineno, bits=3)
    return (GRP_OUT << _SH_GRP) | (ra << _SH_RD) | (port << _SH_RA)


def encode_nop(operands, filename, lineno) -> int:
    if operands:
        raise AsmError("NOP takes no operands", filename, lineno)
    return GRP_NOP << _SH_GRP


def encode_halt(operands, filename, lineno) -> int:
    if operands:
        raise AsmError("HALT takes no operands", filename, lineno)
    return GRP_HALT << _SH_GRP


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

ALL_MNEMONICS = set(ALU_SUB) | set(JUMP_SUB) | set(STACK_SUB) | {
    "ADDI", "LDI", "LD", "ST", "MOV", "CMP", "CMPI", "IN", "OUT", "NOP", "HALT"
}


def encode_instruction(mnemonic, operands, symbols, filename, lineno) -> int:
    if mnemonic in ALU_SUB:
        return encode_alu(mnemonic, operands, symbols, filename, lineno)
    if mnemonic == "ADDI":
        return encode_addi(operands, symbols, filename, lineno)
    if mnemonic == "LDI":
        return encode_ldi(operands, symbols, filename, lineno)
    if mnemonic == "LD":
        return encode_ld(operands, symbols, filename, lineno)
    if mnemonic == "ST":
        return encode_st(operands, symbols, filename, lineno)
    if mnemonic == "MOV":
        return encode_mov(operands, symbols, filename, lineno)
    if mnemonic in JUMP_SUB:
        return encode_jump(mnemonic, operands, symbols, filename, lineno)
    if mnemonic == "PUSH":
        return encode_push(operands, symbols, filename, lineno)
    if mnemonic == "POP":
        return encode_pop(operands, symbols, filename, lineno)
    if mnemonic == "CALL":
        return encode_call(operands, symbols, filename, lineno)
    if mnemonic == "RET":
        return encode_ret(operands, symbols, filename, lineno)
    if mnemonic == "CMP":
        return encode_cmp(operands, symbols, filename, lineno)
    if mnemonic == "CMPI":
        return encode_cmpi(operands, symbols, filename, lineno)
    if mnemonic == "NOP":
        return encode_nop(operands, filename, lineno)
    if mnemonic == "IN":
        return encode_in(operands, symbols, filename, lineno)
    if mnemonic == "OUT":
        return encode_out(operands, symbols, filename, lineno)
    if mnemonic == "HALT":
        return encode_halt(operands, filename, lineno)
    raise AsmError(f"unknown mnemonic '{mnemonic}'", filename, lineno)


# ---------------------------------------------------------------------------
# Two-pass assembler core
# ---------------------------------------------------------------------------

def assemble(source: str, filename: str = "<stdin>"):
    """
    Assemble `source` text.

    Returns:
        words   : list of (addr, word) where word is a 24-bit int
        listing : list of (addr, word_or_None, source_line) for listing output
    """
    lines = source.splitlines()
    symbols: dict[str, int] = {}   # label→addr and .equ name→value
    pc = 0
    errors = []

    # -----------------------------------------------------------------------
    # Pass 1 — collect labels and .equ constants, count instructions
    # -----------------------------------------------------------------------
    for lineno, raw in enumerate(lines, start=1):
        line = strip_comment(raw).strip()
        if not line:
            continue

        # Handle label(s) — a line may be  "label:"  or  "label: INSTR ..."
        while ":" in line:
            colon = line.index(":")
            label = line[:colon].strip()
            if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", label):
                errors.append(AsmError(f"invalid label '{label}'", filename, lineno))
                break
            if label.upper() in symbols or label in symbols:
                errors.append(AsmError(f"duplicate label '{label}'", filename, lineno))
            symbols[label] = pc
            symbols[label.upper()] = pc   # case-insensitive lookup
            line = line[colon+1:].strip()
            if not line:
                break

        if not line:
            continue

        mnemonic, operands = tokenize(line)
        if mnemonic is None:
            continue

        if mnemonic == ".EQU":
            # .equ NAME, value
            if len(operands) != 2:
                errors.append(AsmError(".equ requires NAME, value", filename, lineno))
                continue
            name = operands[0].strip()
            try:
                value = _eval_atom(operands[1].strip(), symbols, filename, lineno)
            except AsmError as e:
                errors.append(e)
                continue
            symbols[name] = value
            symbols[name.upper()] = value
            continue

        if mnemonic == ".ORG":
            if len(operands) != 1:
                errors.append(AsmError(".org requires one argument", filename, lineno))
                continue
            try:
                pc = _eval_atom(operands[0].strip(), symbols, filename, lineno)
            except AsmError as e:
                errors.append(e)
            continue

        if mnemonic not in ALL_MNEMONICS:
            errors.append(AsmError(f"unknown mnemonic '{mnemonic}'", filename, lineno))
            continue

        pc += 1

    if errors:
        raise errors[0]   # report first error — common assembler convention

    # -----------------------------------------------------------------------
    # Pass 2 — encode instructions
    # -----------------------------------------------------------------------
    words: list[tuple[int, int]] = []
    listing: list[tuple] = []   # (addr, word|None, raw_line)
    pc = 0

    for lineno, raw in enumerate(lines, start=1):
        line = strip_comment(raw).strip()

        # Blank / comment-only lines go into listing with no word
        if not line:
            listing.append((pc, None, raw))
            continue

        # Strip labels
        rest = line
        while ":" in rest:
            colon = rest.index(":")
            candidate = rest[:colon].strip()
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", candidate):
                rest = rest[colon+1:].strip()
            else:
                break

        if not rest:
            listing.append((pc, None, raw))
            continue

        mnemonic, operands = tokenize(rest)
        if mnemonic is None:
            listing.append((pc, None, raw))
            continue

        if mnemonic == ".EQU":
            listing.append((pc, None, raw))
            continue

        if mnemonic == ".ORG":
            pc = _eval_atom(operands[0].strip(), symbols, filename, lineno)
            listing.append((pc, None, raw))
            continue

        word = encode_instruction(mnemonic, operands, symbols, filename, lineno)
        listing.append((pc, word, raw))
        words.append((pc, word))
        pc += 1

    return words, listing


# ---------------------------------------------------------------------------
# Output writers
# ---------------------------------------------------------------------------

def write_hex(words: list, out_path: str):
    """Write plain readmemh-compatible hex (one 6-hex-digit word per line)."""
    with open(out_path, "w") as f:
        # Group words by address — fill gaps with 000000 if .org was used
        if not words:
            return
        max_addr = max(addr for addr, _ in words)
        word_map = {addr: w for addr, w in words}
        for addr in range(max_addr + 1):
            w = word_map.get(addr, 0)
            f.write(f"{w:06X}\n")


def write_listing(listing: list, lst_path: str):
    """Write a human-readable listing file."""
    with open(lst_path, "w") as f:
        f.write(f"{'Addr':>4}  {'Word':>6}  Source\n")
        f.write("-" * 62 + "\n")
        for addr, word, raw in listing:
            if word is not None:
                f.write(f"{addr:04X}  {word:06X}  {raw}\n")
            else:
                f.write(f"{'':4}  {'':6}  {raw}\n")


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Assembler for the CPU (8-bit data path, 16-bit address space)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("input", help="input .asm file")
    parser.add_argument("-o", "--output", help="output .hex file (default: input stem + .hex)")
    parser.add_argument("-l", "--listing", action="store_true",
                        help="also write a .lst listing file")
    args = parser.parse_args(argv)

    in_path = args.input
    stem = os.path.splitext(in_path)[0]
    out_path = args.output or stem + ".hex"
    lst_path = stem + ".lst"

    try:
        with open(in_path) as f:
            source = f.read()
    except OSError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    filename = os.path.basename(in_path)

    try:
        words, listing = assemble(source, filename)
    except AsmError as e:
        print(str(e), file=sys.stderr)
        return 1

    write_hex(words, out_path)
    print(f"Assembled {len(words)} words → {out_path}")

    if args.listing:
        write_listing(listing, lst_path)
        print(f"Listing → {lst_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
