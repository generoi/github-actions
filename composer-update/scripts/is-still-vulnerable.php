<?php

/**
 * Check whether a version is still inside any of the package's
 * `affected` ranges from the parsed-vulns JSON.
 *
 * Prints exactly `yes` (still vulnerable — don't accept the update) or
 * `no` (safe — keep the lock change). Used by composer-update's
 * per-package loose retry after the patch-tight constraint fails to
 * resolve and we widen to a same-major range; without this check
 * composer could pick a version that's within the same-major bound but
 * still inside the affected range (rare in practice — composer audit's
 * advisory database usually blocks it — but we'd rather over-revert
 * than ship a "fix" that doesn't fix anything).
 *
 * Usage: php is-still-vulnerable.php <vulns.json> <package> <version>
 */

$autoload = getcwd() . '/vendor/autoload.php';
if (!file_exists($autoload)) {
    fwrite(STDERR, "vendor/autoload.php not found at {$autoload}\n");
    exit(2);
}
require $autoload;

use Composer\Semver\Semver;

if ($argc < 4) {
    fwrite(STDERR, "Usage: {$argv[0]} <vulns.json> <package> <version>\n");
    exit(2);
}

[$_, $vulnsPath, $pkg, $version] = $argv;

$vulns = json_decode(file_get_contents($vulnsPath), true);
if (!is_array($vulns)) {
    echo 'no';
    exit;
}

foreach ($vulns as $v) {
    if (($v['package'] ?? null) !== $pkg) {
        continue;
    }
    $affected = $v['affected'] ?? '';
    if ($affected === '') {
        continue;
    }
    foreach (explode('|', $affected) as $range) {
        try {
            if (Semver::satisfies($version, trim($range))) {
                echo 'yes';
                exit;
            }
        } catch (Throwable $e) {
            // Unparseable range — ignore and keep checking.
        }
    }
}

echo 'no';
