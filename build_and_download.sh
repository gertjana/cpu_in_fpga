#!/usr/bin/env bash
# =============================================================================
# build_and_download.sh — Trigger GitHub Actions synthesis, watch it, then
#                         download the artifact into quartus_output/.
#
# Usage:
#   ./build_and_download.sh examples/pc_test.asm
#   ./build_and_download.sh examples/infinite_counter.asm
# =============================================================================

set -euo pipefail

REPO="gertjana/cpu_in_fpga"
WORKFLOW="synthesize.yml"
ARTIFACT_NAME="quartus-output"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
OUTPUT_DIR="quartus_output/${BRANCH}"

# Colour helpers
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${BOLD}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Validate argument
# ---------------------------------------------------------------------------
[[ $# -eq 1 ]] || die "Usage: $0 <program.asm>\n  e.g. $0 examples/pc_test.asm"

PROGRAM="$1"
[[ -f "$PROGRAM" ]] || die "File not found: $PROGRAM"

# ---------------------------------------------------------------------------
# 2. Check gh is available and authenticated
# ---------------------------------------------------------------------------
command -v gh &>/dev/null || die "gh (GitHub CLI) not found.\n  brew install gh"
gh auth status &>/dev/null  || die "Not authenticated. Run: gh auth login"

# ---------------------------------------------------------------------------
# 3. Trigger the workflow
# ---------------------------------------------------------------------------
info "Triggering workflow '${WORKFLOW}' on branch '${BRANCH}' with program: ${PROGRAM}"
gh workflow run "${WORKFLOW}" \
    --repo "${REPO}" \
    --ref "${BRANCH}" \
    --field "program=${PROGRAM}"

# Give GitHub a moment to register the run
sleep 3

# ---------------------------------------------------------------------------
# 4. Find the run ID that was just created
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
# 5. Watch the workflow run (streams logs, exits when done)
# ---------------------------------------------------------------------------
info "Watching workflow run ..."
gh run watch "${RUN_ID}" --repo "${REPO}" --exit-status \
    || die "Workflow run failed. Check: https://github.com/${REPO}/actions/runs/${RUN_ID}"

ok "Workflow completed successfully."

# ---------------------------------------------------------------------------
# 6. Clear the output directory
# ---------------------------------------------------------------------------
info "Clearing ${OUTPUT_DIR}/ ..."
mkdir -p "${OUTPUT_DIR}"
rm -f "${OUTPUT_DIR}"/*
ok "Output directory cleared."

# ---------------------------------------------------------------------------
# 7. Download the artifact
# ---------------------------------------------------------------------------
info "Downloading artifact '${ARTIFACT_NAME}' ..."
gh run download "${RUN_ID}" \
    --repo "${REPO}" \
    --name "${ARTIFACT_NAME}" \
    --dir "${OUTPUT_DIR}"

ok "Artifact downloaded to ${OUTPUT_DIR}/"
echo ""
ls -lh "${OUTPUT_DIR}/"
