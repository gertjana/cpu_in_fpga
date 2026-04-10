# cpu_fpga.sdc — Timing constraints for 8-bit CPU on MAX1000 (12 MHz)

# 12 MHz clock on pin H6 (period = 83.33 ns)
create_clock -name clk_12m -period 83.333 [get_ports clk_12m]

# Apply jitter/uncertainty to all clock transfers.
derive_clock_uncertainty

# Relax input/output delays — no external timing requirements
set_false_path -from [get_ports rst_n]
set_false_path -to   [get_ports {led[*]}]

# PMOD outputs are asynchronous display signals — no setup/hold required
set_false_path -to [get_ports {pmod_cs_n pmod_mosi pmod_sclk pmod_dc pmod_res_n pmod_vbatc pmod_vddc}]

# GPIO pins have no external timing requirements
set_false_path -to   [get_ports {gpio[*]}]
set_false_path -from [get_ports {gpio[*]}]

# ADC analogue input — ain (PIN_D2) is the dedicated analogue pad.
# Quartus treats analogue pins as having no digital timing path; this
# false-path constraint is a belt-and-braces guard in case Quartus ever
# attempts to analyse the digital wrapper around the pad.
set_false_path -from [get_ports {ain}]
