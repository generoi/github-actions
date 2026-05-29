#!/usr/bin/env bash
#
# Shared helpers for composer-update tests. Source this from a *.test.sh file:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Provides: assert_eq, assert_contains, assert_not_contains, assert_exit,
# pass/fail bookkeeping (call `finish` at the end), a temp-dir factory, a
# fake-composer builder, and a composer/semver bootstrap for the PHP helpers.

ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$ACTION_DIR/scripts"

_tests=0
_fails=0

_red()   { printf '\033[31m%s\033[0m\n' "$1"; }
_green() { printf '\033[32m%s\033[0m\n' "$1"; }

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-}"
  _tests=$((_tests + 1))
  if [ "$actual" = "$expected" ]; then
    _green "  ok: ${msg:-equal}"
  else
    _fails=$((_fails + 1))
    _red "  FAIL: ${msg:-equal}"
    printf '    expected: %q\n    actual:   %q\n' "$expected" "$actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  _tests=$((_tests + 1))
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    _green "  ok: ${msg:-contains '$needle'}"
  else
    _fails=$((_fails + 1))
    _red "  FAIL: ${msg:-contains '$needle'}"
    printf '    needle: %q\n    in:     %q\n' "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  _tests=$((_tests + 1))
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    _fails=$((_fails + 1))
    _red "  FAIL: ${msg:-does not contain '$needle'}"
    printf '    unexpectedly found: %q\n' "$needle"
  else
    _green "  ok: ${msg:-does not contain '$needle'}"
  fi
}

# assert_exit <expected-code> <cmd...> — runs cmd, compares its exit code.
assert_exit() {
  local expected="$1"; shift
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  _tests=$((_tests + 1))
  if [ "$actual" = "$expected" ]; then
    _green "  ok: exit $expected"
  else
    _fails=$((_fails + 1))
    _red "  FAIL: expected exit $expected, got $actual ($*)"
  fi
}

_tmpdirs=()
_cleanup_tmpdirs() { local d; for d in "${_tmpdirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap _cleanup_tmpdirs EXIT

finish() {
  echo "------------------------------------------------------------"
  if [ "$_fails" -eq 0 ]; then
    _green "PASS — $_tests assertion(s)"
    exit 0
  fi
  _red "FAIL — $_fails of $_tests assertion(s) failed"
  exit 1
}

# mktmp — create a temp dir, registered for cleanup at exit. (Must NOT set its
# own EXIT trap: callers use `d=$(mktmp)`, and a trap set inside that
# command-substitution subshell would fire — deleting the dir — the moment the
# subshell returns, before the caller can use it.)
mktmp() {
  local d
  d="$(mktemp -d)"
  _tmpdirs+=("$d")
  echo "$d"
}

# write_fake_composer <bin-dir> <body> — drop an executable `composer` shim into
# bin-dir whose body is the given bash. The shim receives composer's args.
write_fake_composer() {
  local dir="$1" body="$2"
  mkdir -p "$dir"
  {
    echo '#!/usr/bin/env bash'
    echo "$body"
  } > "$dir/composer"
  chmod +x "$dir/composer"
}

# new_project <composer.json> <composer.lock> <fake-composer-body> — create a
# git-initialised temp project with the given manifest/lock and a fake `composer`
# shim on PATH, cd into it, and export the env update.sh expects. Echoes nothing;
# leaves you in the project dir with GH_OUTPUT pointing at ./github_output.
new_project() {
  local manifest="$1" lock="$2" composer_body="$3"
  local dir
  dir="$(mktmp)"
  cd "$dir"
  git init -q
  git config user.email test@example.com
  git config user.name test
  printf '%s' "$manifest" > composer.json
  printf '%s' "$lock" > composer.lock
  git add -A && git commit -qm init
  write_fake_composer "$dir/bin" "$composer_body"
  export PATH="$dir/bin:$PATH"
  export GITHUB_ACTION_PATH="$SCRIPTS_DIR"
  export GITHUB_OUTPUT="$dir/github_output"
  : > "$GITHUB_OUTPUT"
}

# run_update [VULNS_JSON] — run the real update.sh with PACKAGES already exported,
# capturing combined output into $RUN_LOG and its exit code into $RUN_EXIT.
run_update() {
  export VULNS_JSON="${1:-}"
  RUN_LOG=$(bash "$SCRIPTS_DIR/update.sh" 2>&1); RUN_EXIT=$?
  export RUN_LOG RUN_EXIT
}

# json_constraint <pkg> — echo the require/require-dev constraint for a package
# from the CWD composer.json (empty if absent).
json_constraint() {
  jq -r --arg p "$1" '(.require // {})[$p] // (.["require-dev"] // {})[$p] // ""' composer.json
}

# ensure_semver_vendor <dir> — make `$dir/vendor/autoload.php` provide
# composer/semver (what the PHP helpers require via getcwd()/vendor). Cached in
# a shared location so we only hit the network once per test run.
ensure_semver_vendor() {
  local target="$1"
  local cache="${TMPDIR:-/tmp}/composer-update-test-semver"
  if [ ! -f "$cache/vendor/autoload.php" ]; then
    mkdir -p "$cache"
    ( cd "$cache" && composer require composer/semver --no-interaction --quiet >/dev/null 2>&1 )
  fi
  mkdir -p "$target"
  cp -R "$cache/vendor" "$target/vendor"
}
