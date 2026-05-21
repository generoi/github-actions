#!/usr/bin/env bash
#
# Regression test for composer-update/scripts/update.sh
#
# Bug: when EVERY constraint-blocked package is listed in
# extra.vuln-scan.no-widen, the widen-targets dedupe ran `grep -v '^$'` over
# empty input, which exits 1 and (under `set -eo pipefail`) aborted the whole
# step — dropping the PR even though OTHER packages had updated cleanly.
#
# This test drives the real script with a fake `composer` and asserts that a
# safe package (symfony/yaml) still gets updated and changed=true is emitted,
# while a no-widen package (woocommerce) is skipped without aborting.
#
# No network, no real composer. Requires: bash, git, jq.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION_PATH="$SCRIPT_DIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

git init -q
git config user.email test@example.com
git config user.name test

cat > composer.json <<'JSON'
{
    "require": {
        "symfony/yaml": "^7.0",
        "wpackagist-plugin/woocommerce": "10.0.2"
    },
    "extra": {
        "vuln-scan": {
            "no-widen": {
                "wpackagist-plugin/woocommerce": "Pinned — integration-tested against this exact version."
            }
        }
    }
}
JSON

cat > composer.lock <<'JSON'
{
    "packages": [
        { "name": "symfony/yaml", "version": "v7.3.3", "require": {} },
        { "name": "wpackagist-plugin/woocommerce", "version": "10.0.2", "require": {} }
    ],
    "packages-dev": []
}
JSON

git add -A
git commit -qm init

# Fake composer: only a `composer update -W ... symfony/yaml ...` call moves
# symfony/yaml in the lock. woocommerce never moves within constraints (its fix
# is outside the pin) — exactly the scenario that triggered the bug. `require`
# (widen) is a no-op; it must not be reached for the no-widen package anyway.
mkdir bin
cat > bin/composer <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  update*symfony/yaml*)
    tmp=$(mktemp)
    jq '(.packages[] | select(.name=="symfony/yaml") | .version) |= "v7.4.12"' composer.lock > "$tmp" && mv "$tmp" composer.lock
    ;;
esac
exit 0
SH
chmod +x bin/composer
export PATH="$TMP/bin:$PATH"

export PACKAGES="symfony/yaml wpackagist-plugin/woocommerce"
export VULNS_JSON=""
export GITHUB_ACTION_PATH="$ACTION_PATH"
export GITHUB_OUTPUT="$TMP/github_output"
: > "$GITHUB_OUTPUT"

# Run the real script. Before the fix this exits non-zero here.
bash "$ACTION_PATH/scripts/update.sh" > "$TMP/log" 2>&1 || {
  echo "FAIL: update.sh exited non-zero (the no-widen abort bug)"
  cat "$TMP/log"
  exit 1
}

fail() { echo "FAIL: $1"; echo "--- output ---"; cat "$TMP/github_output"; echo "--- log ---"; cat "$TMP/log"; exit 1; }

grep -q '^changed=true' "$GITHUB_OUTPUT" || fail "expected changed=true in GITHUB_OUTPUT"
jq -e '.packages[] | select(.name=="symfony/yaml" and .version=="v7.4.12")' composer.lock >/dev/null \
  || fail "expected symfony/yaml bumped to v7.4.12 in composer.lock"
jq -e '.packages[] | select(.name=="wpackagist-plugin/woocommerce" and .version=="10.0.2")' composer.lock >/dev/null \
  || fail "expected woocommerce left at its pinned 10.0.2"
grep -q "skip wpackagist-plugin/woocommerce — listed in extra.vuln-scan.no-widen" "$TMP/log" \
  || fail "expected woocommerce to be skipped via no-widen"

echo "PASS: safe package updated, no-widen package skipped, PR would be created"
