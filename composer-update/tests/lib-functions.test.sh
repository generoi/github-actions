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

echo "== normalize_widen_constraint =="
# The precision guard consults is_still_vulnerable, which shells out to PHP +
# composer/semver against the CWD's vendor dir. Stub it here so these stay
# pure unit tests; the real wiring is covered end-to-end in
# update-orchestration.test.sh. Stub semantics: vendor/seo is affected <=28.0.
_real_is_still_vulnerable=$(declare -f is_still_vulnerable)
is_still_vulnerable() {
  case "$1:$2" in
    vendor/seo:28.0.0) echo yes ;;
    *) echo no ;;
  esac
}

# The headline case: Yoast's `<=28.0` advisory. Author wrote `^27.6`, so the
# 2-part precision is preserved and the raw range becomes `^28.1`.
assert_eq "$(normalize_widen_constraint '>28.0.0,<29.0.0' '^27.6' '28.1.0' vendor/seo)" \
  "^28.1" "raw range + 2-part author style -> ^28.1"
# Precision guard: same author style, but the fix shipped as a PATCH. `^28.0`
# would mean >=28.0.0 and re-admit the vulnerable 28.0.0, so we must keep the
# third segment.
assert_eq "$(normalize_widen_constraint '>28.0.0,<29.0.0' '^27.6' '28.0.1' vendor/seo)" \
  "^28.0.1" "precision guard: reduced caret would re-admit the advisory"
# 4-segment hotfix (the `<=1.0.271` -> 1.0.271.1 case build_widen_arg exists for).
assert_eq "$(normalize_widen_constraint '>1.0.271,<2.0.0' '^1.0' '1.0.271.1' vendor/x)" \
  "^1.0" "4-segment hotfix, author style honored when floor is safe"
# No style signal (author had a range/pin) -> full resolved precision.
assert_eq "$(normalize_widen_constraint '>6.6.3,<7.0.0' '>=6.0' '6.7.2' vendor/x)" \
  "^6.7.2" "no caret/tilde to imitate -> full resolved version"
assert_eq "$(normalize_widen_constraint '>27.0.0,<28.0.0' '^27.6.1' '28.1.0' vendor/x)" \
  "^28.1.0" "3-part author style preserved"
# Already-idiomatic constraints are left alone — nothing to normalize.
assert_eq "$(normalize_widen_constraint '^27.1.2' '^26.0' '27.6.0' vendor/x)" \
  "" "caret written by the ~min_safe path -> no rewrite"
assert_eq "$(normalize_widen_constraint '~27.1.2' '^26.0' '27.1.2' vendor/x)" \
  "" "tilde -> no rewrite"
assert_eq "$(normalize_widen_constraint '10.0.2' '10.0.1' '10.0.2' vendor/x)" \
  "" "exact pin is a deliberate choice -> no rewrite"
assert_eq "$(normalize_widen_constraint '' '^1.0' '1.2.3' vendor/x)" \
  "" "empty written constraint -> no rewrite"
# Non-numeric resolution (dev-*) has no caret to anchor to. update.sh reverts
# these anyway; belt and braces.
assert_eq "$(normalize_widen_constraint '>1.0.0,<2.0.0' '^1.0' 'dev-trunk' vendor/x)" \
  "" "dev-* resolution -> no rewrite"
# Composer locks tag-style releases with a leading v; constraints omit it.
assert_eq "$(normalize_widen_constraint '>1.0.0,<2.0.0' '^1.0' 'v1.2.3' vendor/x)" \
  "^1.2" "leading v stripped from the resolved version"
# Author precision deeper than the resolved version clamps instead of padding.
assert_eq "$(normalize_widen_constraint '>27.0.0,<29.0.0' '^27.6.1' '28.1' vendor/x)" \
  "^28.1" "author precision clamped to the resolved segment count"

eval "$_real_is_still_vulnerable"

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

echo "== extract_pr_set =="
body_a='blah
<!-- vuln-update-set: a/x,b/y -->
## title'
assert_eq "$(extract_pr_set "$body_a" vuln-update-set)" "a/x,b/y" "extracts the marker set"
assert_eq "$(extract_pr_set "no marker here" vuln-update-set)" "" "absent marker -> empty"
assert_eq "$(extract_pr_set "$body_a" dependencies-set)" "" "different label key -> empty"

echo "== decide_pr_action =="
assert_eq "$(decide_pr_action false 'a,b' '')"      "create" "no existing PR -> create"
assert_eq "$(decide_pr_action true  'a,b' 'a,b')"   "skip"   "same set -> skip (silent)"
assert_eq "$(decide_pr_action true  'a,b,c' 'a,b')" "update" "set grew -> update in place"
assert_eq "$(decide_pr_action true  'a' 'a,b')"     "update" "set shrank -> update in place"
assert_eq "$(decide_pr_action true  '' 'a,b')"      "update" "empty new set (no marker) -> update, never silent"

echo "== get_lock_version =="
printf '{"packages":[{"name":"vendor/a","version":"v1.2.3"}],"packages-dev":[{"name":"dev/b","version":"2.0.0"}]}' > /tmp/_lock.json
assert_eq "$(get_lock_version vendor/a /tmp/_lock.json)" "v1.2.3" "reads version from packages"
assert_eq "$(get_lock_version dev/b /tmp/_lock.json)" "2.0.0" "reads version from packages-dev"
assert_eq "$(get_lock_version vendor/missing /tmp/_lock.json)" "" "absent package -> empty"
rm -f /tmp/_lock.json

finish
