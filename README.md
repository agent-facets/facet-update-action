# Facet Update Action

Keep the facets a repository declares up to date, on a schedule, and open a pull
request when any of them move — the way Dependabot does it for packages.

The action runs `facet update`, works out which facets changed version, and
opens (or refreshes) a single pull request describing what moved. Nothing is
ever merged for you.

## Quickstart

Add `.github/workflows/facet-update.yml`:

```yaml
name: Facet update

on:
  schedule:
    - cron: '0 6 * * 1' # 06:00 UTC every Monday
  workflow_dispatch: # lets you run it by hand from the Actions tab

permissions:
  contents: write
  pull-requests: write

concurrency:
  group: facet-update-${{ github.ref }}

jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: agent-facets/facet-update-action@main
```

Both `permissions:` lines are required — see [Permissions](#permissions).
`workflow_dispatch` is worth keeping: it is how you test this without waiting a
week.

### Pinning

`@main` tracks this repository's default branch. To pin, use a commit SHA:

```yaml
- uses: agent-facets/facet-update-action@<full-40-char-sha>
```

## Requirements

`facets.lock` must be committed. `facet update` refuses to run when a facet in
`facets.json` has no lockfile entry, so run `facet install` and commit both
files before scheduling updates. If `facets.lock` is gitignored the action will
tell you and stop, because an update it cannot commit is not reviewable.

## Choosing a schedule

`cron` is standard five-field UTC cron:

| When | `cron` |
| --- | --- |
| Every Monday, 06:00 | `0 6 * * 1` |
| Every day, 03:00 | `0 3 * * *` |
| First of the month | `0 6 1 * *` |

GitHub runs scheduled workflows on the default branch only, and may delay them
when the runner fleet is busy.

## How far it moves your facets

This is the one setting worth understanding, because the two options fail in
opposite directions.

**`strategy: latest`** (the default) moves every facet to its newest release,
rewriting pinned entries in `facets.json`. You get a pull request whenever
anything is behind.

The catch: it ignores the range you wrote. If `facets.json` says `"2.*"`
because you meant to stay on the 2.x line, this will propose 3.x anyway. It is
a proposal — close the pull request and nothing happens — but it will keep
proposing it.

**`strategy: in-range`** only moves a facet when the new release satisfies the
range already in `facets.json`.

The catch: an exactly-pinned entry like `"1.2.1"` is a range that permits only
`1.2.1`, so it never moves. A repository that pins everything exactly gets a
scheduled job that runs forever and opens nothing. The CLI does say
`Newer releases exist, but the ranges in facets.json permit none of them`, but
that goes into a log nobody reads.

Pick `latest` if you want to hear about new releases. Pick `in-range` if your
ranges are deliberate and you would rather be told nothing than told wrong.

```yaml
- uses: agent-facets/facet-update-action@main
  with:
    strategy: in-range
```

## Inputs

| Input | Default | What it does |
| --- | --- | --- |
| `strategy` | `latest` | `latest` or `in-range` — see above. |
| `cli-version` | `latest` | Version of the `agent-facets` CLI to run. See [Supply chain](#supply-chain). |
| `working-directory` | `.` | Directory holding `facets.json`. |
| `dry-run` | `false` | Report what would change and stop. Nothing is committed, pushed, or opened. |
| `open-pr` | `true` | Set `false` to push the branch and stop there. |
| `branch` | `facet-updates` | Branch the update is pushed to; reused across runs. Cannot equal the base branch. |
| `base` | repo default | Branch the pull request targets. |
| `commit-message` | `chore(facets): update facets` | First line of the commit. |
| `pr-title` | `chore(facets): update facets` | Pull request title. |
| `labels` | none | Comma-separated. A label that cannot be applied is logged and skipped, never fatal. |
| `token` | `github.token` | Used for the pull request API calls only — **not** for the push. See [Permissions](#permissions). |

## Outputs

| Output | What it is |
| --- | --- |
| `updated` | `"true"` when at least one facet changed version. |
| `count` | How many facets changed version. |
| `pr-url` | URL of the pull request, empty when none was opened. |

## Permissions

The job needs `contents: write` to push the branch and `pull-requests: write`
to open the pull request. Omitting the second one is the common mistake: the
push succeeds, then the pull request step fails with GitHub's opaque
`Resource not accessible by integration`. The action catches that and names the
missing permission, but it is easier to just set both.

**The `token` input does not authenticate the push.** It is passed to `gh` for
the pull request API calls. `git push` uses whatever credential
`actions/checkout` persisted. To push as a different identity, give that token
to `actions/checkout` too:

```yaml
- uses: actions/checkout@v4
  with:
    token: ${{ secrets.MY_PAT }}
- uses: agent-facets/facet-update-action@main
  with:
    token: ${{ secrets.MY_PAT }}
```

That also matters because pull requests opened with the default `GITHUB_TOKEN`
do not trigger other workflows. If your checks must run on this pull request,
both steps need a personal access token or GitHub App token.

## Supply chain

`cli-version` defaults to `latest`, so each run executes whatever the npm
registry currently serves for `agent-facets`, with the runner's privileges. The
package's install scripts run — they have to, since the CLI builds a local
binary link on install.

For production, pin an exact version you have reviewed and bump it
deliberately:

```yaml
with:
  cli-version: '0.33.1'
```

Run this action in a job of its own. Step environments in a composite action
are additive to the job's, so any secret your job exposes is visible to the
CLI process it runs.

Only wire this to `schedule` and `workflow_dispatch`. Never run it from
`pull_request_target`, where a fork's `facets.json` would decide what gets
fetched and executed in a job holding a privileged token.

## Using it without GitHub Actions

The part that decides *what changed* is deliberately separate from the part
that opens a pull request. [`scripts/facet-update.sh`](scripts/facet-update.sh)
runs the CLI and reports what moved, and knows nothing about GitHub:

```bash
FACET_STRATEGY=latest \
FACET_OUTPUT=result.txt \
  ./scripts/facet-update.sh

# result.txt contains:
#   updated=true
#   count=1
#   summary=<base64 markdown table>
```

Porting this to GitLab CI or Buildkite means calling that script from a
scheduled job and opening a merge request however that platform does it — the
detection logic comes along unchanged. The script reads `FACET_STRATEGY`,
`FACET_CLI_VERSION`, `FACET_WORKING_DIR`, `FACET_DRY_RUN` and `FACET_OUTPUT`
from the environment, and exits non-zero only on a real failure.

## Notes

The facet CLI exits `0` whether or not anything moved, so "did anything change"
is answered by comparing `facets.lock` before and after — not by the exit code,
and not by `git diff`, which is blind to a lockfile that is untracked or
gitignored.

Updating also re-materializes each facet's assets into the adapter directories,
so those files are part of the same commit, and it may migrate `facets.json`'s
`manifestVersion` — expect that line in the diff.

## License

MIT
