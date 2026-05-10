#!/usr/bin/env bash
# examples-auto-run/scripts/run.sh
# Automatically discovers and runs all examples in the repository,
# capturing output and reporting pass/fail status for each.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
EXAMPLES_DIR="${REPO_ROOT}/examples"
LOG_DIR="${REPO_ROOT}/.agents/skills/examples-auto-run/logs"
TIMEOUT_SECONDS="${EXAMPLES_TIMEOUT:-60}"
PYTHON="${PYTHON:-python}"

PASS=0
FAIL=0
SKIP=0
FAILED_EXAMPLES=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[examples-auto-run] $*"; }
warn() { echo "[examples-auto-run] WARN: $*" >&2; }
err()  { echo "[examples-auto-run] ERROR: $*" >&2; }

require_cmd() {
  command -v "$1" &>/dev/null || { err "Required command not found: $1"; exit 1; }
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
require_cmd "$PYTHON"
require_cmd "timeout"

mkdir -p "$LOG_DIR"

if [[ ! -d "$EXAMPLES_DIR" ]]; then
  err "Examples directory not found: $EXAMPLES_DIR"
  exit 1
fi

# ---------------------------------------------------------------------------
# Collect example files
# ---------------------------------------------------------------------------
# We look for Python files that are directly runnable (have a __main__ block
# or are standalone scripts). Files prefixed with '_' are treated as helpers
# and skipped.
mapfile -t EXAMPLE_FILES < <(
  find "$EXAMPLES_DIR" -name '*.py' \
    ! -name '_*' \
    ! -path '*/.*' \
    | sort
)

if [[ ${#EXAMPLE_FILES[@]} -eq 0 ]]; then
  warn "No example files found in $EXAMPLES_DIR"
  exit 0
fi

log "Found ${#EXAMPLE_FILES[@]} example file(s) to validate."
log "Timeout per example: ${TIMEOUT_SECONDS}s"
log "Logs directory: $LOG_DIR"
echo ""

# ---------------------------------------------------------------------------
# Run each example
# ---------------------------------------------------------------------------
for example in "${EXAMPLE_FILES[@]}"; do
  rel="${example#${REPO_ROOT}/}"
  log_file="${LOG_DIR}/$(echo "$rel" | tr '/' '__').log"

  # Skip examples that require live API keys unless explicitly opted-in.
  # A file containing the marker '# requires-api-key' will be skipped when
  # the OPENAI_API_KEY environment variable is not set.
  if grep -q '# requires-api-key' "$example" 2>/dev/null; then
    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
      log "SKIP  $rel  (requires OPENAI_API_KEY)"
      (( SKIP++ )) || true
      continue
    fi
  fi

  # Check that the file actually contains a runnable entry point.
  if ! grep -q '__main__\|^if __name__' "$example" 2>/dev/null; then
    log "SKIP  $rel  (no __main__ block)"
    (( SKIP++ )) || true
    continue
  fi

  log "RUN   $rel"

  set +e
  timeout "$TIMEOUT_SECONDS" \
    "$PYTHON" "$example" \
    > "$log_file" 2>&1
  exit_code=$?
  set -e

  if [[ $exit_code -eq 0 ]]; then
    log "PASS  $rel"
    (( PASS++ )) || true
  elif [[ $exit_code -eq 124 ]]; then
    err "TIMEOUT $rel  (>${TIMEOUT_SECONDS}s)"
    FAILED_EXAMPLES+=("$rel (timeout)")
    (( FAIL++ )) || true
  else
    err "FAIL  $rel  (exit $exit_code)"
    err "      Log: $log_file"
    FAILED_EXAMPLES+=("$rel (exit $exit_code)")
    (( FAIL++ )) || true
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
log "======================================="
log "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
log "======================================="

if [[ ${#FAILED_EXAMPLES[@]} -gt 0 ]]; then
  err "Failed examples:"
  for fe in "${FAILED_EXAMPLES[@]}"; do
    err "  - $fe"
  done
  exit 1
fi

log "All runnable examples passed."
exit 0
