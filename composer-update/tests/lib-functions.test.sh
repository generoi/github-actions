#!/usr/bin/env bash
#
# Unit tests for scripts/lib.sh — the pure-ish helper functions.
#
# Covers the edge cases fixed in:
#   #27  build_pkg_arg trailing newline
#   #29  build_widen_arg caret (^min_safe) widening
#   #28  loosen_constraint same-major loose range
#   #22/#26  find_direct_ancestors BFS + expand_args_for ancestor inclusion
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

CON=/tmp/composer-update-constraints.json
DIRECT=/tmp/composer-update-direct.txt
REVERSE=/tmp/composer-update-reverse.txt

echo "== build_pkg_arg (#27) =="
echo '{"vendor/a":"~1.2.3"}' > "$CON"
assert_eq "$(build_pkg_arg vendor/a)" "vendor/a:~1.2.3" "name:constraint when constrained"
assert_eq "$(build_pkg_arg vendor/b)" "vendor/b" "bare name when unconstrained"
# #27: a bare (direct-dep) arg MUST be newline-terminated or expand_args_for's
# `while read` drops it. command-subst strips the newline, so count lines.
assert_eq "$(build_pkg_arg vendor/b | wc -l | tr -d ' ')" "1" "bare arg is newline-terminated"
assert_eq "$(build_pkg_arg vendor/a | wc -l | tr -d ' ')" "1" "constrained arg is newline-terminated"

echo "== build_widen_arg (#29) =="
echo '{"vendor/a":"~27.1.2"}' > "$CON"
assert_eq "$(build_widen_arg vendor/a)" "vendor/a:^27.1.2" "tight ~X.Y.Z widens to caret ^X.Y.Z"
assert_eq "$(build_widen_arg vendor/b)" "vendor/b" "no constraint -> bare name (unconstrained widen)"
echo '{"vendor/a":">=1.0,<2.0"}' > "$CON"
assert_eq "$(build_widen_arg vendor/a)" "vendor/a" "non-tilde constraint -> bare name"
# Inclusive-bound range (from a `<=X.Y.Z` advisory): widens to a major-capped
# range that keeps the strict-greater lower bound (boundary stays excluded).
echo '{"vendor/a":">1.0.271,<1.1.0"}' > "$CON"
assert_eq "$(build_widen_arg vendor/a)" "vendor/a:>1.0.271,<2.0.0" "inclusive-bound range widens to major-capped range"

echo "== loosen_constraint (#28) =="
assert_eq "$(loosen_constraint '~6.6.4')"  ">=6.6.4,<7.0.0"   "~6.6.4 -> same-major loose range"
assert_eq "$(loosen_constraint '~10.5.3')" ">=10.5.3,<11.0.0" "~10.5.3 -> >=10.5.3,<11.0.0"
assert_eq "$(loosen_constraint '~6.6')"    ""                 "2-part tilde -> empty (needs X.Y.Z)"
assert_eq "$(loosen_constraint '^1.0.0')"  ""                 "caret -> empty"
# Inclusive-bound range loosens its minor cap to a major cap.
assert_eq "$(loosen_constraint '>1.0.271,<1.1.0')" ">1.0.271,<2.0.0" "inclusive-bound range -> major-capped"

echo "== find_direct_ancestors (#22, #26) =="
printf 'roots/wordpress\nvendor/x\n' > "$DIRECT"
printf 'roots/wordpress-no-content roots/wordpress\n' > "$REVERSE"
assert_eq "$(find_direct_ancestors roots/wordpress)" "roots/wordpress" "a direct dep returns itself"
assert_eq "$(find_direct_ancestors roots/wordpress-no-content)" "roots/wordpress" "transitive BFS up to direct ancestor"
# Multi-level BFS: a -> b -> c, only c is direct.
printf 'c\n' > "$DIRECT"
printf 'a b\nb c\n' > "$REVERSE"
assert_eq "$(find_direct_ancestors a)" "c" "multi-level BFS resolves to nearest direct ancestor"
assert_eq "$(find_direct_ancestors unknown)" "" "no ancestor -> empty (no error under pipefail)"

echo "== expand_args_for (#26) =="
echo '{"roots/wordpress-no-content":"~6.8.5"}' > "$CON"
printf 'roots/wordpress\n' > "$DIRECT"
printf 'roots/wordpress-no-content roots/wordpress\n' > "$REVERSE"
# Transitive: emits its own (constrained) arg AND the direct-dep ancestor.
out=$(expand_args_for roots/wordpress-no-content)
assert_contains "$out" "roots/wordpress-no-content:~6.8.5" "transitive's own constrained arg"
assert_contains "$out" "roots/wordpress" "plus the direct-dep ancestor"
# Direct dep: just its own arg, no ancestor line.
echo '{"roots/wordpress":"~6.8.5"}' > "$CON"
assert_eq "$(expand_args_for roots/wordpress)" "roots/wordpress:~6.8.5" "direct dep -> only its own arg"

echo "== get_lock_version =="
printf '{"packages":[{"name":"vendor/a","version":"v1.2.3"}],"packages-dev":[{"name":"dev/b","version":"2.0.0"}]}' > /tmp/_lock.json
assert_eq "$(get_lock_version vendor/a /tmp/_lock.json)" "v1.2.3" "reads version from packages"
assert_eq "$(get_lock_version dev/b /tmp/_lock.json)" "2.0.0" "reads version from packages-dev"
assert_eq "$(get_lock_version vendor/missing /tmp/_lock.json)" "" "absent package -> empty"
rm -f /tmp/_lock.json

finish
