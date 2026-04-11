// build_config.vh — Generated at synthesis time by build_and_download.sh
// and .github/workflows/synthesize.yml from the "; name: <NAME>" comment
// in the .asm source file.
//
// This default file is committed so that local simulation and Quartus
// builds work without running the CI pipeline.
// The CI pipeline overwrites this file before invoking Quartus.
//
// PROG_NAME must be exactly 19 ASCII characters (pad with spaces on the right).
// The first 2 display columns on line 3 are reserved for the flag V indicator.
`define PROG_NAME "ADC Demo           "

// Uncomment to route OLED FSM debug state to the 8 LEDs instead of the
// normal program-driven LED output.  See top.v for the LED-to-signal mapping.
`define OLED_DIAG
