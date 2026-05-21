#!/usr/bin/env bash
#
# Run every composer-update/tests/*.test.sh and report a summary.
# Requires: bash, git, jq, php, composer (the PHP helper tests bootstrap
# composer/semver into a temp vendor dir).
#
# Usage: composer-update/tests/run.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

pass=0
fail=0
for t in *.test.sh; do
  echo "=================================================================="
  echo "RUN  $t"
  echo "=================================================================="
  if bash "$t"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
  echo
done

echo "=================================================================="
echo "SUMMARY: $pass file(s) passed, $fail failed"
echo "=================================================================="
[ "$fail" -eq 0 ]
