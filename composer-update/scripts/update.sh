#!/usr/bin/env bash
# Update vulnerable Composer packages within constraints (composer update),
# then widen (composer require) for any not in extra.vuln-scan.no-widen.
# Extracted from action.yml (inline run blocks have a 21000-char compiled-
# expression cap). Inputs arrive via env: PACKAGES, VULNS_JSON; GitHub sets
# GITHUB_ACTION_PATH and GITHUB_OUTPUT. Mirrors the composite shell options.
set -eo pipefail

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

# Build the composer arg for a single package: just the name if no
# constraint is configured for it, or `name:constraint` (e.g.
# `vendor/pkg:~1.2.3`) when the caller supplied a tight bound.
# Tilde at offset >0 inside a single word isn't subject to shell
# tilde expansion, so the colon-form is safe to interpolate.
# Trailing newline matters: expand_args_for() concatenates this
# with find_direct_ancestors() and pipes the result to `while read`;
# without it, a direct-dep package produces an unterminated line
# that `read` discards and the arg ends up empty.
build_pkg_arg() {
  local pkg="$1"
  local c
  c=$(jq -r --arg p "$pkg" '.[$p] // ""' /tmp/composer-update-constraints.json)
  if [ -n "$c" ]; then
    printf '%s:%s\n' "$pkg" "$c"
  else
    printf '%s\n' "$pkg"
  fi
}

# Build the composer arg for the WIDEN step (composer require), which
# REPLACES the project's constraint rather than tightening within it.
# Here the package gets a caret `^min_safe` (e.g. `^27.1.2` =
# `>=27.1.2,<28.0.0`) instead of the patch-pinned tight `~min_safe`.
# Why: `composer require` is reached only when the in-constraint
# update already failed — i.e. the fix lives OUTSIDE composer.json's
# current constraint (e.g. project pins `^26.0` but the patched
# release is 27.x). A tight `~27.1.2` would (a) pin to a single patch
# line that often doesn't exist (Yoast went 27.1.1 → 27.2, no 27.1.2)
# and (b) defeat the whole point of widening. The caret spans the
# safe-version's whole major, so composer can land on the real fix
# (27.6) while still not crossing into the next major. Packages with
# no min_safe (no vulns_json) fall back to a bare name — unconstrained
# widening, as before.
build_widen_arg() {
  local pkg="$1"
  local c
  c=$(jq -r --arg p "$pkg" '.[$p] // ""' /tmp/composer-update-constraints.json)
  if [[ "$c" =~ ^~([0-9.]+)$ ]]; then
    printf '%s:^%s' "$pkg" "${BASH_REMATCH[1]}"
  else
    printf '%s' "$pkg"
  fi
}

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

# Find direct-dep ancestor(s) of a package by BFS through the reverse
# map. Returns one ancestor per line. If the package is itself a
# direct dep, returns just that name.
find_direct_ancestors() {
  local target="$1"
  local seen="|"
  local queue="$target"
  local result=""
  while [ -n "$queue" ]; do
    local current
    current=$(echo "$queue" | head -1)
    queue=$(echo "$queue" | tail -n +2)
    case "$seen" in *"|$current|"*) continue ;; esac
    seen="$seen$current|"
    if grep -qFx "$current" /tmp/composer-update-direct.txt; then
      result="$result $current"
      continue
    fi
    local parents
    parents=$(awk -v t="$current" '$1 == t {print $2}' /tmp/composer-update-reverse.txt)
    if [ -n "$parents" ]; then
      queue=$(printf '%s\n%s' "$queue" "$parents")
    fi
  done
  echo "$result" | tr ' ' '\n' | grep -v '^$' | sort -u || true
}

# Derive a "same-major, not-affected" loose constraint from the tight
# `~X.Y.Z` form: `>=X.Y.Z, <(X+1).0.0`. Used as a fallback when the
# tight retry matches no published version (e.g. CVE upper bound
# `<=6.6.3` heuristic'd to `~6.6.4`, but WordPress never tagged
# 6.6.4 — the next release is 6.7.0). Lets composer pick the next
# safe version within composer.json's existing constraint rather
# than falling through to widening.
loosen_constraint() {
  local tight="$1"
  if [[ "$tight" =~ ^~([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    local patch="${BASH_REMATCH[3]}"
    printf '>=%s.%s.%s,<%s.0.0' "$major" "$minor" "$patch" "$((major + 1))"
  fi
}

# Safety net for the loose retry: confirm the package's new locked
# version is OUT of every range in its `affected` field before
# accepting the update. composer audit's advisory database normally
# blocks vulnerable versions, but `audit.block-insecure` defaults
# vary by project and we'd rather over-revert than ship a "fix"
# that doesn't fix anything.
is_still_vulnerable() {
  local pkg="$1"
  local version="$2"
  if [ ! -s /tmp/composer-update-vulns.json ] || [ -z "$version" ]; then
    echo no
    return
  fi
  php "$GITHUB_ACTION_PATH/scripts/is-still-vulnerable.php" \
    /tmp/composer-update-vulns.json "$pkg" "$version"
}

# Expand a single flagged package into the args we pass to composer:
# `name[:constraint]` for the package itself, plus the names of its
# direct-dep ancestor(s) when the flagged package is a transitive.
#
# Why: `composer update -W X` updates X and X's dependencies (downward),
# but NOT X's reverse-deps. For metapackages like roots/wordpress that
# pin roots/wordpress-no-content at self.version, the parent is locked
# at the same version as the transitive and won't move unless we list
# it explicitly. Without this expansion, updating wordpress-no-content
# within a tight ~constraint fails with "roots/wordpress is locked and
# not requested" and falls through to widening — which then rewrites
# composer.json unnecessarily.
#
# Ancestors get no constraint suffix: we only want them eligible for
# movement within their existing composer.json constraint.
expand_args_for() {
  local pkg="$1"
  build_pkg_arg "$pkg"
  if ! grep -qFx "$pkg" /tmp/composer-update-direct.txt; then
    find_direct_ancestors "$pkg"
  fi
}

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
get_lock_version() {
  jq -r --arg p "$1" '
    ((.packages // []) + (."packages-dev" // []))
    | map(select(.name == $p)) | first | .version // empty
  ' "$2"
}

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

if [ "$VERSION_DIFF_COUNT" -eq 0 ]; then
  echo "composer.lock changed but no package versions moved — skipping PR"
  echo "changed=false" >> "$GITHUB_OUTPUT"
  # Reset lock to avoid leaving metadata-only changes staged
  git checkout -- composer.json composer.lock 2>/dev/null || true
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

