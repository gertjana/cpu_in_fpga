# =============================================================================
# Dockerfile — Quartus Prime Lite 22.1 synthesis environment
#
# Base image: didiermalenfant/quartus:22.1-apple-silicon
#   - x86_64 image that bypasses Quartus's startup CPU check (which breaks
#     raetro/quartus:21.1 under Rosetta with "processor extensions not found")
#   - Supports MAX 10 (10M08SAU169C8G on the Arrow MAX1000)
#
# KNOWN LIMITATION on Apple Silicon (M1/M2/M3):
#   Analysis & Synthesis completes, but quartus_fit (the Fitter) crashes under
#   Rosetta 2 because it uses AVX instructions that Rosetta does not emulate.
#   This is a hard limitation — no Docker image can work around it.
#
# For synthesis on Apple Silicon, use GitHub Actions instead:
#   .github/workflows/synthesize.yml  — runs on x86_64 Ubuntu, no emulation.
#
# This Dockerfile is kept for reference and for use on native x86_64 Linux.
# On Linux, use raetro/quartus:22.1 directly (no custom image needed):
#   docker run --rm -v $(pwd):/build raetro/quartus:22.1 \
#     bash -c "cd /build/quartus && quartus_sh --flow compile cpu_fpga"
# =============================================================================

FROM didiermalenfant/quartus:22.1-apple-silicon

WORKDIR /project
