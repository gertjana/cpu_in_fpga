#!/usr/bin/env bash
# =============================================================================
# program.sh — Program the Arrow MAX1000 FPGA over USB using openFPGALoader.
#
# Requirements (host Mac):
#   brew install openfpgaloader
#
# What it does:
#   1. Checks openFPGALoader is installed.
#   2. Looks for a connected MAX1000 / Arrow USB-Blaster.
#   3. Programs quartus/output_files/cpu_fpga.sof into the FPGA SRAM.
#      (SRAM programming is volatile — bitstream is lost on power-cycle.)
#
# For permanent (flash) programming see the note at the bottom.
#
# Usage:
#   ./program.sh              — program SRAM with cpu_fpga.sof
#   ./program.sh --flash      — program internal flash with cpu_fpga.pof (permanent)
# =============================================================================

#set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOF_FILE="${SCRIPT_DIR}/quartus_output/cpu_fpga.sof"
POF_FILE="${SCRIPT_DIR}/quartus_output/cpu_fpga.pof"

# Colour helpers
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${BOLD}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

FLASH_MODE=false
[[ "${1:-}" == "--flash" ]] && FLASH_MODE=true

# ---------------------------------------------------------------------------
# 1. Check openFPGALoader is installed
# ---------------------------------------------------------------------------
if ! command -v openFPGALoader &>/dev/null; then
    die "openFPGALoader not found.\n\nInstall it with:\n  brew install openfpgaloader\n\nThen re-run this script."
fi

OFPL_VERSION=$(openFPGALoader --Version 2>&1 | head -1)
info "openFPGALoader: ${OFPL_VERSION}"

# ---------------------------------------------------------------------------
# 2. Detect the MAX1000 / Arrow USB-Blaster
#    The Arrow MAX1000 uses an FTDI FT2232H as its USB-Blaster.
#    It is not in openFPGALoader's board list, so we always use --cable ft2232.
# ---------------------------------------------------------------------------
CABLE_FLAG="--cable ft2232"

info "Scanning for JTAG devices ..."
if openFPGALoader ${CABLE_FLAG} --detect 2>&1 | grep -qi "10M16S"; then
    ok "Arrow MAX1000 (10M16SAU169C8G) detected."
else
    warn "Could not confirm MAX1000 on JTAG chain — attempting to program anyway ..."
fi

# ---------------------------------------------------------------------------
# 3. Program the device
# ---------------------------------------------------------------------------
if $FLASH_MODE; then
    # --- Flash (permanent, survives power-cycle) ---
    [[ -f "${POF_FILE}" ]] \
        || die "POF file not found: ${POF_FILE}\nRun ./synthesize.sh first."

    info "Programming internal flash with: ${POF_FILE}"
    warn "Flash programming takes ~30 s. Do not disconnect the board."

    openFPGALoader ${CABLE_FLAG} --write-flash "${POF_FILE}"
    ok "Flash programming complete. Bitstream will survive power-cycles."
else
    # --- SRAM (volatile, fastest — use during development) ---
    [[ -f "${SOF_FILE}" ]] \
        || die "SOF file not found: ${SOF_FILE}\nRun ./synthesize.sh first."

    info "Programming FPGA SRAM with: ${SOF_FILE}"

    openFPGALoader ${CABLE_FLAG} "${SOF_FILE}"
    ok "SRAM programming complete."
    info "Note: bitstream is volatile — it will be lost on power-cycle."
    info "Use ./program.sh --flash to program the internal flash permanently."
fi

# ---------------------------------------------------------------------------
# Notes on permanent flash programming
# ---------------------------------------------------------------------------
# MAX 10 has internal flash.  To program it permanently:
#   1. In Quartus, go to File → Convert Programming Files and generate a .pof
#      targeting the CFM (Configuration Flash Memory).
#   2. Run:  ./program.sh --flash
#
# Alternatively, openFPGALoader can convert and write in one step for some
# boards, but explicit POF generation via Quartus is more reliable for MAX 10.
# ---------------------------------------------------------------------------
