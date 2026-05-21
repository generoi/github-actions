<?php

/**
 * Compute the minimum-safe composer constraint per vulnerable package.
 *
 * Reads a parsed-vulns JSON array (objects with at minimum {package, affected})
 * and the project's composer.lock; emits a JSON object mapping
 *   {package} => {tight ~constraint}
 * to stdout.
 *
 * Strategy: for each vuln, find the affected-range that contains the currently
 * locked version, then derive a `~X.Y.Z` constraint capping at the minor of
 * the smallest safe version. composer's tilde semantics (`~X.Y.Z` =
 * `>=X.Y.Z, <X.(Y+1)`) keep the bump within the same minor, preventing the
 * common over-bump where a CVE patched in 10.5.3 leaves composer free to
 * jump to 10.7.0 inside an existing `^10.x` constraint.
 *
 * Upper-bound parsing:
 *   <X.Y.Z   → ~X.Y.Z              (exclusive — the simple case)
 *   <=X.Y.Z  → ~X.Y.(Z+1)          (heuristic next-patch cap; if no such
 *                                    version is published the constraint
 *                                    fails to resolve and composer-update
 *                                    reports the package as untouched —
 *                                    preferable to over-bumping silently)
 *
 * Packages with no parseable upper bound get no entry and fall through to
 * unconstrained behavior in composer-update.
 *
 * Usage: php compute-min-safe-constraints.php <vulns.json> <composer.lock>
 */

// Locate composer/semver via the consumer project's vendor dir. This script
// runs from the action's path (which has no vendor/), so we look in the
// runner's CWD where the workflow has done `composer install`.
$autoload = getcwd() . '/vendor/autoload.php';
if (!file_exists($autoload)) {
    fwrite(STDERR, "vendor/autoload.php not found at {$autoload} — needs composer install first\n");
    exit(2);
}
require $autoload;

use Composer\Semver\Semver;

if ($argc < 3) {
    fwrite(STDERR, "Usage: {$argv[0]} <vulns.json> <composer.lock>\n");
    exit(2);
}

$vulnsPath = $argv[1];
$lockPath  = $argv[2];

$vulns = json_decode(file_get_contents($vulnsPath), true);
$lock  = json_decode(file_get_contents($lockPath), true);

if (!is_array($vulns) || !is_array($lock)) {
    fwrite(STDERR, "Bad input JSON\n");
    exit(2);
}

$locked = [];
foreach (array_merge($lock['packages'] ?? [], $lock['packages-dev'] ?? []) as $p) {
    $locked[$p['name']] = $p['version'];
}

$result = [];
foreach ($vulns as $v) {
    $pkg      = $v['package'] ?? null;
    $affected = $v['affected'] ?? '';
    if (!$pkg || $affected === '') {
        continue;
    }

    $current = $locked[$pkg] ?? null;
    if (!$current) {
        continue;
    }

    foreach (explode('|', $affected) as $range) {
        $range = trim($range);
        try {
            if (!Semver::satisfies($current, $range)) {
                continue;
            }
        } catch (Throwable $e) {
            continue;
        }

        // Exclusive upper bound: <X[.Y[.Z]]. Pad missing parts with 0 so
        // ~X.Y.Z always has a 3-component form (composer's `~X.Y` is a
        // major-cap, not a minor-cap).
        if (preg_match('/<\s*(\d+)(?:\.(\d+))?(?:\.(\d+))?\b/', $range, $m)) {
            // `??` doesn't fall back on empty-string captures from optional
            // groups — use `?:` so `<10.5` becomes `~10.5.0` not `~10.5.`.
            $major = $m[1];
            $minor = ($m[2] ?? '') !== '' ? $m[2] : '0';
            $patch = ($m[3] ?? '') !== '' ? $m[3] : '0';
            $result[$pkg] = "~$major.$minor.$patch";
            break;
        }

        // Inclusive upper bound: <=X[.Y[.Z]]. Bump the patch component to
        // get a heuristic "first safe" version. If no such version exists
        // on Packagist the tight constraint fails to resolve in
        // composer-update — which surfaces the package as untouched
        // instead of letting composer pick the latest minor.
        if (preg_match('/<=\s*(\d+)(?:\.(\d+))?(?:\.(\d+))?\b/', $range, $m)) {
            $major     = $m[1];
            $minor     = ($m[2] ?? '') !== '' ? $m[2] : '0';
            $patchNext = (int) (($m[3] ?? '') !== '' ? $m[3] : '0') + 1;
            $result[$pkg] = "~$major.$minor.$patchNext";
            break;
        }
    }
}

// Cast to object so an empty result encodes as `{}`, not `[]`. composer-update
// string-indexes this map with `jq '.[$pkg]'`, which errors on a JSON array —
// so an empty array would break the consumer under `set -eo pipefail`.
echo json_encode((object) $result, JSON_UNESCAPED_SLASHES);
