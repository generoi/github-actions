#!/usr/bin/env bash
#
# Integration tests for scripts/open-or-refresh-pr.sh — the create / refresh
# orchestration extracted from action.yml. Drives the real script with a fake
# `gh` on PATH and a local bare repo as `origin`, so pushes / PR calls are
# observable without network or auth.
#
# Covers: create (opens a PR + pushes a branch), create-with-no-fix (no-op),
# update-with-change (force-pushes the existing head + edits + comments),
# update-without-change (edits/comments only, no force-push), and that the
# (A) still-vulnerable section is surfaced in the body.
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$SCRIPTS_DIR/open-or-refresh-pr.sh"

# Fake `gh`: log every invocation (and the contents of any --body-file) to
# $GH_LOG; echo a URL for `pr create`.
make_fake_gh() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'SH'
#!/usr/bin/env bash
{
  echo "ARGS: $*"
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--body-file" ] && [ -f "$a" ]; then
      echo "BODY<<"; cat "$a"; echo; echo ">>BODY"
    fi
    prev="$a"
  done
} >> "$GH_LOG"
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  echo "https://github.com/acme/repo/pull/777"
fi
exit 0
SH
  chmod +x "$bin/gh"
}

# new_repo_with_origin — working repo on `master` with a bare `origin` already
# holding the base commit, a fake gh on PATH, and fresh GH_LOG / GITHUB_OUTPUT.
# Sets globals: WORK ORIGIN BIN GH_LOG OUT
new_repo_with_origin() {
  WORK="$(mktmp)"
  ORIGIN="$(mktmp)/origin.git"
  BIN="$(mktmp)/bin"
  GH_LOG="$(mktmp)/gh.log"
  OUT="$(mktmp)/out"
  make_fake_gh "$BIN"
  : > "$GH_LOG"
  : > "$OUT"
  git init -q --bare "$ORIGIN"
  git init -q "$WORK"
  (
    cd "$WORK"
    git config user.email t@e.com && git config user.name t
    echo '{"require":{}}' > composer.json
    echo '{"packages":[],"packages-dev":[]}' > composer.lock
    git add -A && git commit -qm init
    git branch -M master
    git remote add origin "$ORIGIN"
    git push -q origin master
  )
}

# run_orchestrator — run the script in WORK with the given env (passed as
# KEY=VALUE args). Common env (auth off so pushes hit the local origin, fake gh
# on PATH, outputs captured) is supplied automatically.
run_orchestrator() {
  (
    cd "$WORK"
    export PATH="$BIN:$PATH"
    export GH_TOKEN="" GH_LOG="$GH_LOG" GITHUB_OUTPUT="$OUT"
    export REPO="acme/repo" SERVER_URL="https://github.com" RUN_NUMBER="5" RUN_ID="99"
    export PR_TITLE="Update vulnerable packages" PR_LABEL="vuln-update" BRANCH_PREFIX="fix/vuln-update"
    export VERSIONS_FILE="/dev/null" STILL_VULN_FILE="/dev/null"
    env "$@" bash "$SCRIPT"
  ) >/dev/null 2>&1 || true
}

origin_refs() { git -C "$ORIGIN" for-each-ref --format='%(refname)'; }
origin_sha()  { git -C "$ORIGIN" rev-parse "refs/heads/$1" 2>/dev/null; }

echo "== create: opens a PR and pushes a fix branch =="
new_repo_with_origin
( cd "$WORK"; echo '{"packages":[{"name":"vendor/x","version":"1.0.5"}],"packages-dev":[]}' > composer.lock )
run_orchestrator MODE=create CHANGED=true PACKAGES=vendor/x PR_BODY='<!-- vuln-update-set: vendor/x -->'
assert_contains "$(cat "$GH_LOG")" "pr create" "gh pr create was called"
assert_contains "$(cat "$OUT")" "outcome=created" "outcome=created"
assert_contains "$(cat "$OUT")" "pr_url=https://github.com/acme/repo/pull/777" "pr_url captured from gh"
assert_contains "$(origin_refs)" "refs/heads/fix/vuln-update" "a fix branch was pushed to origin"

echo "== create + no resolvable fix: nothing opened =="
new_repo_with_origin
run_orchestrator MODE=create CHANGED=false PACKAGES=vendor/x PR_BODY='x'
assert_not_contains "$(cat "$GH_LOG")" "pr create" "no PR created when nothing changed"
assert_contains "$(cat "$OUT")" "outcome=none" "outcome=none"

echo "== update + change: force-pushes existing head, edits + comments =="
new_repo_with_origin
( cd "$WORK"
  git checkout -q -b fix/vuln-update-old
  git commit -q --allow-empty -m "old fix"
  git push -q origin fix/vuln-update-old
  git checkout -q master
  echo '{"packages":[{"name":"vendor/x","version":"1.0.6"}],"packages-dev":[]}' > composer.lock )
OLD_SHA="$(origin_sha fix/vuln-update-old)"
run_orchestrator MODE=update CHANGED=true PACKAGES=vendor/x \
  EXISTING_NUM=42 EXISTING_HEAD=fix/vuln-update-old EXISTING_URL=https://github.com/acme/repo/pull/42 \
  PR_BODY='<!-- vuln-update-set: vendor/x -->'
assert_eq "$([ "$(origin_sha fix/vuln-update-old)" != "$OLD_SHA" ] && echo moved || echo same)" "moved" "existing head was force-pushed"
assert_contains "$(cat "$GH_LOG")" "pr edit 42" "PR body was refreshed (gh pr edit)"
assert_contains "$(cat "$GH_LOG")" "pr comment 42" "a timeline comment was posted"
assert_contains "$(cat "$OUT")" "outcome=refreshed" "outcome=refreshed"

echo "== update + no fix: edits/comments only, no force-push =="
new_repo_with_origin
( cd "$WORK"
  git checkout -q -b fix/vuln-update-old
  git commit -q --allow-empty -m "old fix"
  git push -q origin fix/vuln-update-old
  git checkout -q master )
OLD_SHA="$(origin_sha fix/vuln-update-old)"
run_orchestrator MODE=update CHANGED=false PACKAGES=vendor/x \
  EXISTING_NUM=42 EXISTING_HEAD=fix/vuln-update-old EXISTING_URL=https://github.com/acme/repo/pull/42 \
  PR_BODY='<!-- vuln-update-set: vendor/x,vendor/y -->'
assert_eq "$(origin_sha fix/vuln-update-old)" "$OLD_SHA" "existing head untouched (no force-push)"
assert_contains "$(cat "$GH_LOG")" "pr edit 42" "body still refreshed so the marker stays current"
assert_contains "$(cat "$OUT")" "outcome=refreshed" "outcome=refreshed"

echo "== (A) still-vulnerable packages surface in the PR body =="
new_repo_with_origin
( cd "$WORK"; echo '{"packages":[{"name":"vendor/x","version":"1.0.5"}],"packages-dev":[]}' > composer.lock )
STILL="$(mktmp)/still.txt"; printf 'vendor/z\t1.2.3\n' > "$STILL"
run_orchestrator MODE=create CHANGED=true PACKAGES=vendor/x \
  STILL_VULN_FILE="$STILL" PR_BODY='<!-- vuln-update-set: vendor/x -->'
assert_contains "$(cat "$GH_LOG")" "Still vulnerable after update" "body has the triage section"
assert_contains "$(cat "$GH_LOG")" "vendor/z" "the unfixed package is listed in the body"

finish
