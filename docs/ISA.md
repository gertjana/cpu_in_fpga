# Simple 8-bit CPU — ISA Specification

## Overview

- **Data width:** 8 bits
- **Address width:** 16 bits (65536 locations)
- **Instruction width:** 24 bits (fixed)
- **Registers:** R0–R7 (8 general-purpose 8-bit registers)
- **Program Counter:** 16-bit PC
- **Stack:** Hardware stack, 16 entries deep (16-bit entries for CALL/RET)
- **Architecture:** Harvard (separate program ROM and data RAM)
- **Flags:** Zero (Z), Carry (C), Negative (N), Overflow (V)

---

## Instruction Encoding

All instructions are **24 bits** wide. Several formats are used depending on the instruction group.

### R-format (register operands)

```
[23:20]  group   — opcode group (4 bits)
[19:17]  Rd/sub  — destination register or sub-opcode (3 bits)
[16:14]  Ra      — source register A (3 bits)
[13:11]  Rb      — source register B (3 bits)
[10:8]   sub     — extra sub-opcode / source Rb (3 bits)
[7:0]    unused
```

### I8-format (8-bit immediate)

All instructions that take an immediate operand place it consistently in the last byte `[7:0]`, giving a uniform range of 0–255:

```
[23:20]  group   — opcode group (4 bits)
[19:17]  Rd/sub  — destination register or sub-opcode (3 bits)
[16:14]  Ra      — source register A (3 bits)
[13:8]   unused
[7:0]    imm8    — 8-bit immediate (0–255)
```

Used by: **LDI**, **ADDI**, **CMPI**.

### I16-format (16-bit address)

```
[23:20]  group   — opcode group (4 bits)
[19:17]  sub     — sub-opcode (3 bits)
[18]     unused
[15:0]   addr16  — 16-bit jump/call target address
```

Used by: **JMP**, **Jcc**, **CALL**.

### ALU-format (extended 4-bit sub-opcode)

Group 0 (ALU) uses an extended sub-opcode that shifts all register fields down by one bit:

```
[23:20]  group=0000
[19:16]  alu_op  — 4-bit ALU sub-opcode (bit[3]=carry-in enable)
[15:13]  Rd      — destination register (3 bits)
[12:10]  Ra      — source register A (3 bits)
[9:7]    Rb      — source register B (3 bits)
[6:0]    unused
```

### IN/OUT-format (peripheral port)

```
[23:20]  group   — 4'h8 (IN) or 4'h9 (OUT)
[19:17]  Rd/Ra   — destination (IN) or source (OUT) register (3 bits)
[16:13]  pppp    — 4-bit peripheral port select (0–15)
[12:0]   unused
```

Port field `pppp` occupies bits `[16:13]`. Although bit 13 is used by other instruction formats, there is no conflict here because groups `4'h8` and `4'h9` are decoded using the IN/OUT format. Extending the port field into bit 13 is backward-compatible because the previous IN/OUT encoding left bits `[13:0]` unused.

---

## Opcode Groups and Instruction Table

| Group | Hex      | Instruction(s) |
|-------|----------|----------------|
| 0     | `4'h0`   | ALU register-register (ADD SUB AND OR XOR NOT SHL SHR ADC) |
| 1     | `4'h1`   | ADDI |
| 2     | `4'h2`   | LDI LD ST |
| 3     | `4'h3`   | MOV |
| 4     | `4'h4`   | JMP JZ JNZ JC JNC JN JV JR |
| 5     | `4'h5`   | PUSH POP CALL RET |
| 6     | `4'h6`   | CMP |
| 7     | `4'h7`   | CMPI |
| 8     | `4'h8`   | IN  (read peripheral) |
| 9     | `4'h9`   | OUT (write peripheral) |
| 10–13 | `4'hA`–`4'hD` | Reserved |
| 14    | `4'hE`   | NOP |
| 15    | `4'hF`   | HALT |

---

### Group 0 — ALU Register-Register  `4'h0`

Format: ALU  
Encoding: `0000 ssss ddd aaa bbb 0000000`

`alu_op[2:0]` selects the operation; `alu_op[3]=1` enables carry-in (ADC):

| `alu_op` | Mnemonic | Operation              | Flags updated |
|----------|----------|------------------------|---------------|
| `0000`   | ADD      | Rd = Ra + Rb           | Z C N V       |
| `0001`   | SUB      | Rd = Ra − Rb           | Z C N V       |
| `0010`   | AND      | Rd = Ra & Rb           | Z N           |
| `0011`   | OR       | Rd = Ra \| Rb          | Z N           |
| `0100`   | XOR      | Rd = Ra ^ Rb           | Z N           |
| `0101`   | NOT      | Rd = ~Ra               | Z N           |
| `0110`   | SHL      | Rd = Ra << 1           | Z C N         |
| `0111`   | SHR      | Rd = Ra >> 1 (logical) | Z C N         |
| `1000`   | ADC      | Rd = Ra + Rb + flag_C  | Z C N V       |

NOT, SHL, SHR are two-operand (Rd, Ra); Rb is ignored.  
ADC is identical to ADD but routes the carry flag into the adder carry-in.

---

### Group 1 — ADDI  `4'h1`

Format: I8  
Encoding: `0001 ddd aaa xxxxxx iiiiiiii`  
Operation: `Rd = Ra + imm8`  (0–255)  
Flags updated: Z C N V

---

### Group 2 — Load / Store  `4'h2`

Sub-opcode in Rd field `[19:17]`:

| Sub   | Format | Mnemonic | Encoding                               | Operation      |
|-------|--------|----------|----------------------------------------|----------------|
| `000` | I8     | LDI      | `0010 000 ddd xxxxxx iiiiiiii`         | Rd = imm8      |
| `001` | R      | LD       | `0010 001 ddd aaa xxxxxxxxxx`          | Rd = MEM[Ra]   |
| `010` | R      | ST       | `0010 010 xxx aaa bbb xxxxxxxx`        | MEM[Ra] = Rb   |

Notes:
- **LDI**: destination register in Ra field `[16:14]`, imm8 in `[7:0]`
- **LD**: destination register in Ra field `[16:14]`, address register in Rb field `[13:11]`
- **ST**: address register in Rb field `[13:11]`, data register in sub field `[10:8]`

---

### Group 3 — MOV  `4'h3`

Format: R  
Encoding: `0011 ddd aaa 000000000000000`  
Operation: `Rd = Ra`  
Flags: none  
Implemented as `Ra OR 0x00` through the ALU.

---

### Group 4 — Jump / Branch  `4'h4`

Sub-opcode in `[19:17]`:

| Sub   | Mnemonic | Condition | Encoding                              |
|-------|----------|-----------|---------------------------------------|
| `000` | JMP      | Always    | `0100 000 x aaaaaaaaaaaaaaaa`         |
| `001` | JZ       | Z = 1     | `0100 001 x aaaaaaaaaaaaaaaa`         |
| `010` | JNZ      | Z = 0     | `0100 010 x aaaaaaaaaaaaaaaa`         |
| `011` | JC       | C = 1     | `0100 011 x aaaaaaaaaaaaaaaa`         |
| `100` | JNC      | C = 0     | `0100 100 x aaaaaaaaaaaaaaaa`         |
| `101` | JN       | N = 1     | `0100 101 x aaaaaaaaaaaaaaaa`         |
| `110` | JV       | V = 1     | `0100 110 x aaaaaaaaaaaaaaaa`         |
| `111` | JR       | Always    | `0100 111 aaa 000000000000000`        |

Bits `[15:0]` = 16-bit absolute jump target for JMP/Jcc.  
JR uses `Ra` from `[16:14]` as the jump target register (indirect jump, 8-bit address zero-extended).

A 1-cycle flush NOP is inserted automatically after every taken branch/jump.

---

### Group 5 — Stack / Subroutines  `4'h5`

Sub-opcode in `[19:17]`:

| Sub   | Mnemonic | Encoding                               | Operation                    |
|-------|----------|----------------------------------------|------------------------------|
| `000` | PUSH     | `0101 000 aaa 000000000000000`         | Stack[--SP] = Ra             |
| `001` | POP      | `0101 001 ddd 000000000000000`         | Rd = Stack[SP++]             |
| `010` | CALL     | `0101 010 x aaaaaaaaaaaaaaaa`          | PUSH(PC+1); PC = addr16      |
| `011` | RET      | `0101 011 xxx 000000000000000`         | PC = POP()                   |

CALL pushes the 16-bit return address (the instruction after the CALL).  
RET pops the 16-bit return address.  
PUSH/POP push/pop 8-bit register values (zero-extended to 16 bits on the stack).

---

### Group 6 — CMP  `4'h6`

Format: R  
Encoding: `0110 xxx aaa bbb 00000000000`  
Operation: flags from `Ra − Rb`, result discarded  
Flags updated: Z C N V

---

### Group 7 — CMPI  `4'h7`

Format: I8  
Encoding: `0111 xxx aaa xxxxxx iiiiiiii`  
Operation: flags from `Ra − imm8`, result discarded  (0–255)  
Flags updated: Z C N V

---

### Group 8 — IN (read hardware peripheral)  `4'h8`

Format: IN/OUT  
Encoding: `1000 ddd pppp 0000000000000`  
Syntax: `IN Rd, port`  
Operation: `Rd = peripheral[port]` — reads the current value from the hardware peripheral selected by `port`  
Flags: none

Port field `pppp` is in bits `[16:13]` (range 0–15):

| Port    | Peripheral        | Direction | Description |
|---------|-------------------|-----------|-------------|
| `0`     | —                 | —         | Reserved — `IN` treated as NOP |
| `1`     | PRNG              | read      | 8-bit Galois LFSR hardware random number generator |
| `2`     | Onboard LEDs      | —         | Write-only; `IN` on port `2` is treated as NOP |
| `3`     | ADC               | read      | 8-bit sampled value from ADC channel 0 (ANAIN, PIN_D2). The MAX10 internal ADC samples the pin; returns 0x00 at 0V and 0xFF at 3.3V. |
| `4`     | GPIO direction    | —         | Write-only; `IN` on port `4` is treated as NOP |
| `5`     | GPIO data         | read      | Read current logic level of all 8 GPIO pins |
| `6`     | —                 | —         | Not yet implemented — reserved |
| `7`     | —                 | —         | Not yet implemented — reserved |
| `8`     | —                 | —         | Not yet implemented — reserved |
| `9`     | —                 | —         | Not yet implemented — reserved |
| `10`    | —                 | —         | Not yet implemented — reserved |
| `11`    | —                 | —         | Not yet implemented — reserved |
| `12`    | —                 | —         | Not yet implemented — reserved |
| `13`    | —                 | —         | Not yet implemented — reserved |
| `14`    | —                 | —         | Not yet implemented — reserved |
| `15`    | —                 | —         | Not yet implemented — reserved |

> The PRNG (port `1`) is an 8-bit Galois LFSR (polynomial x⁸ + x⁶ + x⁵ + x⁴ + 1, tap mask `0xB8`) that advances at the **board clock rate** (12 MHz), independent of the CPU clock. Each `IN` therefore samples the LFSR at a different phase, producing values that are effectively unpredictable from the program's perspective.

---

### Group 9 — OUT (write hardware peripheral)  `4'h9`

Format: IN/OUT  
Encoding: `1001 aaa pppp 0000000000000`  
Syntax: `OUT Ra, port`  
Operation: `peripheral[port] = Ra` — writes the value of `Ra` to the hardware peripheral selected by `port`  
Flags: none

Port field `pppp` is in bits `[16:13]` (range 0–15). Source register `Ra` is in bits `[19:17]`.

Port numbers are shared with `IN` where the same peripheral supports both read and write:

| Port    | Peripheral        | Direction  | Description |
|---------|-------------------|------------|-------------|
| `0`     | —                 | —          | Reserved — `OUT` treated as NOP |
| `1`     | PRNG seed         | write      | Load a seed value into the PRNG LFSR. Writing `0x00` is mapped to `0x01` internally. |
| `2`     | Onboard LEDs      | write      | Set all 8 onboard LEDs. Bit 7 = LED[0] (MSB), bit 0 = LED[7] (LSB). LEDs are active-low on the MAX1000. |
| `3`     | ADC               | —          | Read-only; `OUT` on port `3` is treated as NOP. |
| `4`     | GPIO direction    | write      | Set GPIO direction register (1 = output, 0 = input, per bit). Resets to `0x00` (all inputs) on CPU reset. |
| `5`     | GPIO data         | write      | Set all 8 GPIO output data pins simultaneously. Each bit maps to one pin (bit 0 = GPIO0, …, bit 7 = GPIO7). Only pins whose direction bit (port 4) is 1 drive the output. |
| `6`     | —                 | —          | Not yet implemented — reserved |
| `7`     | —                 | —          | Not yet implemented — reserved |
| `8`     | —                 | —          | Not yet implemented — reserved |
| `9`     | —                 | —          | Not yet implemented — reserved |
| `10`    | —                 | —          | Not yet implemented — reserved |
| `11`    | —                 | —          | Not yet implemented — reserved |
| `12`    | —                 | —          | Not yet implemented — reserved |
| `13`    | —                 | —          | Not yet implemented — reserved |
| `14`    | —                 | —          | Not yet implemented — reserved |
| `15`    | —                 | —          | Not yet implemented — reserved |

**Notes:**
- `OUT` has no effect on CPU registers or flags.
- The GPIO output data register holds its last written value until the CPU writes again or the board is reset.
- The GPIO direction register resets to `0x00` (all inputs) on CPU reset; data register resets to `0x00`.
- On reset, the PRNG seed returns to `0x01`.

**Example — seed the PRNG then read it:**
```asm
        LDI  R0, 42      ; seed value
        OUT  R0, 1       ; write seed to PRNG (port 1)
        IN   R1, 1       ; read first value from seeded PRNG
```

**Example — configure GPIO and read pins:**
```asm
        LDI  R0, 0xF0    ; upper 4 pins = output, lower 4 = input
        OUT  R0, 4       ; set GPIO direction (port 4)
        LDI  R1, 0xA0    ; output pattern for upper pins
        OUT  R1, 5       ; drive GPIO output data (port 5)
        IN   R2, 5       ; read back all 8 GPIO pin values (port 5)
```

**Example — read ADC:**
```asm
        IN   R0, 3       ; sample ADC into R0 (port 3)
```

---

### Group 14 — NOP  `4'hE`

Encoding: `1110 xxxxxxxxxxxxxxxxxxxx`  
No operation, no side effects.

---

### Group 15 — HALT  `4'hF`

Encoding: `1111 xxxxxxxxxxxxxxxxxxxx`  
Stops execution; PC holds current value. All subsequent instruction slots are filled with NOP permanently.

---

## Flag Behaviour

| Flag | Meaning                          | Set by                              |
|------|----------------------------------|-------------------------------------|
| Z    | Result is zero                   | ADD SUB ADC AND OR XOR NOT SHL SHR ADDI CMP CMPI |
| C    | Unsigned carry-out or borrow     | ADD SUB ADC SHL SHR ADDI CMP CMPI  |
| N    | Result bit 7 is 1 (negative)     | ADD SUB ADC AND OR XOR NOT SHL SHR ADDI CMP CMPI |
| V    | Signed overflow                  | ADD SUB ADC ADDI CMP CMPI           |

Flags are **not** updated by: LDI LD ST MOV JMP Jcc JR PUSH POP CALL RET IN OUT NOP HALT.

---

## Register File

| Name | Index    |
|------|----------|
| R0   | `3'b000` |
| R1   | `3'b001` |
| R2   | `3'b010` |
| R3   | `3'b011` |
| R4   | `3'b100` |
| R5   | `3'b101` |
| R6   | `3'b110` |
| R7   | `3'b111` |

---

## Memory Map

| Range         | Usage                                     |
|---------------|-------------------------------------------|
| 0x0000–0xFFFF | Program ROM (Harvard — separate space)    |
| 0x00–0xFF     | Data RAM   (Harvard — 256 byte data space)|

Stack is implemented as a dedicated internal LIFO (16 entries), separate from data RAM.

---

## Quick Encoding Reference

| Instruction       | Binary pattern (24 bits)                          |
|-------------------|---------------------------------------------------|
| ADD  Rd, Ra, Rb   | `0000 0000 ddd aaa bbb 0000000`                   |
| SUB  Rd, Ra, Rb   | `0000 0001 ddd aaa bbb 0000000`                   |
| AND  Rd, Ra, Rb   | `0000 0010 ddd aaa bbb 0000000`                   |
| OR   Rd, Ra, Rb   | `0000 0011 ddd aaa bbb 0000000`                   |
| XOR  Rd, Ra, Rb   | `0000 0100 ddd aaa bbb 0000000`                   |
| NOT  Rd, Ra       | `0000 0101 ddd aaa xxx 0000000`                   |
| SHL  Rd, Ra       | `0000 0110 ddd aaa xxx 0000000`                   |
| SHR  Rd, Ra       | `0000 0111 ddd aaa xxx 0000000`                   |
| ADC  Rd, Ra, Rb   | `0000 1000 ddd aaa bbb 0000000`                   |
| ADDI Rd, Ra, imm8 | `0001 ddd aaa xxxxxx iiiiiiii`                    |
| LDI  Rd, imm8     | `0010 000 ddd xxxxxx iiiiiiii`                    |
| LD   Rd, [Ra]     | `0010 001 ddd aaa xxxxxxxxxx`                     |
| ST   [Ra], Rb     | `0010 010 xxx aaa bbb xxxxxxxx`                   |
| MOV  Rd, Ra       | `0011 ddd aaa 000000000000000`                    |
| JMP  addr16       | `0100 000 x aaaaaaaaaaaaaaaa`                     |
| JZ   addr16       | `0100 001 x aaaaaaaaaaaaaaaa`                     |
| JNZ  addr16       | `0100 010 x aaaaaaaaaaaaaaaa`                     |
| JC   addr16       | `0100 011 x aaaaaaaaaaaaaaaa`                     |
| JNC  addr16       | `0100 100 x aaaaaaaaaaaaaaaa`                     |
| JN   addr16       | `0100 101 x aaaaaaaaaaaaaaaa`                     |
| JV   addr16       | `0100 110 x aaaaaaaaaaaaaaaa`                     |
| JR   Ra           | `0100 111 aaa 000000000000000`                    |
| PUSH Ra           | `0101 000 aaa 000000000000000`                    |
| POP  Rd           | `0101 001 ddd 000000000000000`                    |
| CALL addr16       | `0101 010 x aaaaaaaaaaaaaaaa`                     |
| RET               | `0101 011 xxx 000000000000000`                    |
| CMP  Ra, Rb       | `0110 xxx aaa bbb 00000000000`                    |
| CMPI Ra, imm8     | `0111 xxx aaa xxxxxx iiiiiiii`                    |
| IN   Rd, port     | `1000 ddd pppp 0000000000000`                     |
| OUT  Ra, port     | `1001 aaa pppp 0000000000000`                     |
| NOP               | `1110 xxxxxxxxxxxxxxxxxxxx`                       |
| HALT              | `1111 xxxxxxxxxxxxxxxxxxxx`                       |

---

## Example Program — Count from 0 to 9

```asm
; R0 = counter, R1 = limit (10)
; Loop until R0 == R1, then halt

        LDI  R0, 0       ; R0 = 0
        LDI  R1, 10      ; R1 = 10
loop:
        ADDI R0, R0, 1   ; R0++ (imm8: any value 0–255 works)
        CMP  R0, R1      ; set flags from R0 - R1
        JNZ  loop        ; loop while not equal
        HALT
```
