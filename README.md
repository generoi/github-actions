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

## Versioning

Projects pin to the major tag (`@v1`). Patch updates are automatic.

Dependabot monitors upstream action SHAs — merge its PRs to update all projects at once.
