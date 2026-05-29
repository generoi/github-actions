#!/usr/bin/env bash
#
# Open a new auto-update PR, or refresh the existing one in place.
#
# Extracted from action.yml so the create / refresh orchestration is testable
# (see tests/open-or-refresh-pr.test.sh). The skip decision is made upstream by
# decide_pr_action(); this script only handles MODE in {create, update} and is
# invoked when there is something to do.
#
# Inputs via env:
#   MODE           create | update
#   CHANGED        true | false  (did the lock actually change?)
#   PACKAGES       space-separated flagged package names (for the commit body)
#   PR_TITLE PR_LABEL BRANCH_PREFIX PR_BODY
#   REPO SERVER_URL RUN_NUMBER RUN_ID        (for the run link / auth rewrite)
#   EXISTING_NUM EXISTING_HEAD EXISTING_URL  (update mode: the PR to refresh)
#   GH_TOKEN       when set (with REPO), rewrite origin auth for the push
#   GITHUB_OUTPUT  step outputs (pr_url, outcome)
# Optional (defaulted; overridable for tests):
#   VERSIONS_FILE   default /tmp/composer-update-versions.md
#   STILL_VULN_FILE default /tmp/composer-update-still-vulnerable.txt
#
# Outputs (to GITHUB_OUTPUT):
#   pr_url   the created/refreshed PR
#   outcome  created | refreshed | none
set -eo pipefail

VERSIONS_FILE="${VERSIONS_FILE:-/tmp/composer-update-versions.md}"
STILL_VULN_FILE="${STILL_VULN_FILE:-/tmp/composer-update-still-vulnerable.txt}"
BODY_FILE="$(mktemp)"
COMMENT_FILE="$(mktemp)"
COMMIT_FILE="$(mktemp)"

emit() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"; }

# Assemble the PR body: scan-provided body + the Version changes table (if any)
# + (A) an explicit "still vulnerable" triage section so we never silently
# present a package as fixed when it isn't.
{
  printf '%s' "$PR_BODY"
  if [ -s "$VERSIONS_FILE" ]; then
    cat "$VERSIONS_FILE"
  fi
  if [ -s "$STILL_VULN_FILE" ]; then
    echo ""
    echo "### ⚠️ Still vulnerable after update — manual triage needed"
    echo ""
    echo "These flagged packages did not reach a safe version and are **not** fixed by this PR:"
    echo ""
    while IFS=$'\t' read -r pkg ver; do
      [ -n "$pkg" ] && echo "- \`$pkg\` (now \`${ver:-unchanged}\`)"
    done < "$STILL_VULN_FILE"
  fi
} > "$BODY_FILE"

# create + no resolvable fix → nothing to open, and no existing PR to refresh.
# (The unfixable finding still surfaces via the caller's alert.)
if [ "$MODE" = "create" ] && [ "$CHANGED" != "true" ]; then
  echo "No update available and no existing PR — nothing to open"
  emit outcome none
  exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

# In CI, actions/checkout pins a tokened auth (includeIf + extraheader) that
# overrides our push credentials — clear it and point origin at the token.
# Skipped when GH_TOKEN is empty (tests push to a local origin as-is).
if [ -n "${GH_TOKEN:-}" ] && [ -n "${REPO:-}" ]; then
  for key in $(git config --local --name-only --get-regexp '^includeIf\.gitdir:' 2>/dev/null); do
    git config --local --unset-all "$key" 2>/dev/null || true
  done
  git config --local --unset-all 'http.https://github.com/.extraheader' 2>/dev/null || true
  git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"
fi

# Commit the working-tree fix. Title in subject, package list in body so
# `git blame` on composer.lock answers "why did this version change?".
commit_fix() {
  git add composer.json composer.lock
  {
    printf '%s\n\n' "$PR_TITLE"
    echo "Updated packages:"
    for pkg in $PACKAGES; do
      echo "- $pkg"
    done
  } > "$COMMIT_FILE"
  git commit -F "$COMMIT_FILE"
}

if [ "$MODE" = "create" ]; then
  BRANCH="${BRANCH_PREFIX}-$(date +%Y%m%d-%H%M%S)"
  git checkout -b "$BRANCH"
  commit_fix
  git push origin "$BRANCH"
  # Ensure the dedup label exists (idempotent — no-ops if present).
  gh label create "$PR_LABEL" \
    --color FFAA00 \
    --description "Auto-generated dependency update PR" \
    2>/dev/null || true
  PR_URL=$(gh pr create --title "$PR_TITLE" --label "$PR_LABEL" --body-file "$BODY_FILE")
  echo "Created PR: $PR_URL"
  emit pr_url "$PR_URL"
  emit outcome created
  exit 0
fi

# MODE=update: refresh the existing PR in place so it always reflects the
# current findings, rather than opening a second PR or letting it go stale.
if [ "$CHANGED" = "true" ]; then
  # Force the PR's head branch to "base + current fix": we're on the freshly
  # updated checkout, so commit here and force-push to the existing head.
  git checkout -b "refresh-$(date +%Y%m%d-%H%M%S)"
  commit_fix
  git push -f origin "HEAD:${EXISTING_HEAD}"
  echo "Refreshed branch '$EXISTING_HEAD' on PR #$EXISTING_NUM"
else
  echo "New findings have no resolvable fix — refreshing PR #$EXISTING_NUM body/comment only"
fi

# Rewrite the body so the set marker tracks the latest findings (this is what
# lets an unchanged set hit `skip` next run instead of re-posting), and leave a
# timeline comment. Only runs in `update` mode (set genuinely changed), so it
# can't recur daily on a static finding set.
gh pr edit "$EXISTING_NUM" --body-file "$BODY_FILE"
{
  printf '## Findings changed — refreshed by [run #%s](%s/%s/actions/runs/%s)\n\n' \
    "$RUN_NUMBER" "$SERVER_URL" "$REPO" "$RUN_ID"
  printf '%s\n' "$PR_BODY"
} > "$COMMENT_FILE"
gh pr comment "$EXISTING_NUM" --body-file "$COMMENT_FILE"
emit pr_url "$EXISTING_URL"
emit outcome refreshed
