#!/usr/bin/env bash
#
# run-tests.sh — regression harness for replay-smoke.sh (BUG-087).
#
# Drives the replay gate against fixed migration sets and asserts each one
# passes / fails as it should. Two kinds of case:
#
#   good-storage      a known-GOOD set whose later migration does platform-schema
#                     DML (`insert into storage.buckets …`). Proves the storage
#                     stub is seeded before replay → must PASS. This is the
#                     BUG-087 regression: before the stub it FAILed the apply.
#   bad-email         baseline carries a member email literal           → must FAIL
#   bad-matched-text  baseline carries the `matched_text` PII column     → must FAIL
#   bad-copy          baseline carries a top-level COPY … FROM stdin     → must FAIL
#
# The bad-* cases guard that the storage-stub change did not weaken the PII gate:
# they trip the BLOCKING scan and abort before any container starts (fast). The
# good-storage case exercises a full two-container replay + determinism diff, so
# it needs docker + the pinned image (same prerequisites as the gate itself).
#
# Exit code: 0 = every case behaved as expected; non-zero = at least one didn't.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../replay-smoke.sh"
FIXTURES="$HERE/fixtures"
LOGDIR="$(mktemp -d)"
trap 'rm -rf "$LOGDIR" 2>/dev/null || true' EXIT

pass=0
fail=0

# run_case <fixture> <expect: pass|fail>
run_case() {
  local name="$1" expect="$2"
  local dir="$FIXTURES/$name" rc=0 got
  printf '\n--- case: %-16s (expect %s) ---\n' "$name" "$expect"
  MIGRATIONS_DIR="$dir" bash "$SCRIPT" >"$LOGDIR/$name.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then got="pass"; else got="fail"; fi
  if [ "$got" = "$expect" ]; then
    printf 'OK   %s — gate %sed as expected (rc=%s)\n' "$name" "$got" "$rc"
    pass=$((pass + 1))
  else
    printf 'XX   %s — expected gate to %s but it %sed (rc=%s)\n' "$name" "$expect" "$got" "$rc" >&2
    printf '     ----- log tail -----\n' >&2
    tail -n 25 "$LOGDIR/$name.log" >&2
    fail=$((fail + 1))
  fi
}

echo "replay-smoke regression harness"
echo "  script:   $SCRIPT"
echo "  fixtures: $FIXTURES"

run_case good-storage     pass
run_case bad-email        fail
run_case bad-matched-text fail
run_case bad-copy         fail

echo ""
echo "================================"
printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || { echo "REGRESSION HARNESS FAILED" >&2; exit 1; }
echo "REGRESSION HARNESS PASSED"
