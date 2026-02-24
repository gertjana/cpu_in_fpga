#!/usr/bin/env bash
# =============================================================================
# synth_and_program.sh — One-shot: synthesise then program the MAX1000.
#
# This script just calls synthesize.sh followed by program.sh.
# Both scripts are self-contained; you can also run them individually.
#
# Requirements:
#   - Docker Desktop running (for synthesis)
#   - openFPGALoader installed on the host (for programming):
#       brew install openfpgaloader
#   - Arrow MAX1000 connected via USB
#
# Usage:
#   ./synth_and_program.sh           — synthesise + program SRAM (volatile)
#   ./synth_and_program.sh --flash   — synthesise + program internal flash
#   ./synth_and_program.sh --rebuild — force Docker image rebuild + program SRAM
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SYNTH_ARGS=()
PROG_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --rebuild) SYNTH_ARGS+=("--rebuild") ;;
        --flash)   PROG_ARGS+=("--flash") ;;
        *)
            echo "[ERROR] Unknown argument: $arg" >&2
            echo "Usage: $0 [--rebuild] [--flash]" >&2
            exit 1
            ;;
    esac
done

echo "========================================"
echo "  Step 1/2: Synthesis (Docker/Quartus)"
echo "========================================"
"${SCRIPT_DIR}/synthesize.sh" "${SYNTH_ARGS[@]+"${SYNTH_ARGS[@]}"}"

echo ""
echo "========================================"
echo "  Step 2/2: Programming (openFPGALoader)"
echo "========================================"
"${SCRIPT_DIR}/program.sh" "${PROG_ARGS[@]+"${PROG_ARGS[@]}"}"
