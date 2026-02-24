#!/usr/bin/env bash
# =============================================================================
# synthesize.sh — Run Quartus synthesis locally via Docker.
#
# NOTE FOR APPLE SILICON USERS:
#   quartus_fit (the Fitter) crashes under Rosetta 2 due to AVX instructions.
#   This is a hard limitation of x86 emulation on M1/M2/M3.
#   Use GitHub Actions instead:  push to main → workflow auto-runs → download .sof
#   See: .github/workflows/synthesize.yml
#
# This script works correctly on native x86_64 Linux with Docker.
#
# Requirements:
#   - Docker running
#   - x86_64 Linux (native), or macOS Intel
#
# Output:
#   quartus/output_files/cpu_fpga.sof   — SRAM Object File (program the board)
#   quartus/output_files/cpu_fpga.pof   — PROM Object File (flash programming)
#
# Usage:
#   ./synthesize.sh           — normal build
#   ./synthesize.sh --rebuild — force rebuild of Docker image
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="cpu_in_fpga_quartus"
IMAGE_TAG="22.1-apple-silicon"
SOF_PATH="${SCRIPT_DIR}/quartus/output_files/cpu_fpga.sof"

# Colour helpers (fall back gracefully if terminal doesn't support them)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${BOLD}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Sanity checks
# ---------------------------------------------------------------------------
command -v docker &>/dev/null || die "Docker is not installed or not in PATH."
docker info &>/dev/null       || die "Docker daemon is not running. Start Docker Desktop first."

# ---------------------------------------------------------------------------
# 2. program.hex must be reachable from where Quartus runs (quartus/ dir).
#    top.v uses ROM_INIT("program.hex"), resolved relative to the Quartus
#    working directory — which is quartus/ inside the container.
#    That means quartus/program.hex is correct — it is already there.
# ---------------------------------------------------------------------------
[[ -f "${SCRIPT_DIR}/quartus/program.hex" ]] \
    || die "quartus/program.hex not found. This file is required by the ROM at synthesis time."

# ---------------------------------------------------------------------------
# 3. Build Docker image (skip if already present, unless --rebuild passed)
# ---------------------------------------------------------------------------
FORCE_REBUILD=false
[[ "${1:-}" == "--rebuild" ]] && FORCE_REBUILD=true

FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

if $FORCE_REBUILD || ! docker image inspect "${FULL_IMAGE}" &>/dev/null; then
    info "Building Docker image '${FULL_IMAGE}' from Dockerfile ..."
    info "(Base image didiermalenfant/quartus:22.1-apple-silicon is ~5.5 GB — first pull will take a while.)"
    docker build \
        -t "${FULL_IMAGE}" \
        "${SCRIPT_DIR}"
    ok "Docker image built."
else
    info "Docker image '${FULL_IMAGE}' already exists. Use --rebuild to force a rebuild."
fi

# ---------------------------------------------------------------------------
# 4. Run synthesis
#    -t allocates a pseudo-TTY so Quartus flushes output line-by-line
#    instead of buffering it until the process exits.
# ---------------------------------------------------------------------------
info "Starting Quartus synthesis inside Docker ..."
info "Project root mounted at /project inside the container."
info "(This takes several minutes under x86 emulation on Apple Silicon.)"

docker run --rm -t \
    -v "${SCRIPT_DIR}:/project" \
    "${FULL_IMAGE}" \
    bash -c "cd /project/quartus && quartus_sh --flow compile cpu_fpga"

# ---------------------------------------------------------------------------
# 5. Verify output
# ---------------------------------------------------------------------------
if [[ -f "${SOF_PATH}" ]]; then
    ok "Synthesis successful!"
    ok "SOF file: ${SOF_PATH}"
else
    die "Synthesis finished but SOF file not found at ${SOF_PATH}. Check Quartus output above."
fi
