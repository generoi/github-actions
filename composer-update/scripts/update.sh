#!/usr/bin/env bash
# Update vulnerable Composer packages within constraints (composer update),
# then widen (composer require) for any not in extra.vuln-scan.no-widen.
# Extracted from action.yml (inline run blocks have a 21000-char compiled-
# expression cap). Inputs arrive via env: PACKAGES, VULNS_JSON; GitHub sets
# GITHUB_ACTION_PATH and GITHUB_OUTPUT. Mirrors the composite shell options.
set -eo pipefail

# Shared helper functions (build_pkg_arg, build_widen_arg, find_direct_ancestors,
# loosen_constraint, is_still_vulnerable, expand_args_for, get_lock_version).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Snapshot composer.lock to a tempfile BEFORE any composer ops run,
# so we have an untouched copy for the before/after version diff.
cp composer.lock /tmp/composer-update-before.lock

# Derive minimum-safe constraints from the optional vulns_json input.
# The PHP helper parses each vuln's `affected` range, finds the one
# that contains the currently-locked version, and emits a tight
# `~X.Y.Z` constraint capping at patch-level. Empty input → empty
# constraint map → unconstrained behavior throughout.
echo '{}' > /tmp/composer-update-constraints.json
if [ -n "${VULNS_JSON:-}" ]; then
  printf '%s' "$VULNS_JSON" > /tmp/composer-update-vulns.json
  if jq -e 'type == "array"' /tmp/composer-update-vulns.json >/dev/null 2>&1; then
    php "$GITHUB_ACTION_PATH/scripts/compute-min-safe-constraints.php" \
      /tmp/composer-update-vulns.json composer.lock \
      > /tmp/composer-update-constraints.json
    echo "Minimum-safe constraints:"
    jq . /tmp/composer-update-constraints.json
  else
    echo "::warning::vulns_json input is not a valid JSON array — falling back to unconstrained behavior"
  fi
fi


# Precompute the project's direct-dependency set + the lock's reverse-
# dependency map, used by:
#   - expand_args_for() below to include the direct-dep ancestor(s) of
#     each flagged transitive in the composer update call, so the
#     ancestor can move within its existing composer.json constraint
#   - the widen step (Step 2) below, to BFS from each unhandled
#     transitive up to a direct-dep ancestor it can widen
jq -r '((.require // {}) | keys) + ((.["require-dev"] // {}) | keys) | .[]' composer.json \
  | sort -u > /tmp/composer-update-direct.txt
jq -r '
  ((.packages // []) + (."packages-dev" // []))[] as $p |
  ($p.require // {} | keys[]) as $child |
  "\($child) \($p.name)"
' composer.lock > /tmp/composer-update-reverse.txt


# Step 1: Try composer update (stays within existing constraints).
# `-W` (--with-all-dependencies) lets composer also update packages that
# are LOCKED (not just those listed) when needed — required for cases
# like roots/wordpress-no-content, which is pinned to the same version
# as roots/wordpress; without -W neither can move.
# Composite actions run with `set -e`, so capture the exit code via
# `|| UPDATE_EXIT=$?` to keep the fallback alive on a non-zero exit.
declare -a BULK_ARGS=()
declare -A BULK_SEEN=()
for PACKAGE in $PACKAGES; do
  while IFS= read -r arg; do
    [ -z "$arg" ] && continue
    [ -n "${BULK_SEEN[$arg]:-}" ] && continue
    BULK_SEEN[$arg]=1
    BULK_ARGS+=("$arg")
  done < <(expand_args_for "$PACKAGE")
done
echo "Trying: composer update -W ${BULK_ARGS[*]}"
UPDATE_EXIT=0
composer update -W "${BULK_ARGS[@]}" --no-interaction --no-scripts 2>&1 || UPDATE_EXIT=$?
if [ "$UPDATE_EXIT" -ne 0 ]; then
  echo "::warning::bulk composer update exited with code $UPDATE_EXIT — will retry per package"
fi

# Per-package retry. `composer update -W <list>` is transactional —
# if even ONE listed package can't reach a satisfying version within
# constraints (e.g. faq-schema-block-to-accordion whose only fix is
# on dev-trunk, which we reject), composer rolls back the entire
# batch and leaves the lock untouched. That would punish packages
# like phpunit/phpunit whose fix IS available within their current
# constraint, by forcing them through the widening step. Loop
# per-package: for any package whose locked version didn't move,
# retry the update on just that one so a single unfixable package
# can't poison the rest.

UNHANDLED=""
for PACKAGE in $PACKAGES; do
  BEFORE_V=$(get_lock_version "$PACKAGE" /tmp/composer-update-before.lock)
  CURRENT_V=$(get_lock_version "$PACKAGE" composer.lock)
  if [ -n "$CURRENT_V" ] && [ "$BEFORE_V" != "$CURRENT_V" ]; then
    continue
  fi
  declare -a RETRY_ARGS=()
  while IFS= read -r arg; do
    [ -n "$arg" ] && RETRY_ARGS+=("$arg")
  done < <(expand_args_for "$PACKAGE")
  echo "  retrying per-package (tight): composer update -W ${RETRY_ARGS[*]}"
  composer update -W "${RETRY_ARGS[@]}" --no-interaction --no-scripts 2>&1 || true
  RETRY_V=$(get_lock_version "$PACKAGE" composer.lock)
  if [ -n "$RETRY_V" ] && [ "$BEFORE_V" != "$RETRY_V" ]; then
    continue
  fi

  # Tight retry produced no movement — either the constraint is
  # outside composer.json's range (genuine widen-needed case), or
  # the tight ~X.Y.Z range has no published version (e.g.
  # WP never tagged 6.6.4, only 6.7+). For the second case we
  # can still avoid widening composer.json by using a loose
  # constraint `>=X.Y.Z, <(X+1).0.0` which lets composer pick
  # the next safe version within the project's existing
  # constraint. The first case will also try this and still
  # fail — falling through to the widen step as before.
  TIGHT=$(jq -r --arg p "$PACKAGE" '.[$p] // ""' /tmp/composer-update-constraints.json)
  LOOSE=$(loosen_constraint "$TIGHT")
  if [ -n "$LOOSE" ]; then
    declare -a LOOSE_ARGS=("$PACKAGE:$LOOSE")
    if ! grep -qFx "$PACKAGE" /tmp/composer-update-direct.txt; then
      while IFS= read -r anc; do
        [ -n "$anc" ] && LOOSE_ARGS+=("$anc")
      done < <(find_direct_ancestors "$PACKAGE")
    fi

    # Snapshot composer.json + composer.lock so we can revert if
    # the loose retry moves the package to a still-vulnerable
    # version. (composer's own audit-blocking usually prevents
    # this, but we don't rely on it.)
    cp composer.json /tmp/composer-update-pre-loose.json
    cp composer.lock /tmp/composer-update-pre-loose.lock

    echo "  retrying per-package (loose): composer update -W ${LOOSE_ARGS[*]}"
    composer update -W "${LOOSE_ARGS[@]}" --no-interaction --no-scripts 2>&1 || true
    LOOSE_V=$(get_lock_version "$PACKAGE" composer.lock)
    if [ -n "$LOOSE_V" ] && [ "$BEFORE_V" != "$LOOSE_V" ]; then
      if [ "$(is_still_vulnerable "$PACKAGE" "$LOOSE_V")" = "no" ]; then
        echo "  loose retry succeeded: $PACKAGE $BEFORE_V → $LOOSE_V (out of affected range, composer.json untouched)"
        continue
      else
        echo "::warning::loose retry moved $PACKAGE to $LOOSE_V but it's still in the affected range — reverting"
        cp /tmp/composer-update-pre-loose.json composer.json
        cp /tmp/composer-update-pre-loose.lock composer.lock
      fi
    fi
  fi

  UNHANDLED="$UNHANDLED $PACKAGE"
done

if [ -z "$UNHANDLED" ]; then
  echo "Updated all packages within existing constraints"
  echo "changed=true" >> "$GITHUB_OUTPUT"
else
  echo "Packages still needing a constraint bump:$UNHANDLED"
  # Step 2: Constraints blocked the update — try composer require
  # (bumps to latest, REPLACING the existing constraint). Same `-W`
  # reasoning applies.
  #
  # Opt-out: packages listed under `extra.vuln-scan.no-widen` in the
  # project's composer.json are skipped here. Use this for packages
  # whose constraints are intentional (exact pin like "10.0.2", a
  # locked-down range like "^1.1" the team won't widen automatically,
  # license-tested version, etc.). The map's values are free-text
  # reasons — they're not parsed by this action, they exist purely
  # for in-place documentation of why each package opts out.
  #
  # Format (both shapes accepted):
  #   "extra": { "vuln-scan": { "no-widen": {
  #     "wpackagist-plugin/woocommerce": "License-tested only against 10.0.x"
  #   } } }
  # or:
  #   "extra": { "vuln-scan": { "no-widen": [
  #     "wpackagist-plugin/woocommerce"
  #   ] } }
  NO_WIDEN=$(jq -r '
    .extra["vuln-scan"]["no-widen"] // {} |
    if type == "array" then .[] else keys[] end
  ' composer.json 2>/dev/null | tr '\n' ' ')
  echo "No update within constraints, trying: composer require -W (filtered against extra.vuln-scan.no-widen)"

  # Expand the unhandled package list into the set of direct deps
  # we'll actually widen. Packages already moved by the per-package
  # update retry are NOT in $UNHANDLED, so they don't reach this
  # step and won't have their constraint widened unnecessarily.
  # Transitives get replaced by their direct-dep ancestor(s) via
  # find_direct_ancestors (defined at the top of this step);
  # multiple flagged packages converging on the same ancestor are
  # de-duped so we only widen each ancestor once.
  TARGETS=""
  for PACKAGE in $UNHANDLED; do
    if echo " $NO_WIDEN " | grep -qF " $PACKAGE "; then
      echo "  skip $PACKAGE — listed in extra.vuln-scan.no-widen"
      continue
    fi

    if grep -qFx "$PACKAGE" /tmp/composer-update-direct.txt; then
      TARGETS="$TARGETS $PACKAGE"
      continue
    fi

    ancestors=$(find_direct_ancestors "$PACKAGE" | tr '\n' ' ')
    if [ -z "${ancestors// /}" ]; then
      echo "::warning::no direct-dep ancestor found for transitive $PACKAGE — cannot widen"
      continue
    fi
    echo "  $PACKAGE is transitive — will widen ancestor(s): $ancestors"
    TARGETS="$TARGETS $ancestors"
  done

  # Dedupe. `|| true`: empty TARGETS (all unhandled are no-widen) makes
  # grep exit 1, which under `set -eo pipefail` would abort PR creation.
  TARGETS=$(echo "$TARGETS" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' || true)

  for PACKAGE in $TARGETS; do
    # Snapshot composer.json + composer.lock before each require so we
    # can roll back if composer resolves the package to a dev-* branch
    # constraint (e.g. dev-trunk). That happens on wpackagist plugins
    # when the project sets minimum-stability: dev and no released tag
    # outranks trunk — never a safe answer for a vuln scanner.
    cp composer.json /tmp/composer-update-pre-require.json
    cp composer.lock /tmp/composer-update-pre-require.lock

    # Preserve the require / require-dev placement. `composer require`
    # defaults to `require`; without `--dev` it will MOVE a package
    # that was originally in require-dev (e.g. phpunit/phpunit) into
    # require, which silently changes the prod dependency surface.
    REQUIRE_FLAGS="-W"
    if jq -e --arg p "$PACKAGE" '(.["require-dev"] // {})[$p]' composer.json >/dev/null; then
      REQUIRE_FLAGS="-W --dev"
    fi

    BEFORE_REQUIRE_V=$(get_lock_version "$PACKAGE" /tmp/composer-update-pre-require.lock)
    PKG_ARG=$(build_widen_arg "$PACKAGE")

    echo "  widening: composer require $REQUIRE_FLAGS $PKG_ARG"
    composer require $REQUIRE_FLAGS "$PKG_ARG" --no-interaction --no-scripts 2>&1 || true

    NEW_CONSTRAINT=$(jq -r --arg p "$PACKAGE" '(.require // {})[$p] // (.["require-dev"] // {})[$p] // ""' composer.json)
    AFTER_REQUIRE_V=$(get_lock_version "$PACKAGE" composer.lock)

    # Two reasons to throw out the require outcome and restore the
    # snapshot:
    #
    # 1. dev-* constraint — wpackagist plugins whose trunk readme
    #    declares a version higher than the latest stable tag can
    #    resolve to e.g. dev-trunk; never a safe answer for a vuln
    #    scanner.
    #
    # 2. Downgrade — `composer require -W <pkg>` with no constraint
    #    can pick a LOWER version than the one currently locked
    #    when audit.block-insecure blocks all sub-deps of newer
    #    versions (e.g. roots/wordpress 6.x metapackages all
    #    require roots/wordpress-no-content self.version, which is
    #    audit-blocked, so composer walks back to roots/wordpress
    #    5.9.3 which predates the metapackage split). A fix-by-
    #    downgrade is never the right answer; surface it as a
    #    triage signal instead.
    REVERT_REASON=""
    case "$NEW_CONSTRAINT" in
      dev-*)
        REVERT_REASON="resolved to dev branch constraint '$NEW_CONSTRAINT'"
        ;;
    esac
    if [ -z "$REVERT_REASON" ] && [ -n "$BEFORE_REQUIRE_V" ] && [ -n "$AFTER_REQUIRE_V" ] && [ "$BEFORE_REQUIRE_V" != "$AFTER_REQUIRE_V" ]; then
      LOWER=$(printf '%s\n%s\n' "$BEFORE_REQUIRE_V" "$AFTER_REQUIRE_V" | sort -V | head -1)
      if [ "$LOWER" = "$AFTER_REQUIRE_V" ]; then
        REVERT_REASON="downgrade $BEFORE_REQUIRE_V → $AFTER_REQUIRE_V (likely blocked by audit advisory on a sub-dep)"
      fi
    fi

    if [ -n "$REVERT_REASON" ]; then
      echo "::warning::composer require on $PACKAGE — reverting: $REVERT_REASON"
      cp /tmp/composer-update-pre-require.json composer.json
      cp /tmp/composer-update-pre-require.lock composer.lock
    fi
  done

  if git diff --quiet composer.json composer.lock; then
    echo "No updates available"
    echo "changed=false" >> "$GITHUB_OUTPUT"
    exit 0
  fi
  echo "Updated with constraint bump"
  echo "changed=true" >> "$GITHUB_OUTPUT"
fi

# Build a version-diff table from the before tempfile (saved above)
# vs the post-update composer.lock.
# from_entries requires {key, value} — it silently drops other field
# names like `version`, producing a map of {pkg: null} regardless of
# actual version. Map to {key, value} explicitly.
JQ_VERSIONS='[(.packages + ."packages-dev")[] | {key: .name, value: .version}] | from_entries'
jq "$JQ_VERSIONS" /tmp/composer-update-before.lock > /tmp/composer-update-before.json
jq "$JQ_VERSIONS" composer.lock > /tmp/composer-update-after.json

echo "Before snapshot: $(jq 'length' /tmp/composer-update-before.json) packages"
echo "After snapshot:  $(jq 'length' /tmp/composer-update-after.json) packages"

# Count packages with actual version changes (or added/removed).
# If zero, the composer.lock diff is metadata-only (refreshed dist
# references, content-hash) and doesn't actually fix any vulnerability
# — skip PR creation rather than opening noise.
VERSION_DIFF_COUNT=$(jq -r --slurpfile after /tmp/composer-update-after.json '
  ([to_entries[]
    | ($after[0][.key] // null) as $n
    | select($n != null and $n != .value)
  ] | length)
  + ([$after[0] | keys[]] - [keys[]] | length)
  + ([keys[]] - [$after[0] | keys[]] | length)
' /tmp/composer-update-before.json)

echo "Version changes detected: $VERSION_DIFF_COUNT"

# (A) Final safety net: never present a package as fixed if its resulting
# locked version is STILL inside the advisory's affected range. Catches a wrong
# min-safe constraint (see the `<=` 4-segment-hotfix bug) that composer's own
# audit-blocking didn't stop. Runs on every outcome — including the no-move case
# below — so open-or-refresh-pr.sh can surface unfixed packages in the PR body.
# is_still_vulnerable returns "no" when no vulns_json was supplied, so plain
# dependency-update runs are unaffected.
: > /tmp/composer-update-still-vulnerable.txt
for PACKAGE in $PACKAGES; do
  FINAL_V=$(get_lock_version "$PACKAGE" composer.lock)
  if [ "$(is_still_vulnerable "$PACKAGE" "$FINAL_V")" = "yes" ]; then
    echo "::warning::$PACKAGE is still in its advisory's affected range (now ${FINAL_V:-<unchanged>}) — not a real fix, needs manual triage"
    printf '%s\t%s\n' "$PACKAGE" "$FINAL_V" >> /tmp/composer-update-still-vulnerable.txt
  fi
done

if [ "$VERSION_DIFF_COUNT" -eq 0 ]; then
  echo "composer.lock changed but no package versions moved — skipping PR"
  echo "changed=false" >> "$GITHUB_OUTPUT"
  # Reset lock to avoid leaving metadata-only changes staged
  git checkout -- composer.json composer.lock 2>/dev/null || true
  exit 0
fi

# (E) Don't ship a lockfile that doesn't validate. A bad require/widen can leave
# composer.json inconsistent or out of sync with the lock; reject and revert
# rather than open a PR that breaks `composer install` on deploy.
if ! composer validate --no-check-all --no-check-publish --quiet >/tmp/composer-update-validate.log 2>&1; then
  echo "::error::composer validate failed after update — reverting, no PR"
  cat /tmp/composer-update-validate.log || true
  git checkout -- composer.json composer.lock 2>/dev/null || true
  echo "changed=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

{
  echo ""
  echo "## Version changes"
  echo ""
  echo "| Package | From | To |"
  echo "|---|---|---|"
  jq -r --slurpfile after /tmp/composer-update-after.json '
    to_entries[] as $b
    | ($after[0][$b.key] // null) as $n
    | select($n != null and $n != $b.value)
    | "| `\($b.key)` | `\($b.value)` | `\($n)` |"
  ' /tmp/composer-update-before.json | sort
  # New packages (present in after but not before)
  jq -r --slurpfile after /tmp/composer-update-after.json '
    [$after[0] | keys[]] - [keys[]] | .[]
  ' /tmp/composer-update-before.json | while read -r pkg; do
    [ -z "$pkg" ] && continue
    v=$(jq -r --arg k "$pkg" '.[$k]' /tmp/composer-update-after.json)
    echo "| \`$pkg\` | _(new)_ | \`$v\` |"
  done
  # Removed packages (present in before but not after)
  jq -r --slurpfile after /tmp/composer-update-after.json '
    [keys[]] - [$after[0] | keys[]] | .[]
  ' /tmp/composer-update-before.json | while read -r pkg; do
    [ -z "$pkg" ] && continue
    v=$(jq -r --arg k "$pkg" '.[$k]' /tmp/composer-update-before.json)
    echo "| \`$pkg\` | \`$v\` | _(removed)_ |"
  done
} > /tmp/composer-update-versions.md

echo "Version changes table:"
cat /tmp/composer-update-versions.md

