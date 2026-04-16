#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
cd "/workspaces/$WORKSPACE"

# Install Claude CLI if missing
if ! command -v claude &>/dev/null; then
  curl -fsSL https://claude.ai/install.sh | bash
  export PATH="$HOME/.local/bin:$PATH"
fi

# Git auth
git config --global credential.helper "!f() { echo username=x-access-token; echo password=\${CODESPACE_TOKEN}; }; f"
git config --global url."https://github.com/".insteadOf "git@github.com:"
git fetch origin
git submodule update --init --recursive --force 2>/dev/null || true

# Clean up stale worktrees from previous runs
git worktree prune 2>/dev/null || true
for wt in .claude/worktrees/*/; do
  [ -d "$wt" ] && git worktree remove --force "$wt" 2>/dev/null || true
done

# Determine the working branch
ISSUE_BRANCH="claude/issue-${GITHUB_ISSUE}"
if [ -n "${CI_BRANCH:-}" ]; then
  WORK_BRANCH="$CI_BRANCH"
elif git rev-parse --verify "origin/$ISSUE_BRANCH" &>/dev/null; then
  WORK_BRANCH="$ISSUE_BRANCH"
else
  WORK_BRANCH=""
fi

# Always update master to latest
git checkout master 2>/dev/null || true
git reset --hard origin/master

# Check out existing branch and rebase, or stay on fresh master
if [ -n "$WORK_BRANCH" ]; then
  git checkout "$WORK_BRANCH" 2>/dev/null || git checkout -b "$WORK_BRANCH" "origin/$WORK_BRANCH"
  git rebase origin/master 2>/dev/null || git rebase --abort 2>/dev/null || true
fi

# GitHub CLI auth
echo "${CODESPACE_TOKEN}" | gh auth login --with-token 2>/dev/null || true

# Append CI instructions to prompt
if [ -n "${CI_BRANCH:-}" ]; then
  printf '\n\nCI instructions (always follow):\n' >> /tmp/claude-prompt.txt
  printf -- '- You are on branch %s. Make changes and push to this branch.\n' "$CI_BRANCH" >> /tmp/claude-prompt.txt
  printf -- '- Preview URL: %s\n' "$CODESPACE_PREVIEW_URL" >> /tmp/claude-prompt.txt
else
  printf '\n\nCI instructions (always follow):\n' >> /tmp/claude-prompt.txt
  printf -- '- If your task involves code changes: create branch claude/issue-%s, commit changes, push, and create a PR linking to #%s.\n' "$GITHUB_ISSUE" "$GITHUB_ISSUE" >> /tmp/claude-prompt.txt
  printf -- '- If it is a question or investigation: just respond in the comment, no PR needed.\n' >> /tmp/claude-prompt.txt
  printf -- '- Preview URL: %s\n' "$CODESPACE_PREVIEW_URL" >> /tmp/claude-prompt.txt
fi

PROMPT=$(cat /tmp/claude-prompt.txt)
# Use github-issue agent if available, otherwise plain prompt
AGENT_FLAG=""
if [ -f .claude/agents/github-issue.md ]; then
  AGENT_FLAG="--agent github-issue"
fi
JSON=$(claude -p --verbose --dangerously-skip-permissions --output-format json \
  $AGENT_FLAG "$PROMPT" 2>/tmp/claude-stderr.log) || true

if [ -s /tmp/claude-stderr.log ]; then
  echo "::warning::Claude stderr: $(head -5 /tmp/claude-stderr.log)"
fi

if [ -z "$JSON" ]; then
  STDERR=$(cat /tmp/claude-stderr.log 2>/dev/null || echo "unknown error")
  RESULT="⚠️ Claude produced no output. Error: ${STDERR}"
fi
RESULT=${RESULT:-$(echo "$JSON" | jq -r 'if type == "array" then .[-1].result else .result end // "No response"')}
COST=$(echo "$JSON" | jq -r 'if type == "array" then .[-1].total_cost_usd else .total_cost_usd end // 0')
COST_DISPLAY=$(printf '$%.2f' "$COST")

DURATION=$(echo "$JSON" | jq -r 'if type == "array" then .[-1].duration_ms else .duration_ms end // 0')
DURATION_DISPLAY=$(printf '%ds' "$((DURATION / 1000))")
TURNS=$(echo "$JSON" | jq -r 'if type == "array" then .[-1].num_turns else .num_turns end // 0')

# Auto-screenshot if Claude didn't embed one
SCREENSHOT_MD=""
if [ -n "$CLOUDINARY_CLOUD_NAME" ] && [ -n "$CLOUDINARY_UPLOAD_PRESET" ] && ! echo "$RESULT" | grep -q '!\[.*\](http'; then
  if timeout 30 npx playwright screenshot --ignore-https-errors --wait-for-timeout=3000 \
    "$CODESPACE_PREVIEW_URL" /tmp/screenshot.png 2>/dev/null; then
    IMG_URL=$(curl -s -X POST \
      -F "file=@/tmp/screenshot.png" \
      -F "upload_preset=$CLOUDINARY_UPLOAD_PRESET" \
      "https://api.cloudinary.com/v1_1/$CLOUDINARY_CLOUD_NAME/image/upload" | jq -r '.secure_url // empty')
    if [ -n "$IMG_URL" ]; then
      SCREENSHOT_MD=$(printf '\n\n![Preview screenshot](%s)' "$IMG_URL")
    fi
  fi
fi

BODY=$(printf '%s\n\n---\n🔗 [Preview](%s) · 💰 %s · ⏱️ %s · 🔄 %s turns%s' "$RESULT" "$CODESPACE_PREVIEW_URL" "$COST_DISPLAY" "$DURATION_DISPLAY" "$TURNS" "$SCREENSHOT_MD")
if [ -n "${CI_PR_NUMBER:-}" ]; then
  gh pr comment "$CI_PR_NUMBER" -R "$GITHUB_REPOSITORY" --body "$BODY"
else
  gh issue comment "$GITHUB_ISSUE" -R "$GITHUB_REPOSITORY" --body "$BODY"
fi
