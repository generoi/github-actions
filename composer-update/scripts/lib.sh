#!/usr/bin/env bash
#
# Helper functions for composer-update/scripts/update.sh.
#
# Sourced by update.sh (and by the unit tests under ../tests). These functions
# are pure-ish: they take args and read a few tempfiles that update.sh writes
# before calling them:
#   /tmp/composer-update-constraints.json  (build_pkg_arg, build_widen_arg)
#   /tmp/composer-update-direct.txt         (find_direct_ancestors, expand_args_for)
#   /tmp/composer-update-reverse.txt        (find_direct_ancestors)
#   /tmp/composer-update-vulns.json         (is_still_vulnerable)
# and $GITHUB_ACTION_PATH for the PHP helpers.

# Build the composer arg for a single package: just the name if no
# constraint is configured for it, or `name:constraint` (e.g.
# `vendor/pkg:~1.2.3`) when the caller supplied a tight bound.
# Tilde at offset >0 inside a single word isn't subject to shell
# tilde expansion, so the colon-form is safe to interpolate.
# Trailing newline matters: expand_args_for() concatenates this
# with find_direct_ancestors() and pipes the result to `while read`;
# without it, a direct-dep package produces an unterminated line
# that `read` discards and the arg ends up empty. (#27)
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
# widening, as before. (#29)
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

# Find direct-dep ancestor(s) of a package by BFS through the reverse
# map. Returns one ancestor per line. If the package is itself a
# direct dep, returns just that name. (#22, #26)
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
# than falling through to widening. (#28)
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
# that doesn't fix anything. (#28)
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
# movement within their existing composer.json constraint. (#26)
expand_args_for() {
  local pkg="$1"
  build_pkg_arg "$pkg"
  if ! grep -qFx "$pkg" /tmp/composer-update-direct.txt; then
    find_direct_ancestors "$pkg"
  fi
}

# Read a package's locked version from a given composer.lock file.
get_lock_version() {
  jq -r --arg p "$1" '
    ((.packages // []) + (."packages-dev" // []))
    | map(select(.name == $p)) | first | .version // empty
  ' "$2"
}
