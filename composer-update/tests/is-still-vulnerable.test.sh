#!/usr/bin/env bash
#
# Unit tests for scripts/is-still-vulnerable.php  (guard added in #28)
#
# Prints `yes` if a version is inside any of the package's affected ranges,
# else `no`. Used by the loose-constraint retry to avoid accepting a "fix"
# that's still vulnerable. Must fail safe (`no`) on junk input.
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK="$(mktmp)"
ensure_semver_vendor "$WORK"
cd "$WORK"

check() { # check <vulns-json> <pkg> <version>
  printf '%s' "$1" > vulns.json
  php "$SCRIPTS_DIR/is-still-vulnerable.php" vulns.json "$2" "$3"
}

V='[{"package":"vendor/a","affected":">=6.0.0,<6.6.4"}]'

assert_eq "$(check "$V" vendor/a 6.6.0)" "yes" "version inside affected range -> yes"
assert_eq "$(check "$V" vendor/a 6.6.4)" "no"  "version at safe boundary -> no"
assert_eq "$(check "$V" vendor/a 7.0.0)" "no"  "version above range -> no"

echo "== multi-range '|' =="
M='[{"package":"vendor/a","affected":">=5.0,<5.4|>=6.0,<6.6.4"}]'
assert_eq "$(check "$M" vendor/a 6.5.0)" "yes" "matches second range -> yes"
assert_eq "$(check "$M" vendor/a 5.9.0)" "no"  "between ranges -> no"

echo "== package not in vulns -> no =="
assert_eq "$(check "$V" vendor/other 1.0.0)" "no" "unknown package -> no"

echo "== empty affected -> no =="
assert_eq "$(check '[{"package":"vendor/a","affected":""}]' vendor/a 1.0.0)" "no" "empty affected skipped -> no"

echo "== unparseable range ignored, others still checked =="
U='[{"package":"vendor/a","affected":"garbage|>=6.0,<6.6.4"}]'
assert_eq "$(check "$U" vendor/a 6.5.0)" "yes" "bad range skipped, good range matches -> yes"

echo "== invalid vulns JSON fails safe -> no =="
assert_eq "$(check 'not json' vendor/a 1.0.0)" "no" "junk input -> no"

finish
