# 8-bit CPU in FPGA

A simple but complete 8-bit CPU designed in Verilog and targeting the **Arrow MAX1000** FPGA board (Intel MAX 10). The project includes the full RTL, a testbench suite, a Quartus project, and an infinite-loop demo program that visualises CPU state on the board's 8 LEDs.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Project Structure](#project-structure)
- [Simulation](#simulation)
- [Synthesis and Programming the FPGA](#synthesis-and-programming-the-fpga)
- [Writing Your Own Programs](#writing-your-own-programs)
- [LED Indicators](#led-indicators)
- [ISA Quick Reference](#isa-quick-reference)

---

## Architecture Overview

### CPU at a Glance

| Property | Value |
|----------|-------|
| Data width | 8 bits |
| Address width | 8 bits (256 locations) |
| Instruction width | 16 bits (fixed) |
| Registers | R0–R7 (8 × 8-bit, general purpose) |
| Architecture | Harvard (separate program ROM and data RAM) |
| Pipeline | 2-stage: Fetch → Execute |
| Stack | Hardware LIFO, 16 entries deep |
| Flags | Z (zero), C (carry), N (negative), V (overflow) |
| Clock | 12 MHz on-board oscillator |

### Block Diagram

```
          ┌─────────────────────────────────────────────────────┐
          │                        CPU                          │
          │                                                     │
  clk ───►│  ┌──┐   addr    ┌─────┐  instr    ┌────-─────┐      │
  rst ───►│  │PC├──────────►│ ROM ├──────────►│ Decoder  │      │
          │  └─▲┘           └─────┘           └───-─┬────┘      │
          │    │                                    │ controls  │
          │    │ pc_load/target            ┌────────▼────────┐  │
          │    └───────────────────────────┤    Datapath     │  │
          │                                │                 │  │
          │                                │  ┌─────────┐    │  │
          │                                │  │ RegFile │    │  │
          │                                │  │  R0–R7  │    │  │
          │                                │  └────┬────┘    │  │
          │                                │       │         │  │
          │                                │  ┌────▼──┐      │  │
          │                                │  │  ALU  │      │  │
          │                                │  └────┬──┘      │  │
          │                                │       │ flags   │  │
          │                                │  ┌────▼────┐    │  │
          │                                │  │  Flags  │    │  │
          │  ┌───────┐                     │  │ Z C N V │    │  │
          │  │  RAM  │◄────────────────────┤  └─────────┘    │  │
          │  └───────┘                     │                 │  │
          │                                │  ┌─────────┐    │  │
          │                                │  │  Stack  │    │  │
          │                                │  └─────────┘    │  │
          │                                └─────────────────┘  │
          └─────────────────────────────────────────────────────┘
```

### Pipeline

The CPU uses a simple 2-stage pipeline to hide the 1-cycle ROM read latency:

```
Cycle N:    PC → ROM address
Cycle N+1:  ROM output valid → decode → execute → write-back
```

A 1-cycle flush NOP is inserted automatically after every taken branch or jump. A HALT instruction freezes the PC and replaces all subsequent ROM output with NOPs permanently.

### Modules

| File | Description |
|------|-------------|
| `rtl/cpu.v` | Top-level CPU — wires all modules together |
| `rtl/decoder.v` | Instruction decoder / control unit |
| `rtl/alu.v` | 8-bit ALU (ADD SUB AND OR XOR NOT SHL SHR) |
| `rtl/regfile.v` | 8 × 8-bit register file |
| `rtl/pc.v` | 8-bit program counter with load and halt |
| `rtl/rom.v` | 256 × 16-bit synchronous program ROM |
| `rtl/ram.v` | 256 × 8-bit data RAM |
| `rtl/stack.v` | 16-entry hardware stack (PUSH/POP/CALL/RET) |
| `rtl/top.v` | MAX1000 top-level (clock, reset, LED logic) |

---

## Project Structure

```
cpu_in_fpga/
├── docs/
│   └── ISA.md              # Full ISA specification
├── rtl/
│   ├── alu.v
│   ├── cpu.v
│   ├── decoder.v
│   ├── pc.v
│   ├── ram.v
│   ├── regfile.v
│   ├── rom.v
│   ├── stack.v
│   └── top.v
├── tb/
│   ├── tb_alu.v
│   ├── tb_cpu.v            # Integration testbench
│   ├── tb_decoder.v
│   ├── tb_mem.v
│   ├── tb_pc.v
│   ├── tb_regfile.v
│   ├── tb_stack.v
│   └── cpu_program.hex     # Program used by tb_cpu.v
├── quartus/
│   ├── cpu_fpga.qsf        # Quartus project + pin assignments
│   ├── cpu_fpga.sdc        # Timing constraints (12 MHz)
│   └── program.hex         # Infinite-loop demo program for the FPGA
└── sim/                    # Compiled simulation binaries (generated)
```

---

## Simulation

### Requirements

- [Icarus Verilog](https://steveicarus.github.io/iverilog/) (`iverilog` + `vvp`)

### Running all testbenches

All commands are run from the **project root**.

```sh
# ALU
iverilog -g2005 -o sim/tb_alu tb/tb_alu.v rtl/alu.v && vvp sim/tb_alu

# Register file
iverilog -g2005 -o sim/tb_regfile tb/tb_regfile.v rtl/regfile.v && vvp sim/tb_regfile

# Program counter
iverilog -g2005 -o sim/tb_pc tb/tb_pc.v rtl/pc.v && vvp sim/tb_pc

# Instruction decoder
iverilog -g2005 -o sim/tb_decoder tb/tb_decoder.v rtl/decoder.v && vvp sim/tb_decoder

# ROM + RAM
iverilog -g2005 -o sim/tb_mem tb/tb_mem.v rtl/rom.v rtl/ram.v && vvp sim/tb_mem

# Stack
iverilog -g2005 -o sim/tb_stack tb/tb_stack.v rtl/stack.v && vvp sim/tb_stack

# CPU integration (runs cpu_program.hex)
iverilog -g2005 -o sim/tb_cpu \
    tb/tb_cpu.v rtl/cpu.v rtl/rom.v rtl/ram.v \
    rtl/regfile.v rtl/alu.v rtl/pc.v rtl/decoder.v rtl/stack.v
vvp sim/tb_cpu
```

All 7 testbenches should report `ALL TESTS PASSED` (244 checks total).

---

## Synthesis and Programming the FPGA

### Requirements

- [Intel Quartus Prime](https://www.intel.com/content/www/us/en/products/details/fpga/development-tools/quartus-prime.html) (Lite edition is free and sufficient)
- Arrow MAX1000 board (Intel MAX 10, `10M08SAU169C8G`)
- USB cable for programming

### Step 1 — Copy the ROM program

The ROM is initialised from a file called `program.hex` that must be in the working directory when Quartus compiles. Copy the supplied demo program there:

```sh
cp quartus/program.hex program.hex
```

If you have written your own program (see below), copy that file instead.

### Step 2 — Open the Quartus project

```
File → Open Project → quartus/cpu_fpga.qsf
```

Or from the command line (full compile):

```sh
quartus_sh --flow compile quartus/cpu_fpga.qsf
```

### Step 3 — Compile

Click **Start Compilation** (Ctrl+L) or let the command-line flow above run to completion. The compiled bitstream is written to `quartus/output_files/top.sof`.

### Step 4 — Program the board

1. Connect the MAX1000 board via USB.
2. Open **Tools → Programmer**.
3. Click **Hardware Setup** and select the USB-Blaster.
4. Add the `.sof` file (`quartus/output_files/top.sof`).
5. Tick **Program/Configure** and click **Start**.

The board programs in a few seconds and the CPU starts running immediately.

---

## Writing Your Own Programs

Programs are stored in the ROM as a plain hex file — one 16-bit instruction word per line, big-endian, no prefix.

### Step 1 — Write assembly

Refer to `docs/ISA.md` for the full instruction set. A quick reference is also at the bottom of this file.

Example — count from 0 to 9, then halt:

```
; R0 = counter
; R1 = limit (10)

LDI  R0, 0      ; addr 0
LDI  R1, 10     ; addr 1
ADDI R0, R0, 1  ; addr 2  ← loop:
CMPI R0, 10     ; addr 3
JNZ  2          ; addr 4  → back to loop
HALT            ; addr 5
```

### Step 2 — Encode to hex

There is no assembler tool included; encoding is done by hand using the tables below and in `docs/ISA.md`.

Encoding the example above:

| Addr | Instruction     | Binary                  | Hex    |
|------|-----------------|-------------------------|--------|
| 0    | LDI R0, 0       | `0010 000 0 00000000`   | `2000` |
| 1    | LDI R1, 10      | `0010 001 0 00001010`   | `220A` |
| 2    | ADDI R0, R0, 1  | `0001 000 000 000001`   | `1001` |
| 3    | CMPI R0, 10     | `0111 000 000 001010`   | `700A` |
| 4    | JNZ  2          | `0100 010 0 00000010`   | `4202` |
| 5    | HALT            | `1111 000 000 000000`   | `F000` |

The resulting `program.hex`:

```
2000
220A
1001
700A
4202
F000
```

### Step 3 — Simulate your program

Replace the hex file the CPU testbench loads and recompile:

```sh
cp my_program.hex tb/cpu_program.hex

iverilog -g2005 -o sim/tb_cpu \
    tb/tb_cpu.v rtl/cpu.v rtl/rom.v rtl/ram.v \
    rtl/regfile.v rtl/alu.v rtl/pc.v rtl/decoder.v rtl/stack.v

vvp sim/tb_cpu
```

The testbench checks that `halt_out` is asserted and inspects register values via hierarchical access. Edit `tb/tb_cpu.v` to add your own assertions for your program's expected final state.

### Step 4 — Run on the FPGA

```sh
cp my_program.hex program.hex
```

Then recompile in Quartus and reprogram the board as described above. The LEDs will immediately reflect the new program's execution.

> **Note:** If your program never executes a HALT instruction, the heartbeat LED keeps blinking indefinitely. If it halts, the heartbeat LED freezes solid ON.

---

## LED Indicators

| LED | Pin | Signal | Meaning |
|-----|-----|--------|---------|
| LED[0] | E1 | Flag Z | ON = last ALU result was zero |
| LED[1] | F2 | Flag C | ON = carry or borrow out |
| LED[2] | H1 | Flag N | ON = result was negative (bit 7 set) |
| LED[3] | H2 | Flag V | ON = signed overflow |
| LED[4] | J1 | Heartbeat / Halt | Blinks ~1.4 Hz while running; solid ON when halted |
| LED[5] | J2 | PC[2] | Program counter bit 2 |
| LED[6] | K2 | PC[1] | Program counter bit 1 |
| LED[7] | K1 | PC[0] | Program counter bit 0 |

LEDs are **active-low** on the MAX1000 — `led_n=0` illuminates the LED.

Because the CPU runs at 12 MHz, individual instruction transitions are invisible. The flag LEDs show the most recently committed flag state, and the PC LEDs give a rough indication of which region of the program is executing.

---

## ISA Quick Reference

All instructions are **16 bits** wide. Three formats are used:

```
R-format:  [15:12] group | [11:9] Rd  | [8:6] Ra | [5:3] Rb  | [2:0] sub
I-format:  [15:12] group | [11:9] Rd  | [8:6] Ra | [5:0] imm6
I8-format: [15:12] group | [11:9] sub | [8] x    | [7:0] imm8
```

### Instruction table

| Instruction | Format | Encoding | Operation | Flags |
|---|---|---|---|---|
| `ADD  Rd, Ra, Rb`   | R  | `0000 ddd aaa bbb 000` | Rd = Ra + Rb        | Z C N V |
| `SUB  Rd, Ra, Rb`   | R  | `0000 ddd aaa bbb 001` | Rd = Ra − Rb        | Z C N V |
| `AND  Rd, Ra, Rb`   | R  | `0000 ddd aaa bbb 010` | Rd = Ra & Rb        | Z N     |
| `OR   Rd, Ra, Rb`   | R  | `0000 ddd aaa bbb 011` | Rd = Ra \| Rb       | Z N     |
| `XOR  Rd, Ra, Rb`   | R  | `0000 ddd aaa bbb 100` | Rd = Ra ^ Rb        | Z N     |
| `NOT  Rd, Ra`       | R  | `0000 ddd aaa xxx 101` | Rd = ~Ra            | Z N     |
| `SHL  Rd, Ra`       | R  | `0000 ddd aaa xxx 110` | Rd = Ra << 1        | Z C N   |
| `SHR  Rd, Ra`       | R  | `0000 ddd aaa xxx 111` | Rd = Ra >> 1        | Z C N   |
| `ADDI Rd, Ra, imm6` | I  | `0001 ddd aaa iiiiii`  | Rd = Ra + imm6      | Z C N V |
| `LDI  Rd, imm8`     | I8 | `0010 000 ddd iiiiii`  | Rd = imm8 (6-bit)   | —       |
| `LD   Rd, [Ra]`     | R  | `0010 001 ddd aaa xxx` | Rd = RAM[Ra]        | —       |
| `ST   [Ra], Rb`     | R  | `0010 010 xxx aaa bbb` | RAM[Ra] = Rb        | —       |
| `MOV  Rd, Ra`       | R  | `0011 ddd aaa xxxxxxx` | Rd = Ra             | —       |
| `JMP  addr8`        | I8 | `0100 000 x iiiiiiii`  | PC = addr8          | —       |
| `JZ   addr8`        | I8 | `0100 001 x iiiiiiii`  | if Z: PC = addr8    | —       |
| `JNZ  addr8`        | I8 | `0100 010 x iiiiiiii`  | if !Z: PC = addr8   | —       |
| `JC   addr8`        | I8 | `0100 011 x iiiiiiii`  | if C: PC = addr8    | —       |
| `JNC  addr8`        | I8 | `0100 100 x iiiiiiii`  | if !C: PC = addr8   | —       |
| `JN   addr8`        | I8 | `0100 101 x iiiiiiii`  | if N: PC = addr8    | —       |
| `JV   addr8`        | I8 | `0100 110 x iiiiiiii`  | if V: PC = addr8    | —       |
| `JR   Ra`           | R  | `0100 111 aaa xxxxxxx` | PC = Ra             | —       |
| `PUSH Ra`           | R  | `0101 000 aaa xxxxxxx` | Stack ← Ra          | —       |
| `POP  Rd`           | R  | `0101 001 ddd xxxxxxx` | Rd ← Stack          | —       |
| `CALL addr8`        | I8 | `0101 010 x iiiiiiii`  | PUSH(PC+1); PC=addr | —       |
| `RET`               | R  | `0101 011 xxx xxxxxxx` | PC ← Stack          | —       |
| `CMP  Ra, Rb`       | R  | `0110 xxx aaa bbb xxx` | flags(Ra − Rb)      | Z C N V |
| `CMPI Ra, imm6`     | I  | `0111 xxx aaa iiiiii`  | flags(Ra − imm6)    | Z C N V |
| `NOP`               | —  | `1110 xxxxxxxxxxxx`    | no operation        | —       |
| `HALT`              | —  | `1111 xxxxxxxxxxxx`    | freeze CPU          | —       |

### Register encoding

| Name | Binary |
|------|--------|
| R0   | `000`  |
| R1   | `001`  |
| R2   | `010`  |
| R3   | `011`  |
| R4   | `100`  |
| R5   | `101`  |
| R6   | `110`  |
| R7   | `111`  |

See `docs/ISA.md` for the complete specification including flag behaviour details and memory map.
