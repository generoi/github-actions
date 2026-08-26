# Genero GitHub Actions

Shared composite actions and reusable workflows for Genero's Bedrock/Sage WordPress projects.

## Setup

This is a **private** repository. To allow other repos in the org to use these actions:

1. Go to **Settings → Actions → General** on this repo
2. Under "Access", select **"Accessible from repositories in the 'generoi' organization"**

## Composite Actions

| Action | Description |
|--------|-------------|
| `setup` | PHP + Node.js setup with caching, Fontawesome and Packagist auth |
| `install-wordpress` | MySQL + WP dev server install (single or multisite) |
| `setup-ddev` | DDEV setup (pinned SHA) |
| `ssh-agent` | SSH agent wrapper (pinned SHA) |

### Usage

```yaml
- uses: generoi/github-actions/setup@v1
  with:
    npm_fontawesome_auth_token: ${{ secrets.NPM_FONTAWESOME_AUTH_TOKEN }}
    packagist_github_token: ${{ secrets.PACKAGIST_GITHUB_TOKEN }}

- uses: generoi/github-actions/install-wordpress@v1
  with:
    multisite: 'true'
```

## Reusable Workflows

| Workflow | Description |
|----------|-------------|
| `test.yml` | Lint + install WP + smoke test + phpunit |
| `deploy.yml` | SSH + build + test + deployer |
| `e2e.yml` | Playwright E2E tests against a URL |
| `vulnerability-scan.yml` | WP vuln scan + Google Chat notification |
| `plugin-changelog.yml` | Comment wp.org changelogs for changed `wp-plugin/*` |

### Usage

```yaml
jobs:
  test:
    uses: generoi/github-actions/.github/workflows/test.yml@v1
    secrets: inherit
    with:
      multisite: true
      smoke_grep: 'app/themes/gds/public/scripts/app.js'
```

### Changelogs for `wp-plugin/*`

Dependabot renders release notes for every github-sourced package and nothing at
all for `wp-plugin/*`: WP Packages publishes the wp.org SVN tag as the package
source, and Dependabot only resolves git sources — then falls back to a metadata
lookup hardcoded to `repo.packagist.org`, where those packages do not exist. No
`dependabot.yml` setting changes either half.

`plugin-changelog.yml` fills the gap from `api.wordpress.org` instead. The caller
owns the trigger and the token, because a reusable workflow can only narrow the
caller's permissions, never widen them:

```yaml
on:
  pull_request:
    paths:
      - composer.lock

permissions:
  contents: read
  pull-requests: write

jobs:
  changelog:
    uses: generoi/github-actions/.github/workflows/plugin-changelog.yml@v2
```

Dependabot's `pull_request` events get a read-only token *by default*, but an
explicit `permissions:` block still elevates it — so this needs no
`pull_request_target`, and should not use one. Drop `contents: read` and the
comment still posts, from a diff-hunk fallback that quietly misses plugins.

### Scheduling the nightly scan

`vulnerability-scan.yml` does not sleep to spread load — runner time is billed,
so the stagger belongs in the cron expression, which is free. **Give each repo
its own minute** (and ideally its own hour) rather than copying `5 4 * * *`:

```yaml
on:
  schedule:
    - cron: '17 3 * * *' # unique per repo
```

Sharing one minute across repos means every scan hits the advisory and GitHub
APIs simultaneously, and GitHub also delays runs scheduled on popular minutes.

### Which repos the cron actually scans

The scheduled scan is gated on the repo's `maintenance` organization custom
property. It runs only for `monthly`, `bi-monthly`, `quarterly` and
`critical-only`; `hosted-only`, `none` and an **unset** property skip the run.

That means adding the workflow to a repo is not enough — the repo also needs a
`maintenance` value, or its nightly scan silently no-ops:

```sh
gh api repos/generoi/<repo>/properties/values \
  --jq '.[] | select(.property_name == "maintenance") | .value'
```

Two deliberate escape hatches:

- A manual `workflow_dispatch` **always** scans, whatever the tier.
- If the property API call fails, the scan runs anyway. An untagged repo is a
  visible state someone can fix; a transient 5xx is not, and it must never
  silently skip a security scan.

## Versioning

Projects pin to the major tag (`@v1`). Patch updates are automatic.

Dependabot monitors upstream action SHAs — merge its PRs to update all projects at once.
