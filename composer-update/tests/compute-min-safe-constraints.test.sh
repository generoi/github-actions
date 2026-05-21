#!/usr/bin/env bash
#
# Unit tests for scripts/compute-min-safe-constraints.php
#
# Verifies the per-package "minimum-safe" constraint derivation: pick the
# affected range that contains the locked version, then turn its upper bound
# into a tight ~X.Y.Z (capping at the safe minor). Covers exclusive vs
# inclusive bounds, missing version components, multi-range selection, and the
# no-entry fall-throughs.
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK="$(mktmp)"
ensure_semver_vendor "$WORK"
cd "$WORK"

# run_compute <vulns-json> <lock-json> -> prints the helper's JSON output
run_compute() {
  printf '%s' "$1" > vulns.json
  printf '%s' "$2" > composer.lock
  php "$SCRIPTS_DIR/compute-min-safe-constraints.php" vulns.json composer.lock
}

lock() { # lock <name> <version>
  printf '{"packages":[{"name":"%s","version":"%s"}],"packages-dev":[]}' "$1" "$2"
}

echo "== exclusive upper bound <X.Y.Z => ~X.Y.Z =="
out=$(run_compute '[{"package":"vendor/a","affected":">=7.0.0,<7.4.12"}]' "$(lock vendor/a v7.4.8)")
assert_eq "$(echo "$out" | jq -r '."vendor/a"')" "~7.4.12" "<7.4.12 -> ~7.4.12"

echo "== inclusive upper bound <=X.Y.Z => ~X.Y.(Z+1) =="
out=$(run_compute '[{"package":"vendor/a","affected":"<=2.0.21"}]' "$(lock vendor/a 2.0.10)")
assert_eq "$(echo "$out" | jq -r '."vendor/a"')" "~2.0.22" "<=2.0.21 -> ~2.0.22"

echo "== missing patch <X.Y => ~X.Y.0 (not ~X.Y.) =="
out=$(run_compute '[{"package":"vendor/a","affected":">=10.5,<10.6"}]' "$(lock vendor/a 10.5.3)")
assert_eq "$(echo "$out" | jq -r '."vendor/a"')" "~10.6.0" "<10.6 -> ~10.6.0"

echo "== missing minor+patch <X => ~X.0.0 =="
out=$(run_compute '[{"package":"vendor/a","affected":"<8"}]' "$(lock vendor/a 7.4.0)")
assert_eq "$(echo "$out" | jq -r '."vendor/a"')" "~8.0.0" "<8 -> ~8.0.0"

echo "== multi-range '|': pick the range containing the locked version =="
# Locked 6.4.30 sits in the second range; its bound (<6.4.40) drives the result.
multi='[{"package":"vendor/a","affected":">=7.0.0,<7.4.12|>=6.4.0,<6.4.40"}]'
out=$(run_compute "$multi" "$(lock vendor/a v6.4.30)")
assert_eq "$(echo "$out" | jq -r '."vendor/a"')" "~6.4.40" "selects range matching locked version"

echo "== package not present in lock => no entry =="
out=$(run_compute '[{"package":"vendor/missing","affected":"<2.0.0"}]' "$(lock vendor/other 1.0.0)")
assert_eq "$(echo "$out" | jq -r 'has("vendor/missing")')" "false" "unlocked package omitted"

echo "== locked version not in any affected range => no entry =="
out=$(run_compute '[{"package":"vendor/a","affected":"<7.0.0"}]' "$(lock vendor/a v7.4.8)")
assert_eq "$(echo "$out" | jq -r 'has("vendor/a")')" "false" "already-safe version omitted"

echo "== no parseable upper bound (only lower) => no entry =="
out=$(run_compute '[{"package":"vendor/a","affected":">=1.0.0"}]' "$(lock vendor/a 1.5.0)")
assert_eq "$(echo "$out" | jq -r 'has("vendor/a")')" "false" "no upper bound omitted"

echo "== multiple packages in one run =="
twolock='{"packages":[{"name":"vendor/a","version":"7.4.8"},{"name":"vendor/b","version":"1.2.0"}],"packages-dev":[]}'
out=$(run_compute '[{"package":"vendor/a","affected":"<7.4.12"},{"package":"vendor/b","affected":"<=1.2.3"}]' "$twolock")
assert_eq "$(echo "$out" | jq -r '."vendor/a"')" "~7.4.12" "pkg a"
assert_eq "$(echo "$out" | jq -r '."vendor/b"')" "~1.2.4" "pkg b (inclusive bump)"

finish
