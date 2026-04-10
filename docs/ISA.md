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
[11:9]   sub    — sub-opcode (Group 0) or destination register (other groups)
[8:6]    Rd     — destination register (Group 0) or source register A (other groups)
[5:3]    Ra     — source register A (Group 0) or source register B (other groups)
[2:0]    Rb     — source register B (Group 0) or unused
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

Used by: **JMP/Jcc**, **CALL**.

---

## Opcode Groups and Instruction Table

| Group | Hex | Instruction(s) |
|-------|-----|----------------|
| 0     | `4'h0` | ALU register-register (ADD SUB AND OR XOR NOT SHL SHR) |
| 1     | `4'h1` | ADDI |
| 2     | `4'h2` | LDI LD ST |
| 3     | `4'h3` | MOV |
| 4     | `4'h4` | JMP JZ JNZ JC JNC JN JV JR |
| 5     | `4'h5` | PUSH POP CALL RET |
| 6     | `4'h6` | CMP |
| 7     | `4'h7` | CMPI |
| 8     | `4'h8` | IN  (read peripheral) |
| 9     | `4'h9` | OUT (write peripheral) |
| 10–13 | `4'hA`–`4'hD` | Reserved |
| 14    | `4'hE` | NOP |
| 15    | `4'hF` | HALT |

### Group 0 — ALU Register-Register  `4'h0`

Format: R  
Encoding: `0000 sss ddd aaa bbb`  
Sub-opcode `sss` in bits `[11:9]`, destination `ddd` in bits `[8:6]`, source A `aaa` in bits `[5:3]`, source B `bbb` in bits `[2:0]`:

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

| Sub | Format | Mnemonic | Encoding                    | Operation          |
|-----|--------|----------|-----------------------------|--------------------|
| 000 | I      | LDI      | `0010 000 ddd iiiiii`       | Rd = imm6 (0–63)   |
| 001 | R      | LD       | `0010 001 ddd aaa xxx`      | Rd = MEM[Ra]       |
| 010 | R      | ST       | `0010 010 xxx aaa bbb`      | MEM[Ra] = Rb       |

Notes:
- **LDI**: destination register in bits `[8:6]`, 6-bit immediate in bits `[5:0]` (range 0–63)
- **LD**: destination register in bits `[8:6]`, address register in bits `[5:3]`
- **ST**: address register in bits `[5:3]`, data register in bits `[2:0]`

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

### Group 8 — IN (read hardware peripheral)  `4'h8`

Format: R  
Encoding: `1000 ddd ppp xxxxxxxx`  
Syntax: `IN Rd, port`  
Operation: `Rd = peripheral[port]` — reads the current value from the hardware peripheral selected by `port`  
Flags: none

Port field `ppp` is in bits `[8:6]` (range 0–7):

| Port | Peripheral   | Direction | Description |
|------|--------------|-----------|-------------|
| `1`  | PRNG         | read      | 8-bit Galois LFSR hardware random number generator |
| `2`  | GPIO input.  | read      | Read current logic level of all 8 GPIO pins (pins configured as input by `OUT Ra, 3`; pins configured as output return their driven value) |
| `3`  | GPIO dir.    | —         | Write-only; `IN` on port `3` is treated as NOP |
| `4`  | ADC          | read      | Read the 8-bit sampled value from ADC channel 0 (ANAIN, PIN_D2 — the dedicated analogue input pin on the MAX1000 board). The MAX10 internal ADC samples this pin and returns a 0–255 value proportional to the input voltage (0V = 0x00, 3.3V = 0xFF).   |
| `5`  | Accel X | read      | Read X-Axis of the Accelometer |
| `6`  | Accel Y | read      | Read Y-Axis of the Accelometer |
| `7`  | Accel S | read      | Read Z-Axis of the Accelometer |

The PRNG (port `1`) is an 8-bit Galois LFSR (polynomial x⁸ + x⁶ + x⁵ + x⁴ + 1, tap mask `0xB8`) that advances at the **board clock rate** (12 MHz), independent of the CPU clock. Each `IN` therefore samples the LFSR at a different phase, producing values that are effectively unpredictable from the program's perspective. Period: 255.

### Group 9 — OUT (write hardware peripheral)  `4'h9`

Format: R  
Encoding: `1001 aaa ppp xxxxxxxx`  
Syntax: `OUT Ra, port`  
Operation: `peripheral[port] = Ra` — writes the value of `Ra` to the hardware peripheral selected by `port`  
Flags: none

Port field `ppp` is in bits `[8:6]` (range 0–7). Source register `Ra` is in bits `[11:9]`.

Port numbers are shared with `IN` where the same peripheral supports both read and write:

| Port | Peripheral   | Direction  | Description |
|------|--------------|------------|-------------|
| `1`  | PRNG seed    | write      | Load a seed value into the PRNG LFSR. Clears the zero-lock guard automatically (writing `0x00` is mapped to `0x01`). |
| `2`  | GPIO out     | write      | Set all 8 GPIO output data pins simultaneously. Each bit maps to one pin (bit 0 = GPIO0, …, bit 7 = GPIO7). Only pins whose direction bit (port 3) is 1 drive the output. |
| `3`  | GPIO dir     | write      | Set GPIO direction register (1 = output, 0 = input, per bit). Resets to `0x00` (all inputs) on CPU reset. |
| `4`  | —            | —          | Reserved; `OUT` to port 4 is treated as NOP (MAX10 has no DAC). |
| `5`–`7` | —        | —          | Reserved for future peripherals; currently treated as NOP. |

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
        OUT  R0, 3       ; set GPIO direction
        LDI  R1, 0xA0    ; output pattern for upper pins
        OUT  R1, 2       ; drive GPIO output data
        IN   R2, 2       ; read back all 8 GPIO pin values
```

**Example — set GPIO outputs:**
```asm
        LDI  R0, 0x55    ; alternating high/low pattern (0101 0101)
        OUT  R0, 2       ; drive GPIO pins
```

**Example — read ADC:**
```asm
        IN   R0, 4       ; sample ADC into R0
```

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

Flags are **not** updated by: LDI LD ST MOV JMP Jcc JR PUSH POP CALL RET IN OUT NOP HALT.

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

        LDI  R0, 0       ; 0010 000 000 000000  (R0, imm6=0)
        LDI  R1, 10      ; 0010 000 001 001010  (R1, imm6=10)
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
| ADD  Rd, Ra, Rb  | `0000 000 ddd aaa bbb`                      |
| SUB  Rd, Ra, Rb  | `0000 001 ddd aaa bbb`                      |
| AND  Rd, Ra, Rb  | `0000 010 ddd aaa bbb`                      |
| OR   Rd, Ra, Rb  | `0000 011 ddd aaa bbb`                      |
| XOR  Rd, Ra, Rb  | `0000 100 ddd aaa bbb`                      |
| NOT  Rd, Ra      | `0000 101 ddd aaa xxx`                      |
| SHL  Rd, Ra      | `0000 110 ddd aaa xxx`                      |
| SHR  Rd, Ra      | `0000 111 ddd aaa xxx`                      |
| ADDI Rd, Ra, imm6| `0001 ddd aaa iiiiii`                       |
| LDI  Rd, imm6    | `0010 000 ddd iiiiii`                       |
| LD   Rd, [Ra]    | `0010 001 ddd aaa xxx`                      |
| ST   [Ra], Rb    | `0010 010 xxx aaa bbb`                      |
| MOV  Rd, Ra      | `0011 ddd aaa xxx xxx`                      |
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
| IN   Rd, port    | `1000 ddd ppp xxxxxxxx`                     |
| OUT  Ra, port    | `1001 aaa ppp xxxxxxxx`                     |
| NOP              | `1110 xxxxxxxxxxxx`                         |
| HALT             | `1111 xxxxxxxxxxxx`                         |
