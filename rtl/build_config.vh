// build_config.vh — Generated at synthesis time by build_and_download.sh
// and .github/workflows/synthesize.yml from header comments in the .asm file.
//
// This default file is committed so that local simulation and Quartus
// builds work without running the CI pipeline.
// The CI pipeline overwrites this file before invoking Quartus.
//
// PROG_NAME must be exactly 19 ASCII characters (pad with spaces on the right).
// The first 2 display columns on line 3 are reserved for the flag V indicator.
//
// CPU_CLK_DIV_BITS controls the CPU clock prescaler width: f = 12 MHz / 2^N.
//   23 → ~1.4 Hz   22 → ~2.9 Hz   21 → ~5.7 Hz   20 → ~11.4 Hz
//   17 → ~91 Hz    14 → ~732 Hz
`define PROG_NAME        "UNKNOWN            "
`define CPU_CLK_DIV_BITS 20
