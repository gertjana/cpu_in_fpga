#!/usr/bin/env python3
"""
assembler.py — Two-pass assembler for the simple 8-bit CPU.

Usage:
    python tools/assembler.py program.asm
    python tools/assembler.py -l program.asm          # also writes .lst
    python tools/assembler.py -o out.hex program.asm

Output: Intel-format readmemh-compatible hex (one 4-digit hex word per line).
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

# Group encodings (bits [15:12])
GRP_ALU   = 0x0
GRP_ADDI  = 0x1
GRP_MEM   = 0x2
GRP_MOV   = 0x3
GRP_JUMP  = 0x4
GRP_STACK = 0x5
GRP_CMP   = 0x6
GRP_CMPI  = 0x7
GRP_NOP   = 0xE
GRP_HALT  = 0xF

# ALU sub-opcodes (bits [2:0])
ALU_SUB = {
    "ADD": 0, "SUB": 1, "AND": 2, "OR": 3,
    "XOR": 4, "NOT": 5, "SHL": 6, "SHR": 7,
}

# Jump sub-opcodes (bits [11:9])
JUMP_SUB = {
    "JMP": 0, "JZ": 1, "JNZ": 2, "JC": 3,
    "JNC": 4, "JN": 5, "JV": 6, "JR": 7,
}

# Stack/subroutine sub-opcodes (bits [11:9])
STACK_SUB = {"PUSH": 0, "POP": 1, "CALL": 2, "RET": 3}

# MEM sub-opcodes (in Rd field, bits [11:9])
MEM_LDI  = 0  # handled specially — Rd is destination
MEM_LD   = 1  # handled specially
MEM_ST   = 2  # handled specially


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
# ---------------------------------------------------------------------------

def encode_alu(mnemonic, operands, symbols, filename, lineno) -> int:
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
    return (GRP_ALU << 12) | (rd << 9) | (ra << 6) | (rb << 3) | sub


def encode_addi(operands, symbols, filename, lineno) -> int:
    if len(operands) != 3:
        raise AsmError("ADDI requires 3 operands: Rd, Ra, imm6", filename, lineno)
    rd  = parse_reg(operands[0], filename, lineno)
    ra  = parse_reg(operands[1], filename, lineno)
    imm = parse_imm(operands[2], symbols, filename, lineno, bits=6)
    return (GRP_ADDI << 12) | (rd << 9) | (ra << 6) | imm


def encode_ldi(operands, symbols, filename, lineno) -> int:
    # LDI Rd, imm6   → 0010 000 ddd iiiiii
    # Decoder: sub=MEM_LDI in f_rd [11:9], dest=f_ra [8:6], imm=f_imm6 [5:0]
    if len(operands) != 2:
        raise AsmError("LDI requires 2 operands: Rd, imm6", filename, lineno)
    rd  = parse_reg(operands[0], filename, lineno)
    imm = parse_imm(operands[1], symbols, filename, lineno, bits=6)
    return (GRP_MEM << 12) | (MEM_LDI << 9) | (rd << 6) | imm


def encode_ld(operands, symbols, filename, lineno) -> int:
    # LD Rd, [Ra]   → 0010 001 ddd aaa 000
    # Decoder: sub=MEM_LD in f_rd [11:9], dest=f_ra [8:6], addr=f_rb [5:3]
    if len(operands) != 2:
        raise AsmError("LD requires 2 operands: Rd, [Ra]", filename, lineno)
    rd = parse_reg(operands[0], filename, lineno)
    ra_tok = operands[1].strip().lstrip("[").rstrip("]")
    ra = parse_reg(ra_tok, filename, lineno)
    return (GRP_MEM << 12) | (MEM_LD << 9) | (rd << 6) | (ra << 3)


def encode_st(operands, symbols, filename, lineno) -> int:
    # ST [Ra], Rb   → 0010 010 xxx aaa bbb
    # Decoder: sub=MEM_ST in f_rd [11:9], addr=f_rb [5:3], data=f_sub [2:0]
    if len(operands) != 2:
        raise AsmError("ST requires 2 operands: [Ra], Rb", filename, lineno)
    ra_tok = operands[0].strip().lstrip("[").rstrip("]")
    ra = parse_reg(ra_tok, filename, lineno)
    rb = parse_reg(operands[1], filename, lineno)
    return (GRP_MEM << 12) | (MEM_ST << 9) | (ra << 3) | rb


def encode_mov(operands, symbols, filename, lineno) -> int:
    # MOV Rd, Ra   → 0011 ddd aaa 000000000
    if len(operands) != 2:
        raise AsmError("MOV requires 2 operands: Rd, Ra", filename, lineno)
    rd = parse_reg(operands[0], filename, lineno)
    ra = parse_reg(operands[1], filename, lineno)
    return (GRP_MOV << 12) | (rd << 9) | (ra << 6)


def encode_jump(mnemonic, operands, symbols, filename, lineno) -> int:
    sub = JUMP_SUB[mnemonic]
    if mnemonic == "JR":
        # JR Ra   → 0100 111 aaa 00000000
        if len(operands) != 1:
            raise AsmError("JR requires 1 operand: Ra", filename, lineno)
        ra = parse_reg(operands[0], filename, lineno)
        return (GRP_JUMP << 12) | (sub << 9) | (ra << 6)
    else:
        # JMP/Jcc addr8
        if len(operands) != 1:
            raise AsmError(f"{mnemonic} requires 1 operand: addr8", filename, lineno)
        addr = parse_imm(operands[0], symbols, filename, lineno, bits=8)
        return (GRP_JUMP << 12) | (sub << 9) | addr


def encode_push(operands, symbols, filename, lineno) -> int:
    # PUSH Ra   → 0101 000 aaa 000000000
    if len(operands) != 1:
        raise AsmError("PUSH requires 1 operand: Ra", filename, lineno)
    ra = parse_reg(operands[0], filename, lineno)
    return (GRP_STACK << 12) | (STACK_SUB["PUSH"] << 9) | (ra << 6)


def encode_pop(operands, symbols, filename, lineno) -> int:
    # POP Rd   → 0101 001 ddd 000000000
    if len(operands) != 1:
        raise AsmError("POP requires 1 operand: Rd", filename, lineno)
    rd = parse_reg(operands[0], filename, lineno)
    return (GRP_STACK << 12) | (STACK_SUB["POP"] << 9) | (rd << 6)


def encode_call(operands, symbols, filename, lineno) -> int:
    # CALL addr8   → 0101 010 x iiiiiiii
    if len(operands) != 1:
        raise AsmError("CALL requires 1 operand: addr8", filename, lineno)
    addr = parse_imm(operands[0], symbols, filename, lineno, bits=8)
    return (GRP_STACK << 12) | (STACK_SUB["CALL"] << 9) | addr


def encode_ret(operands, symbols, filename, lineno) -> int:
    if operands:
        raise AsmError("RET takes no operands", filename, lineno)
    return (GRP_STACK << 12) | (STACK_SUB["RET"] << 9)


def encode_cmp(operands, symbols, filename, lineno) -> int:
    # CMP Ra, Rb   → 0110 000 aaa bbb 000
    if len(operands) != 2:
        raise AsmError("CMP requires 2 operands: Ra, Rb", filename, lineno)
    ra = parse_reg(operands[0], filename, lineno)
    rb = parse_reg(operands[1], filename, lineno)
    return (GRP_CMP << 12) | (ra << 6) | (rb << 3)


def encode_cmpi(operands, symbols, filename, lineno) -> int:
    # CMPI Ra, imm6   → 0111 000 aaa iiiiii
    if len(operands) != 2:
        raise AsmError("CMPI requires 2 operands: Ra, imm6", filename, lineno)
    ra  = parse_reg(operands[0], filename, lineno)
    imm = parse_imm(operands[1], symbols, filename, lineno, bits=6)
    return (GRP_CMPI << 12) | (ra << 6) | imm


def encode_nop(operands, filename, lineno) -> int:
    if operands:
        raise AsmError("NOP takes no operands", filename, lineno)
    return GRP_NOP << 12


def encode_halt(operands, filename, lineno) -> int:
    if operands:
        raise AsmError("HALT takes no operands", filename, lineno)
    return GRP_HALT << 12


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

ALL_MNEMONICS = set(ALU_SUB) | set(JUMP_SUB) | set(STACK_SUB) | {
    "ADDI", "LDI", "LD", "ST", "MOV", "CMP", "CMPI", "NOP", "HALT"
}

# Directives that are not instructions but are handled in the main passes.
# .EQU and .ORG are handled inline; .OLED_LABEL is a macro that expands
# to a sequence of real instructions.
DIRECTIVES = {".EQU", ".ORG", ".OLED_LABEL"}


def expand_oled_label(text: str, filename: str, lineno: int) -> list:
    """
    Expand  .oled_label "text"  into a list of 16-bit instruction words.

    Writes up to 16 ASCII characters into RAM[0xF0..0xFF] using registers
    R4 (address pointer) and R5 (character value).  Existing values in R4/R5
    are clobbered.  Call this at program startup before the main loop.

    Encoding for the address (0xF0 = 240):
        LDI  R4, 60      ; R4 = 60 = 0x3C
        SHL  R4, R4      ; R4 = 120
        SHL  R4, R4      ; R4 = 240 = 0xF0

    Encoding for each character (ASCII value c):
        c <= 63 : LDI  R5, c
                  ST   [R4], R5
                  ADDI R4, R4, 1      (advance pointer, unless last char)
        c > 63  : LDI  R5, c-64      ; c-64 fits in 6 bits for printable ASCII (max 126-64=62)
                  ADDI R5, R5, 64     ; ... but 64 > 63, so instead:
                  ; We use:  LDI R5, (c>>1)  then SHL R5,R5  then ADDI R5,R5,(c&1)
                  ; This works for c up to 127.

    Uses 3 instruction address setup + 3–4 instructions per character.
    Total for 16 chars ≈ 3 + 16×3 = 51 instructions worst case.
    """
    # Strip surrounding quotes and limit to 16 chars, pad with spaces
    text = text.strip()
    if len(text) >= 2 and text[0] == '"' and text[-1] == '"':
        text = text[1:-1]
    elif len(text) >= 2 and text[0] == "'" and text[-1] == "'":
        text = text[1:-1]
    else:
        raise AsmError(".oled_label requires a quoted string", filename, lineno)

    text = text[:16].ljust(16)   # pad / truncate to exactly 16 chars

    words = []

    # Register indices
    R4 = 4
    R5 = 5

    def ldi(rd, imm6):
        return (GRP_MEM << 12) | (MEM_LDI << 9) | (rd << 6) | (imm6 & 0x3F)

    def addi(rd, ra, imm6):
        return (GRP_ADDI << 12) | (rd << 9) | (ra << 6) | (imm6 & 0x3F)

    def shl(rd, ra):
        return (GRP_ALU << 12) | (rd << 9) | (ra << 6) | (0 << 3) | ALU_SUB["SHL"]

    def st(ra, rb):
        # ST [Ra], Rb  → addr=Ra (f_rb field [5:3]), data=Rb (f_sub [2:0])
        return (GRP_MEM << 12) | (MEM_ST << 9) | (ra << 3) | rb

    # Address setup: R4 = 0xF0 = 240
    # LDI R4, 60  → SHL R4,R4  → SHL R4,R4  (60 → 120 → 240)
    words.append(ldi(R4, 60))
    words.append(shl(R4, R4))
    words.append(shl(R4, R4))

    for i, ch in enumerate(text):
        c = ord(ch) & 0xFF
        if c == 0:
            c = 0x20  # treat NUL as space

        # Load c into R5
        if c <= 63:
            words.append(ldi(R5, c))
        else:
            # c = 2*(c>>1) + (c&1); c>>1 <= 63 for c <= 127
            half = c >> 1
            bit0 = c & 1
            words.append(ldi(R5, half))
            words.append(shl(R5, R5))
            if bit0:
                words.append(addi(R5, R5, 1))

        # ST [R4], R5
        words.append(st(R4, R5))

        # ADDI R4, R4, 1  (advance pointer) — skip for last char
        if i < 15:
            words.append(addi(R4, R4, 1))

    return words


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
        words   : list of int (16-bit instruction words, in address order)
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

        if mnemonic == ".OLED_LABEL":
            # Macro: expands to a sequence of real instructions.
            # Count them in Pass 1 so labels after this directive get correct addresses.
            # Extract raw argument from line (everything after the mnemonic).
            raw_rest = line[len(".oled_label"):].strip() if line.lower().startswith(".oled_label") else ""
            try:
                expanded = expand_oled_label(raw_rest, filename, lineno)
            except AsmError as e:
                errors.append(e)
                continue
            pc += len(expanded)
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

        if mnemonic == ".OLED_LABEL":
            # Expand macro into a sequence of real instruction words.
            raw_rest = rest[len(".oled_label"):].strip() if rest.lower().startswith(".oled_label") else ""
            expanded = expand_oled_label(raw_rest, filename, lineno)
            listing.append((pc, None, raw))   # show directive as single listing line
            for w in expanded:
                words.append((pc, w))
                pc += 1
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
    """Write plain readmemh-compatible hex (one 4-hex-digit word per line)."""
    with open(out_path, "w") as f:
        # Group words by address — fill gaps with 0000 if .org was used
        if not words:
            return
        max_addr = max(addr for addr, _ in words)
        word_map = {addr: w for addr, w in words}
        for addr in range(max_addr + 1):
            w = word_map.get(addr, 0)
            f.write(f"{w:04X}\n")


def write_listing(listing: list, lst_path: str):
    """Write a human-readable listing file."""
    with open(lst_path, "w") as f:
        f.write(f"{'Addr':>4}  {'Word':>4}  Source\n")
        f.write("-" * 60 + "\n")
        for addr, word, raw in listing:
            if word is not None:
                f.write(f"{addr:04X}  {word:04X}  {raw}\n")
            else:
                f.write(f"{'':4}  {'':4}  {raw}\n")


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Assembler for the simple 8-bit CPU",
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
