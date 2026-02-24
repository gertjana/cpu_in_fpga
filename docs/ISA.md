# Simple 8-bit CPU — ISA Specification

## Overview

- **Data width:** 8 bits
- **Address width:** 8 bits (256 locations)
- **Instruction width:** 16 bits (fixed)
- **Registers:** R0–R7 (8 general-purpose 8-bit registers)
- **Program Counter:** 8-bit PC
- **Stack:** Hardware stack, 16 entries deep
- **Architecture:** Harvard (separate program ROM and data RAM)
- **Flags:** Zero (Z), Carry (C), Negative (N), Overflow (V)

---

## Instruction Encoding

All instructions are 16 bits wide. Two formats are used:

### R-format (register operands)

```
[15:12]  group  — opcode group (4 bits)
[11:9]   Rd     — destination register (3 bits)
[8:6]    Ra     — source register A    (3 bits)
[5:3]    Rb     — source register B    (3 bits)
[2:0]    sub    — sub-opcode or unused (3 bits)
```

### I-format (immediate operand)

```
[15:12]  group  — opcode group (4 bits)
[11:9]   Rd     — destination / sub-opcode (3 bits)
[8:6]    Ra     — source register A         (3 bits)
[5:0]    imm6   — 6-bit immediate (zero-extended to 8 bits internally)
```

> **Why imm6?**  
> 16 bits − 4 (group) − 3 (Rd) − 3 (Ra) = **6 bits** left for the immediate.
> This gives a range of 0–63 for unsigned immediates, which is sufficient for
> most loop counters and small offsets on an 8-bit CPU.
> Jump targets and load-immediate values use a dedicated 8-bit immediate format
> (see I8-format below).

### I8-format (8-bit immediate, no Ra field)

Used where a full 8-bit constant is needed and Ra is not required:

```
[15:12]  group  — opcode group (4 bits)
[11:9]   Rd/sub — destination / sub-opcode (3 bits)
[8]      unused
[7:0]    imm8   — 8-bit immediate
```

Used by: **LDI**, **JMP/Jcc**, **CALL**.

---

## Opcode Groups and Instruction Table

### Group 0 — ALU Register-Register  `4'h0`

Format: R  
Encoding: `0000 ddd aaa bbb sss`  
Sub-opcode `sss` in bits `[2:0]`:

| `sss` | Mnemonic | Operation              | Flags updated |
|-------|----------|------------------------|---------------|
| `000` | ADD      | Rd = Ra + Rb           | Z C N V       |
| `001` | SUB      | Rd = Ra − Rb           | Z C N V       |
| `010` | AND      | Rd = Ra & Rb           | Z N           |
| `011` | OR       | Rd = Ra \| Rb          | Z N           |
| `100` | XOR      | Rd = Ra ^ Rb           | Z N           |
| `101` | NOT      | Rd = ~Ra               | Z N           |
| `110` | SHL      | Rd = Ra << 1           | Z C N         |
| `111` | SHR      | Rd = Ra >> 1 (logical) | Z C N         |

### Group 1 — ADDI (add immediate)  `4'h1`

Format: I  
Encoding: `0001 ddd aaa iiiiii`  
Operation: `Rd = Ra + imm6`  (imm6 zero-extended to 8 bits)  
Flags updated: Z C N V

### Group 2 — Load / Store  `4'h2`

Sub-opcode in `Rd` field bits `[11:9]`:

| Sub | Format | Mnemonic | Encoding                   | Operation          |
|-----|--------|----------|----------------------------|--------------------|
| 000 | I8     | LDI      | `0010 ddd x iiiiiiii`      | Rd = imm8          |
| 001 | R      | LD       | `0010 ddd aaa xxx xxxxx`   | Rd = MEM[Ra]       |
| 010 | R      | ST       | `0010 xxx aaa bbb xxxxx`   | MEM[Ra] = Rb       |

### Group 3 — MOV  `4'h3`

Format: R  
Encoding: `0011 ddd aaa xxx xxx`  
Operation: `Rd = Ra`  
Flags: none

### Group 4 — Jump / Branch  `4'h4`

Format: I8 (or R for JR)  
Sub-opcode in `[11:9]`:

| Sub | Mnemonic | Condition   | Encoding                  |
|-----|----------|-------------|---------------------------|
| 000 | JMP      | Always      | `0100 000 x iiiiiiii`     |
| 001 | JZ       | Z = 1       | `0100 001 x iiiiiiii`     |
| 010 | JNZ      | Z = 0       | `0100 010 x iiiiiiii`     |
| 011 | JC       | C = 1       | `0100 011 x iiiiiiii`     |
| 100 | JNC      | C = 0       | `0100 100 x iiiiiiii`     |
| 101 | JN       | N = 1       | `0100 101 x iiiiiiii`     |
| 110 | JV       | V = 1       | `0100 110 x iiiiiiii`     |
| 111 | JR       | Always      | `0100 111 aaa xxxxxxxx`   |

Lower 8 bits `[7:0]` = absolute jump target for JMP/Jcc.  
JR uses `Ra` from `[8:6]` as the jump target register (indirect jump).

### Group 5 — Stack / Subroutines  `4'h5`

Sub-opcode in `[11:9]`:

| Sub | Mnemonic | Encoding                   | Operation              |
|-----|----------|----------------------------|------------------------|
| 000 | PUSH     | `0101 000 aaa xxxxxxxxx`   | Stack[--SP] = Ra       |
| 001 | POP      | `0101 001 ddd xxxxxxxxx`   | Rd = Stack[SP++]       |
| 010 | CALL     | `0101 010 x iiiiiiii`      | PUSH(PC+1); PC = imm8  |
| 011 | RET      | `0101 011 xxx xxxxxxxxx`   | PC = POP()             |

### Group 6 — CMP  `4'h6`

Format: R  
Encoding: `0110 xxx aaa bbb xxx`  
Operation: flags from `Ra − Rb`, result discarded  
Flags updated: Z C N V

### Group 7 — CMPI  `4'h7`

Format: I  
Encoding: `0111 xxx aaa iiiiii`  
Operation: flags from `Ra − imm6`, result discarded  
Flags updated: Z C N V

### Group 14 — NOP  `4'hE`

Encoding: `1110 xxxxxxxxxxxx`  
No operation, no side effects.

### Group 15 — HALT  `4'hF`

Encoding: `1111 xxxxxxxxxxxx`  
Stops execution; PC holds current value.

---

## Flag Behaviour

| Flag | Meaning                          | Set by                              |
|------|----------------------------------|-------------------------------------|
| Z    | Result is zero                   | ADD SUB AND OR XOR NOT SHL SHR ADDI CMP CMPI |
| C    | Unsigned carry-out or borrow     | ADD SUB SHL SHR ADDI CMP CMPI       |
| N    | Result bit 7 is 1 (negative)     | ADD SUB AND OR XOR NOT SHL SHR ADDI CMP CMPI |
| V    | Signed overflow                  | ADD SUB ADDI CMP CMPI               |

Flags are **not** updated by: LDI LD ST MOV JMP Jcc JR PUSH POP CALL RET NOP HALT.

---

## Register File

| Name | Index |
|------|-------|
| R0   | 3'b000 |
| R1   | 3'b001 |
| R2   | 3'b010 |
| R3   | 3'b011 |
| R4   | 3'b100 |
| R5   | 3'b101 |
| R6   | 3'b110 |
| R7   | 3'b111 |

---

## Memory Map

| Range     | Usage                                     |
|-----------|-------------------------------------------|
| 0x00–0xFF | Program ROM (Harvard — separate space)    |
| 0x00–0xFF | Data RAM   (Harvard — separate space)     |

Stack is implemented as a dedicated internal LIFO (16 entries), separate from data RAM.

---

## Example Program — Count from 0 to 9

```
; R0 = counter, initialised to 0
; R1 = limit (10)
; Loop until R0 == R1, then halt

        LDI  R0, 0       ; 0010 000 x 00000000
        LDI  R1, 10      ; 0010 001 x 00001010
loop:
        ADDI R0, R0, 1   ; 0001 000 000 000001   (imm6 = 1)
        CMP  R0, R1      ; 0110 xxx 000 001 xxx
        JNZ  loop        ; 0100 010 x 00000010   (addr of loop)
        HALT             ; 1111 xxxxxxxxxxxx
```

---

## Quick Encoding Reference

| Instruction      | Binary pattern                              |
|------------------|---------------------------------------------|
| ADD  Rd, Ra, Rb  | `0000 ddd aaa bbb 000`                      |
| SUB  Rd, Ra, Rb  | `0000 ddd aaa bbb 001`                      |
| AND  Rd, Ra, Rb  | `0000 ddd aaa bbb 010`                      |
| OR   Rd, Ra, Rb  | `0000 ddd aaa bbb 011`                      |
| XOR  Rd, Ra, Rb  | `0000 ddd aaa bbb 100`                      |
| NOT  Rd, Ra      | `0000 ddd aaa xxx 101`                      |
| SHL  Rd, Ra      | `0000 ddd aaa xxx 110`                      |
| SHR  Rd, Ra      | `0000 ddd aaa xxx 111`                      |
| ADDI Rd, Ra, imm6| `0001 ddd aaa iiiiii`                       |
| LDI  Rd, imm8    | `0010 ddd x iiiiiiii`                       |
| LD   Rd, [Ra]    | `0010 ddd aaa 001 xxxxx` *(sub in Ra field)*|
| ST   [Ra], Rb    | `0010 xxx aaa 010 bbb xx` *(sub in Ra)*     |
| MOV  Rd, Ra      | `0011 ddd aaa xxxxxxxxx`                    |
| JMP  addr8       | `0100 000 x iiiiiiii`                       |
| JZ   addr8       | `0100 001 x iiiiiiii`                       |
| JNZ  addr8       | `0100 010 x iiiiiiii`                       |
| JC   addr8       | `0100 011 x iiiiiiii`                       |
| JNC  addr8       | `0100 100 x iiiiiiii`                       |
| JN   addr8       | `0100 101 x iiiiiiii`                       |
| JV   addr8       | `0100 110 x iiiiiiii`                       |
| JR   Ra          | `0100 111 aaa xxxxxxxx`                     |
| PUSH Ra          | `0101 000 aaa xxxxxxxxx`                    |
| POP  Rd          | `0101 001 ddd xxxxxxxxx`                    |
| CALL addr8       | `0101 010 x iiiiiiii`                       |
| RET              | `0101 011 xxx xxxxxxxxx`                    |
| CMP  Ra, Rb      | `0110 xxx aaa bbb xxx`                      |
| CMPI Ra, imm6    | `0111 xxx aaa iiiiii`                       |
| NOP              | `1110 xxxxxxxxxxxx`                         |
| HALT             | `1111 xxxxxxxxxxxx`                         |
