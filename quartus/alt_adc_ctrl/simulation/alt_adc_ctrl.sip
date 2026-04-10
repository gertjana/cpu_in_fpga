set_global_assignment -entity "alt_adc_ctrl" -library "lib_alt_adc_ctrl" -name IP_TOOL_NAME "Qsys"
set_global_assignment -entity "alt_adc_ctrl" -library "lib_alt_adc_ctrl" -name IP_TOOL_VERSION "18.1"
set_global_assignment -entity "alt_adc_ctrl" -library "lib_alt_adc_ctrl" -name IP_TOOL_ENV "Qsys"
set_global_assignment -library "lib_alt_adc_ctrl" -name SPD_FILE [file join $::quartus(sip_path) "../alt_adc_ctrl.spd"]
set_global_assignment -library "lib_alt_adc_ctrl" -name MISC_FILE [file join $::quartus(sip_path) "../../alt_adc_ctrl.qsys"]

set_global_assignment -library "lib_alt_adc_ctrl" -name MISC_FILE [file join $::quartus(sip_path) "alt_adc_ctrl.v"]
set_global_assignment -library "lib_alt_adc_ctrl" -name MISC_FILE [file join $::quartus(sip_path) "submodules/alt_adc_ctrl_modular_adc_0.v"]
set_global_assignment -library "lib_alt_adc_ctrl" -name MISC_FILE [file join $::quartus(sip_path) "submodules/altera_modular_adc_control.v"]
set_global_assignment -library "lib_alt_adc_ctrl" -name MISC_FILE [file join $::quartus(sip_path) "submodules/altera_modular_adc_control_avrg_fifo.v"]
set_global_assignment -library "lib_alt_adc_ctrl" -name MISC_FILE [file join $::quartus(sip_path) "submodules/altera_modular_adc_control_fsm.v"]
set_global_assignment -library "lib_alt_adc_ctrl" -name MISC_FILE [file join $::quartus(sip_path) "submodules/chsel_code_converter_sw_to_hw.v"]
set_global_assignment -library "lib_alt_adc_ctrl" -name MISC_FILE [file join $::quartus(sip_path) "submodules/fiftyfivenm_adcblock_primitive_wrapper.v"]
set_global_assignment -library "lib_alt_adc_ctrl" -name MISC_FILE [file join $::quartus(sip_path) "submodules/fiftyfivenm_adcblock_top_wrapper.v"]
