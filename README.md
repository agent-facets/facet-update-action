# Facet Update Action

Keep the facets a repository declares up to date, on a schedule, and open a pull
request when any of them move — the way Dependabot does it for packages.

The action runs `facet update`, notices whether `facets.json` or `facets.lock`
actually changed, and opens (or refreshes) a single pull request describing what
moved. Nothing is ever merged for you.

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

jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: agent-facets/facet-update-action@v1
```

That is the whole setup. `workflow_dispatch` is worth keeping — it is how you
test the thing without waiting a week.

## Choosing a schedule

`cron` is standard five-field UTC cron. A few that people actually want:

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
- uses: agent-facets/facet-update-action@v1
  with:
    strategy: in-range
```

## Inputs

| Input | Default | What it does |
| --- | --- | --- |
| `strategy` | `latest` | `latest` or `in-range` — see above. |
| `cli-version` | `latest` | Version of the `agent-facets` CLI to run. Pin it for reproducible runs. |
| `working-directory` | `.` | Directory holding `facets.json`. |
| `open-pr` | `true` | Set `false` to push the branch and stop there. |
| `branch` | `facet-updates` | Branch the update is pushed to; reused across runs. |
| `base` | repo default | Branch the pull request targets. |
| `commit-message` | `chore(facets): update facets` | First line of the commit. |
| `pr-title` | `chore(facets): update facets` | Pull request title. |
| `labels` | none | Comma-separated labels. A label the repo doesn't have is skipped, not an error. |
| `token` | `github.token` | Token used to push and open the pull request. |

## Outputs

| Output | What it is |
| --- | --- |
| `updated` | `"true"` when `facets.json` or `facets.lock` changed. |
| `count` | How many facets moved. |
| `pr-url` | URL of the pull request, empty when none was opened. |

## Permissions

The job needs `contents: write` to push the branch and `pull-requests: write`
to open the pull request.

Pull requests opened with the default `GITHUB_TOKEN` do not trigger other
workflows. If your checks must run on this pull request, pass a personal access
token or GitHub App token as `token` instead.

## Using it without GitHub Actions

The part that decides *what to update* is deliberately separate from the part
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
detection logic comes along unchanged. The script takes its settings from the
environment (`FACET_STRATEGY`, `FACET_CLI_VERSION`, `FACET_WORKING_DIR`,
`FACET_DRY_RUN`, `FACET_OUTPUT`) and exits non-zero only on a real failure.

## Notes

The facet CLI exits `0` whether or not anything moved, so this action decides
by diffing `facets.json` and `facets.lock` rather than trusting the exit code.

Updating may also migrate `facets.json`'s `manifestVersion`, so that line can
appear in the diff alongside the version changes.

## License

MIT
