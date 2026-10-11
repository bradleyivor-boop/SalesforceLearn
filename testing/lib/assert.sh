#!/usr/bin/env bash
# Shared assertion helpers for phase test scripts.
# Usage: source this file, set CURRENT_PHASE, call assert_* functions, then print_summary at the end.

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_PHASE="${CURRENT_PHASE:-Unnamed Phase}"

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  PASS  $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "  FAIL  $1"
  if [ -n "${2:-}" ]; then
    echo "        $2"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail "$desc" "expected '$expected', got '$actual'"
  fi
}

assert_not_empty() {
  local desc="$1" value="$2"
  if [ -n "$value" ] && [ "$value" != "null" ]; then
    pass "$desc"
  else
    fail "$desc" "value was empty/null"
  fi
}

assert_contains() {
  # Uses a here-string (not a pipe) so grep -q exiting early on a large haystack
  # can't SIGPIPE the producer and get misreported as a failure under `pipefail`.
  local desc="$1" haystack="$2" needle="$3"
  if grep -qx -- "$needle" <<< "$haystack"; then
    pass "$desc"
  else
    fail "$desc" "'$needle' not found in list"
  fi
}

assert_gte() {
  local desc="$1" expected_min="$2" actual="$3"
  if [ "$actual" -ge "$expected_min" ] 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc" "expected >= $expected_min, got '$actual'"
  fi
}

print_summary() {
  echo ""
  echo "---- ${CURRENT_PHASE}: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ----"
  [ "$FAIL_COUNT" -eq 0 ]
}
