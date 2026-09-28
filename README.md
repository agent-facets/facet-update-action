# Facet Update Action

Keep a repository's declared facets current. The action runs on a schedule, opens one pull request for the update, and never merges it.

## Quickstart

Add `.github/workflows/facet-update.yml`:

```yaml
name: Facet update

on:
  schedule:
    - cron: '0 6 * * 1' # 06:00 UTC every Monday
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

# Queue runs for this repository's facet-updates branch. Let a run finish once
# it has started preparing the branch.
concurrency:
  group: facet-update-${{ github.repository }}-facet-updates
  cancel-in-progress: false

jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: agent-facets/facet-update-action@v1
        with:
          cli-version: '0.33.1'
          adapter: codex@0.9.0
```

Both permissions are required; see [Permissions](#permissions). `workflow_dispatch` lets you test the action without waiting for the schedule.

## Requirements

Commit and track `facets.lock` alongside `facets.json`. The action rejects a missing, ignored, or untracked lockfile: a clean working tree alone is not evidence that the lockfile records the proposed versions.

The standard workflow assumes a GitHub-hosted Ubuntu runner with Bash, Git, Node/npm (`npx`), and the GitHub CLI available. It also needs outbound network access to GitHub (checkout, push, and pull-request API calls) and the npm registry (the pinned CLI and adapter installs). GitHub publishes the current hosted-runner tool inventory in [actions/runner-images](https://github.com/actions/runner-images); self-hosted runners must provide equivalent tools and network access.

## Choosing a schedule

`cron` uses five fields in UTC. GitHub runs scheduled workflows from the default branch and may delay a run when runners are busy; see the [scheduled events documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule).

| When | `cron` |
| --- | --- |
| Every Monday, 06:00 | `0 6 * * 1` |
| Every day, 03:00 | `0 3 * * *` |
| First of the month | `0 6 1 * *` |

`strategy: latest` (the default) proposes each facet's newest release, including exactly pinned entries. `strategy: in-range` honors the existing `facets.json` range; an exactly pinned entry therefore never moves.

## Inputs

| Input | Default | What it does |
| --- | --- | --- |
| `strategy` | `latest` | `latest` or `in-range`. |
| `cli-version` | `0.33.1` | Version of the `agent-facets` CLI to run. Pin it deliberately; see [Supply chain](#supply-chain). |
| `adapter` | required | First-party materialization adapter as an exact `claude-code@M.N.P`, `opencode@M.N.P`, or `codex@M.N.P` release. |
| `working-directory` | `.` | Directory holding `facets.json`. |
| `dry-run` | `false` | Reports the action's dry-run result and makes no GitHub mutations; adapter setup can still install runner-local code. |
| `open-pr` | `true` | Opens or refreshes a pull request when facets change. |
| `branch` | `facet-updates` | Destination update branch. It cannot be the base or default branch. |
| `base` | repo default | Branch the pull request targets. |
| `commit-message` | `chore(facets): update facets` | First line of the generated commit. |
| `pr-title` | `chore(facets): update facets` | Pull request title. |
| `pr-author` | `github-actions[bot]` | Login the action requires for generated pull requests. |
| `labels` | none | Comma-separated labels; a label failure is logged and nonfatal. |
| `token` | `github.token` | Token for pull-request API calls; it does not change checkout's push credential. |

## Outputs

| Output | What it is |
| --- | --- |
| `updated` | `"true"` only when a non-dry-run update changed at least one facet; dry runs always report `"false"`. |
| `count` | Number of changed facet entries: upgrades, downgrades, additions, and removals. The action's dry-run report is the shared zero-change result below, not a proposed-change count. |
| `pr-url` | URL of the pull request opened or refreshed, empty when none was. |

For no-change and dry-run, the final console result line is followed here by the three exact machine-output file lines. The CLI may print diagnostics before the result line:

```text
facet-update: updated=false count=0
updated=false
count=0
summary=
```

## Update branch

The action owns `branch` and uses an explicit `--force-with-lease` against the fetched tip. If another concurrent run changes that tip, the losing run refuses to push; it does not overwrite the winner. If the existing tip was not made by `github-actions[bot]`, it also refuses to replace it. These are structural provenance checks for a trusted repository, not cryptographic proof of who authored a commit and not a security boundary against a repository attacker.

Reserve the branch for this action. If you change `branch`, change the last segment of `concurrency.group` to the same literal. That keeps runs for the branch in one queue. GitHub documents [concurrency groups](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).

```yaml
concurrency:
  group: facet-update-${{ github.repository }}-weekly-facet-updates
  cancel-in-progress: false
jobs:
  update:
    steps:
      - uses: agent-facets/facet-update-action@v1
        with:
          branch: weekly-facet-updates
          cli-version: '0.33.1'
          adapter: codex@0.9.0
```

A closed historical pull request is not reused: the next update creates a new PR. One matching open PR is refreshed as the branch advances. `open-pr: false` can create an absent update branch, but it cannot refresh an existing update branch; use `open-pr: true` for recurring updates.

## Permissions

The job needs `contents: write` to push and `pull-requests: write` to create or refresh the pull request. GitHub documents [setting `GITHUB_TOKEN` permissions](https://docs.github.com/en/actions/security-for-github-actions/security-guides/automatic-token-authentication#permissions-for-the-github_token). Repository or organization Actions settings must also enable [Allow GitHub Actions to create and approve pull requests](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository#preventing-github-actions-from-creating-or-approving-pull-requests).

`pr-author` is an assertion, not a way to choose an identity: the created or refreshed PR must be owned by that login (default `github-actions[bot]`) or the action fails. The default `GITHUB_TOKEN` creates PR events in GitHub's approval-required workflow state, so downstream checks do not begin automatically. An App installation token or PAT can create events that start checks automatically, subject to your repository settings.

`token` is used for the pull-request API only. To use a custom App token or PAT consistently, give the same credential to both checkout and this action:

```yaml
- uses: actions/checkout@v7
  with:
    token: ${{ secrets.FACET_UPDATE_TOKEN }}
- uses: agent-facets/facet-update-action@v1
  with:
    token: ${{ secrets.FACET_UPDATE_TOKEN }}
    pr-author: my-update-app[bot]
    cli-version: '0.33.1'
    adapter: codex@0.9.0
```

GitHub's [workflow-trigger documentation](https://docs.github.com/en/actions/how-tos/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow) describes the special behavior of events created with `GITHUB_TOKEN`.

## Pinning

Use the reference that matches your change-control policy:

| Reference | Trade-off |
| --- | --- |
| Full commit SHA | Strongest action pin: it stays on the reviewed commit until you edit the workflow. |
| `v1.0.0` | An immutable release tag gives a reviewed patch release without following later releases. |
| `v1` | Convenient major-line tag; it can move to compatible releases and therefore depends on the repository's immutable-release policy. |

GitHub recommends pinning third-party actions to a full commit SHA in its [security hardening guidance](https://docs.github.com/en/actions/how-tos/security-for-github-actions/security-guides/security-hardening-your-deployments#using-third-party-actions). GitHub's [immutable release documentation](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository/managing-immutable-releases) explains the release-policy trade-off.

## Supply chain

Pin the action and both executable packages separately: use an action SHA when your policy requires the strongest pin, set `cli-version: '0.33.1'` for the CLI, and set `adapter: codex@0.9.0` (or an exact version of another supported first-party adapter) for materialization. The action uses that CLI version to install the selected adapter before updating facets. Both npm packages and their install scripts execute with the job's credentials, including during a dry run. Keep the action in a dedicated job and expose only the secrets it needs.

Only use this action from `schedule` or `workflow_dispatch`; do not run it from `pull_request_target`, where untrusted repository content could influence a privileged job.

## Using it without GitHub Actions

[`scripts/facet-update.sh`](scripts/facet-update.sh) runs the CLI and reports what moved without GitHub API calls. It reads `FACET_STRATEGY`, `FACET_CLI_VERSION`, `FACET_WORKING_DIR`, `FACET_DRY_RUN`, and `FACET_OUTPUT` from the environment.

## License

MIT
