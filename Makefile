# =============================================================================
# Makefile — build, simulate, and view waveforms for the 8-bit CPU
#
# Prerequisites:
#   brew install icarus-verilog   (iverilog / vvp)
#   brew install surfer           (waveform viewer, M1-compatible)
#
# Usage:
#   make sim          — compile and run all testbenches (prints PASS/FAIL)
#   make wave TB=cpu  — open surfer for a specific testbench
#                       TB can be: alu, decoder, mem, pc, regfile, stack, cpu, fibonacci, fibonacci_stack, knightrider
#   make clean        — remove compiled binaries and VCD files
# =============================================================================

IVERILOG  = iverilog
VVP       = vvp
WAVE      = surfer
ASSEMBLER = python3 tools/assembler.py

RTL = rtl/cpu.v rtl/alu.v rtl/regfile.v rtl/pc.v \
      rtl/decoder.v rtl/rom.v rtl/ram.v rtl/stack.v rtl/prng.v

SIM_DIR = sim/vcd

# ---------------------------------------------------------------------------
# Assembly sources that back the example .hex files used by testbenches.
# Each .hex is rebuilt from its .asm whenever the .asm is newer.
# ---------------------------------------------------------------------------
EXAMPLE_ASMS = $(wildcard examples/*.asm)
EXAMPLE_HEXS = $(EXAMPLE_ASMS:.asm=.hex)

examples/%.hex: examples/%.asm
	@echo "Assembling $< -> $@"
	$(ASSEMBLER) -o $@ $<

# ---------------------------------------------------------------------------
# All testbenches
# ---------------------------------------------------------------------------
TBS = alu decoder mem pc regfile stack cpu fibonacci fibonacci_stack knightrider oled_monitor

.PHONY: all sim assemble clean $(TBS:%=sim-%) $(TBS:%=wave-%)

all: sim

assemble: $(EXAMPLE_HEXS)

sim: assemble $(TBS:%=sim-%)

# ---------------------------------------------------------------------------
# Per-testbench rules
# ---------------------------------------------------------------------------

sim-alu: $(SIM_DIR)
	@echo "--- tb_alu ---"
	$(IVERILOG) -g2005 -o $(SIM_DIR)/tb_alu tb/tb_alu.v rtl/alu.v
	$(VVP) $(SIM_DIR)/tb_alu

sim-decoder: $(SIM_DIR)
	@echo "--- tb_decoder ---"
	$(IVERILOG) -g2005 -o $(SIM_DIR)/tb_decoder tb/tb_decoder.v rtl/decoder.v
	$(VVP) $(SIM_DIR)/tb_decoder

sim-mem: $(SIM_DIR)
	@echo "--- tb_mem ---"
	$(IVERILOG) -g2005 -o $(SIM_DIR)/tb_mem tb/tb_mem.v rtl/rom.v rtl/ram.v
	$(VVP) $(SIM_DIR)/tb_mem

sim-pc: $(SIM_DIR)
	@echo "--- tb_pc ---"
	$(IVERILOG) -g2005 -o $(SIM_DIR)/tb_pc tb/tb_pc.v rtl/pc.v
	$(VVP) $(SIM_DIR)/tb_pc

sim-regfile: $(SIM_DIR)
	@echo "--- tb_regfile ---"
	$(IVERILOG) -g2005 -o $(SIM_DIR)/tb_regfile tb/tb_regfile.v rtl/regfile.v
	$(VVP) $(SIM_DIR)/tb_regfile

sim-stack: $(SIM_DIR)
	@echo "--- tb_stack ---"
	$(IVERILOG) -g2005 -o $(SIM_DIR)/tb_stack tb/tb_stack.v rtl/stack.v
	$(VVP) $(SIM_DIR)/tb_stack

sim-cpu: $(SIM_DIR)
	@echo "--- tb_cpu ---"
	$(IVERILOG) -g2005 -o $(SIM_DIR)/tb_cpu tb/tb_cpu.v $(RTL)
	$(VVP) $(SIM_DIR)/tb_cpu

sim-fibonacci: $(SIM_DIR)
	@echo "--- tb_fibonacci ---"
	$(IVERILOG) -g2005 -o $(SIM_DIR)/tb_fibonacci tb/tb_fibonacci.v $(RTL)
	$(VVP) $(SIM_DIR)/tb_fibonacci

sim-fibonacci_stack: $(SIM_DIR)
	@echo "--- tb_fibonacci_stack ---"
	$(IVERILOG) -g2005 -o $(SIM_DIR)/tb_fibonacci_stack tb/tb_fibonacci_stack.v $(RTL)
	$(VVP) $(SIM_DIR)/tb_fibonacci_stack

sim-knightrider: $(SIM_DIR)
	@echo "--- tb_knightrider ---"
	$(IVERILOG) -g2005 -o $(SIM_DIR)/tb_knightrider tb/tb_knightrider.v $(RTL)
	$(VVP) $(SIM_DIR)/tb_knightrider

sim-oled_monitor: $(SIM_DIR)
	@echo "--- tb_oled_monitor ---"
	$(IVERILOG) -g2005 -o $(SIM_DIR)/tb_oled_monitor tb/tb_oled_monitor.v rtl/oled_monitor.v
	$(VVP) $(SIM_DIR)/tb_oled_monitor

# ---------------------------------------------------------------------------
# GTKWave: make wave TB=<name>
# ---------------------------------------------------------------------------
wave:
ifndef TB
	$(error TB is not set. Usage: make wave TB=cpu)
endif
	$(MAKE) sim-$(TB)
	$(WAVE) $(SIM_DIR)/tb_$(TB).vcd &

# ---------------------------------------------------------------------------
# Convenience shortcuts: make wave-cpu, make wave-fibonacci, etc.
# ---------------------------------------------------------------------------
$(TBS:%=wave-%): wave-%: sim-%
	$(WAVE) $(SIM_DIR)/tb_$*.vcd &

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------
$(SIM_DIR):
	mkdir -p $(SIM_DIR)

clean:
	rm -rf $(SIM_DIR)
