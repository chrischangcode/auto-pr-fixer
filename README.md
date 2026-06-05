# auto-pr-fixer

A GitHub Action that automatically detects CI build failures on pull requests and uses GitHub Copilot CLI to suggest (or commit) fixes.

## How it works

1. Triggers on `workflow_run` completed events (when a CI workflow fails)
2. Reads config from `.github/auto-pr-fixer.yml` on the **default branch** (not the PR branch, for security)
3. Finds open PRs matching the failed workflow's branch
4. Fetches the failed job logs, extracts error context, and redacts secrets
5. Invokes `gh copilot` to suggest a fix
6. Posts a comment on the PR with the suggestion (or commits the fix directly, if configured)

## Quick start

### 1. Add the workflow to your repo

Create `.github/workflows/auto-pr-fixer.yml`:

```yaml
name: Auto PR Fixer

on:
  workflow_run:
    workflows: ["CI"]     # name of your CI workflow
    types: [completed]

permissions:
  actions: read
  checks: read
  contents: write
  pull-requests: write
  issues: write

jobs:
  fix:
    if: github.event.workflow_run.conclusion == 'failure'
    runs-on: ubuntu-latest
    steps:
      - uses: chrischangcode/auto-pr-fixer@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

### 2. Add a config file (optional)

Create `.github/auto-pr-fixer.yml` in your repo:

```yaml
# "comment" = post a suggestion (default, safe)
# "commit"  = push a fix directly to the PR branch
mode: comment

maxRetries: 2

# Only run on PRs with this label (remove to run on all PRs)
requireLabel: auto-fix

# Which CI workflows to watch
workflows:
  - CI

# Skip these branches
branches:
  exclude:
    - main
    - release/**

# Skip bot authors
authors:
  exclude:
    - dependabot[bot]
    - renovate[bot]

# Don't touch these files
protectedPaths:
  - ".github/workflows/**"
  - "**/*.lock"
```

See [`example-config.yml`](./example-config.yml) for the full config reference.

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `github-token` | GitHub token with write access | `${{ github.token }}` |
| `config-path` | Path to config file | `.github/auto-pr-fixer.yml` |
| `dry-run` | Force comment-only mode | `false` |

## Security

- Config is **always loaded from the default branch**, never from the PR — so PR authors can't change the action's behavior
- Fork PRs are **skipped by default** (configurable)
- Secrets in build logs are **redacted** before being sent to the model
- Protected paths (workflow files, lockfiles) **cannot be modified** by the fixer
- Retry state prevents **infinite fix loops**
- Head SHA is verified before committing to prevent **race conditions**

## Requirements

- `gh` CLI with the Copilot extension installed on the runner
- `jq` (pre-installed on GitHub-hosted runners)
- `python3` with `pyyaml` for config parsing (pre-installed on GitHub-hosted runners)

## License

MIT
