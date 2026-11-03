#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

runner="$SRC/out/tests/hmailserver-core-tests"
[ -x "$runner" ] || { echo "missing $runner - mayhem/build.sh should have built it" >&2; emit_ctrf "hmailserver-core-tests" 0 1 0; exit 1; }

out="$("$runner" 2>&1)"; rc=$?
printf '%s\n' "$out"

# The runner prints "SPF conformance: N of M cases decided." only after every RFC 7208 case has
# been evaluated and compared with its expected verdict; one "FAILED:" line per mismatch. A run
# that never reaches that line (crash, neutered binary) counts as one failure.
failed=$(printf '%s\n' "$out" | grep -c '^FAILED:' || true)
if line=$(printf '%s\n' "$out" | grep -E '^SPF conformance: [0-9]+ of [0-9]+ cases decided\.$'); then
  decided=$(printf '%s' "$line" | sed -E 's/^SPF conformance: ([0-9]+) of ([0-9]+).*/\1/')
  total=$(printf '%s' "$line" | sed -E 's/^SPF conformance: ([0-9]+) of ([0-9]+).*/\2/')
else
  decided=0; total=0; failed=$((failed + 1))
fi
[ "$total" -gt 0 ] || failed=$((failed + 1))
[ "$rc" -eq 0 ] || [ "$failed" -gt 0 ] || failed=1
passed=$(( decided > failed ? decided - failed : 0 ))
failed=$(( failed + total - decided ))
emit_ctrf "hmailserver-core-tests" "$passed" "$failed" 0
