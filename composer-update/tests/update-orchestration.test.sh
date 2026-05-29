#!/usr/bin/env bash
#
# Integration tests for scripts/update.sh — drives the real script end-to-end
# with a fake `composer` (no network) and asserts the Step 1 / Step 2 guards.
#
# Covers:
#   #24  revert a `composer require` outcome that DOWNGRADES the package
#   #21  revert a `composer require` that resolves to a dev-* constraint
#   #23  per-package retry: one unfixable package doesn't widen the rest
#   #20  no-widen honored when given as a JSON array (not just a map)
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$SCRIPTS_DIR/lib.sh"   # get_lock_version for assertions

# A fake-composer helper that bumps a package's locked version via jq. Paste
# into a fake-composer body as needed.
JQ_BUMP='bump(){ tmp=$(mktemp); jq --arg n "$1" --arg v "$2" "(.packages[]|select(.name==\$n).version)=\$v" composer.lock > "$tmp" && mv "$tmp" composer.lock; }'

echo "=================================================================="
echo "#24 — composer require that downgrades is reverted"
echo "=================================================================="
new_project \
  '{"require":{"vendor/wp":"^6.6"}}' \
  '{"packages":[{"name":"vendor/wp","version":"6.6.4","require":{}}],"packages-dev":[]}' \
  '
args="$*"
case "$args" in
  update*)  : ;;   # fix is outside ^6.6 — nothing moves within constraints
  require*vendor/wp*)
    # Unconstrained require walks DOWN to 5.9.3 and rewrites the constraint.
    tmp=$(mktemp); jq "(.packages[]|select(.name==\"vendor/wp\").version)=\"5.9.3\"" composer.lock > "$tmp" && mv "$tmp" composer.lock
    tmp=$(mktemp); jq ".require[\"vendor/wp\"]=\"^5.9\"" composer.json > "$tmp" && mv "$tmp" composer.json
    ;;
esac
exit 0'
export PACKAGES="vendor/wp"
run_update ""
assert_eq "$(json_constraint vendor/wp)" "^6.6" "composer.json constraint reverted (not ^5.9)"
assert_eq "$(get_lock_version vendor/wp composer.lock)" "6.6.4" "lock version reverted (not 5.9.3)"
assert_contains "$RUN_LOG" "downgrade 6.6.4" "logged the downgrade revert"
assert_contains "$(cat "$GITHUB_OUTPUT")" "changed=false" "no PR (nothing safely updatable)"

echo "=================================================================="
echo "#21 — composer require that resolves to dev-* is reverted"
echo "=================================================================="
new_project \
  '{"require":{"vendor/plugin":"^1.0"}}' \
  '{"packages":[{"name":"vendor/plugin","version":"1.1.1","require":{}}],"packages-dev":[]}' \
  '
args="$*"
case "$args" in
  update*) : ;;
  require*vendor/plugin*)
    tmp=$(mktemp); jq "(.packages[]|select(.name==\"vendor/plugin\").version)=\"dev-trunk\"" composer.lock > "$tmp" && mv "$tmp" composer.lock
    tmp=$(mktemp); jq ".require[\"vendor/plugin\"]=\"dev-trunk\"" composer.json > "$tmp" && mv "$tmp" composer.json
    ;;
esac
exit 0'
export PACKAGES="vendor/plugin"
run_update ""
assert_eq "$(json_constraint vendor/plugin)" "^1.0" "dev-* constraint reverted"
assert_contains "$RUN_LOG" "resolved to dev branch constraint" "logged the dev-* revert"
assert_contains "$(cat "$GITHUB_OUTPUT")" "changed=false" "no PR"

echo "=================================================================="
echo "#23 — one unfixable package doesn't force-widen the fixable ones"
echo "=================================================================="
# Bulk update (both pkgs) fails transactionally; per-package retry moves
# vendor/good within ^1.0; vendor/bad is unfixable (and pinned no-widen).
new_project \
  '{"require":{"vendor/good":"^1.0","vendor/bad":"^1.0"},"extra":{"vuln-scan":{"no-widen":{"vendor/bad":"pinned"}}}}' \
  '{"packages":[{"name":"vendor/good","version":"1.0.0","require":{}},{"name":"vendor/bad","version":"1.0.0","require":{}}],"packages-dev":[]}' \
  '
args="$*"
if [[ "$args" == update*vendor/good*vendor/bad* || "$args" == update*vendor/bad*vendor/good* ]]; then
  exit 1   # transactional batch rolls back because vendor/bad is unsatisfiable
elif [[ "$args" == update*vendor/good* ]]; then
  tmp=$(mktemp); jq "(.packages[]|select(.name==\"vendor/good\").version)=\"1.0.5\"" composer.lock > "$tmp" && mv "$tmp" composer.lock
fi
exit 0'
export PACKAGES="vendor/good vendor/bad"
run_update ""
assert_eq "$(get_lock_version vendor/good composer.lock)" "1.0.5" "good moved within constraint via per-package retry"
assert_eq "$(json_constraint vendor/good)" "^1.0" "good NOT widened (constraint untouched)"
assert_eq "$(get_lock_version vendor/bad composer.lock)" "1.0.0" "bad unchanged"
assert_contains "$RUN_LOG" "skip vendor/bad — listed in extra.vuln-scan.no-widen" "bad skipped via no-widen"
assert_contains "$(cat "$GITHUB_OUTPUT")" "changed=true" "PR raised for the package that did update"

echo "=================================================================="
echo "#20 — no-widen honored as a JSON array (not only a map)"
echo "=================================================================="
new_project \
  '{"require":{"vendor/safe":"^1.0","vendor/x":"1.0.0"},"extra":{"vuln-scan":{"no-widen":["vendor/x"]}}}' \
  '{"packages":[{"name":"vendor/safe","version":"1.0.0","require":{}},{"name":"vendor/x","version":"1.0.0","require":{}}],"packages-dev":[]}' \
  '
args="$*"
case "$args" in
  update*vendor/safe*)
    tmp=$(mktemp); jq "(.packages[]|select(.name==\"vendor/safe\").version)=\"1.0.5\"" composer.lock > "$tmp" && mv "$tmp" composer.lock
    ;;
esac
exit 0'
export PACKAGES="vendor/safe vendor/x"
run_update ""
assert_eq "$(get_lock_version vendor/safe composer.lock)" "1.0.5" "safe package updated"
assert_eq "$(json_constraint vendor/x)" "1.0.0" "no-widen (array form) left x pinned"
assert_contains "$RUN_LOG" "skip vendor/x — listed in extra.vuln-scan.no-widen" "array-form no-widen honored"

finish
