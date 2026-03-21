#!/usr/bin/env bash
# =============================================================================
# build_and_download.sh — Trigger GitHub Actions synthesis, watch it, then
#                         download the artifact into quartus_output/<branch>/<name>/.
#
# Usage:
#   ./build_and_download.sh fibonacci
#   ./build_and_download.sh knightrider
#
# The argument is the bare name of an .asm file in examples/.
# The CPU clock speed is read from a "; clk_div: N" line in the .asm header.
#   If not present, defaults to 20 (≈ 11.4 Hz).
#   12 MHz / 2^N:  23→~1.4 Hz  22→~2.9 Hz  21→~5.7 Hz  20→~11.4 Hz
#                  17→~91 Hz   14→~732 Hz
# The assembled SOF/POF is stored in quartus_output/<branch>/<name>/.
# =============================================================================

set -euo pipefail

REPO="gertjana/cpu_in_fpga"
WORKFLOW="synthesize.yml"
BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Colour helpers
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${BOLD}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Validate argument
# ---------------------------------------------------------------------------
[[ $# -eq 1 ]] || die "Usage: $0 <name>\n  e.g. $0 fibonacci"

NAME="${1%.asm}"          # strip .asm suffix if accidentally included
PROGRAM="examples/${NAME}.asm"
ARTIFACT_NAME="quartus-output-${BRANCH}-${NAME}"
OUTPUT_DIR="quartus_output/${BRANCH}/${NAME}"

[[ -f "$PROGRAM" ]] || die "File not found: ${PROGRAM}"

# ---------------------------------------------------------------------------
# 2. Read clk_div from the .asm header ("; clk_div: N"), default 20
# ---------------------------------------------------------------------------
CLK_DIV=$(grep -m1 '^[[:space:]]*;[[:space:]]*clk_div[[:space:]]*:' "$PROGRAM" | sed 's/.*clk_div[[:space:]]*:[[:space:]]*//' | tr -dc '0-9')
CLK_DIV="${CLK_DIV:-20}"
info "Clock divider : CPU_CLK_DIV_BITS=${CLK_DIV}  (12 MHz / 2^${CLK_DIV})"

# ---------------------------------------------------------------------------
# 2b. Read prog_name from the .asm header ("; name: <NAME>"), default to NAME
#     Truncated/padded to exactly 19 characters for the OLED display.
#     (2 columns are reserved for the flag V indicator and a space prefix.)
# ---------------------------------------------------------------------------
RAW_NAME=$(grep -m1 '^[[:space:]]*;[[:space:]]*name[[:space:]]*:' "$PROGRAM" | sed 's/.*name[[:space:]]*:[[:space:]]*//' | tr -d '\r\n')
RAW_NAME="${RAW_NAME:-${NAME}}"
# Pad or truncate to exactly 19 characters
PROG_NAME=$(printf "%-19.19s" "${RAW_NAME}")
info "Program name  : \"${PROG_NAME}\""

# ---------------------------------------------------------------------------
# 3. Check gh is available and authenticated
# ---------------------------------------------------------------------------
command -v gh &>/dev/null || die "gh (GitHub CLI) not found.\n  brew install gh"
gh auth status &>/dev/null  || die "Not authenticated. Run: gh auth login"

# ---------------------------------------------------------------------------
# 4. Trigger the workflow
# ---------------------------------------------------------------------------
info "Triggering workflow '${WORKFLOW}' on branch '${BRANCH}'"
info "Program : ${PROGRAM}"
info "Output  : ${OUTPUT_DIR}/"
gh workflow run "${WORKFLOW}" \
    --repo "${REPO}" \
    --ref "${BRANCH}" \
    --field "program=${PROGRAM}" \
    --field "name=${NAME}" \
    --field "clk_div=${CLK_DIV}" \
    --field "prog_name=${PROG_NAME}"

# Give GitHub a moment to register the run
sleep 3

# ---------------------------------------------------------------------------
# 5. Find the run ID that was just created
# ---------------------------------------------------------------------------
info "Fetching run ID ..."
RUN_ID=$(gh run list \
    --repo "${REPO}" \
    --workflow "${WORKFLOW}" \
    --branch "${BRANCH}" \
    --limit 1 \
    --json databaseId \
    --jq '.[0].databaseId')

[[ -n "$RUN_ID" ]] || die "Could not determine run ID."
info "Run ID: ${RUN_ID}"
info "Watch at: https://github.com/${REPO}/actions/runs/${RUN_ID}"

# ---------------------------------------------------------------------------
# 6. Watch the workflow run (streams logs, exits when done)
# ---------------------------------------------------------------------------
info "Watching workflow run ..."
gh run watch "${RUN_ID}" --repo "${REPO}" --exit-status \
    || die "Workflow run failed. Check: https://github.com/${REPO}/actions/runs/${RUN_ID}"

ok "Workflow completed successfully."

# ---------------------------------------------------------------------------
# 7. Clear the output directory
# ---------------------------------------------------------------------------
info "Clearing ${OUTPUT_DIR}/ ..."
mkdir -p "${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}"/*
ok "Output directory cleared."

# ---------------------------------------------------------------------------
# 8. Download the artifact
# ---------------------------------------------------------------------------
sleep 5  # Give GitHub a moment to prepare the artifact
info "Downloading artifact '${ARTIFACT_NAME}' ..."
TMPDIR=$(mktemp -d)
gh run download "${RUN_ID}" \
    --repo "${REPO}" \
    --name "${ARTIFACT_NAME}" \
    --dir "${TMPDIR}"

# gh unpacks into TMPDIR/<artifact-name>/ — move contents up into OUTPUT_DIR
mv "${TMPDIR}/${ARTIFACT_NAME}"/* "${OUTPUT_DIR}/"
rm -rf "${TMPDIR}"

ok "Artifact downloaded to ${OUTPUT_DIR}/"
echo ""
ls -lh "${OUTPUT_DIR}/"
echo ""
info "To program the FPGA, run:  ./program.sh ${NAME}"
