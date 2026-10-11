#!/usr/bin/env bash
# Full regression runner: executes every phaseN_*.sh test script in order against the
# default org and prints a combined summary. Run this at the end of every build phase —
# it re-validates ALL prior phases, not just the newest one, so later phases can't
# silently break earlier config (e.g. a Phase 3 deploy reverting a Phase 1 sharing setting).
#
# Usage: ./testing/run_regression.sh
# Exit code: 0 if every phase script passed, 1 if any failed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_PHASES=()

echo "============================================="
echo " Full Regression Suite"
echo " Target org: $(export PATH="$HOME/.npm-global/bin:$PATH"; sf org display --json 2>/dev/null | jq -r '.result.username // "unknown"')"
echo " Run at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "============================================="
echo ""

for TEST_SCRIPT in "$SCRIPT_DIR"/phase*.sh; do
  [ -e "$TEST_SCRIPT" ] || continue
  bash "$TEST_SCRIPT"
  SCRIPT_EXIT=$?

  # Re-source-free re-parse of that script's own summary line isn't available here,
  # so we just track pass/fail at the script level and let each script's own PASS/FAIL
  # lines above speak for the per-test-case detail.
  if [ $SCRIPT_EXIT -eq 0 ]; then
    TOTAL_PASS=$((TOTAL_PASS + 1))
  else
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    FAILED_PHASES+=("$(basename "$TEST_SCRIPT")")
  fi
  echo ""
done

echo "============================================="
echo " Regression Summary: ${TOTAL_PASS} phase script(s) passed, ${TOTAL_FAIL} failed"
if [ ${#FAILED_PHASES[@]} -gt 0 ]; then
  echo " Failing scripts:"
  for F in "${FAILED_PHASES[@]}"; do
    echo "   - $F"
  done
fi
echo "============================================="

[ "$TOTAL_FAIL" -eq 0 ]
