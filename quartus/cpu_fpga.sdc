# cpu_fpga.sdc — Timing constraints for 8-bit CPU on MAX1000 (12 MHz)

# 12 MHz clock on pin H6 (period = 83.33 ns)
create_clock -name clk_12m -period 83.333 [get_ports clk_12m]

# Relax input/output delays — no external timing requirements
set_false_path -from [get_ports rst_n]
set_false_path -to   [get_ports {led_n[*]}]
