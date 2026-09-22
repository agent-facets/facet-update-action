#!/usr/bin/env bash
#
# Run a facet update and report what moved.
#
# This script is the CI-neutral half of the updater. It knows how to run the
# facet CLI and how to work out what changed; it knows nothing about GitHub,
# GitLab or Buildkite. Porting the updater to another CI system means writing a
# new wrapper that calls this script and then opens a merge request its own way
# — the detection logic below should not need to change.
#
# Inputs (environment):
#   FACET_STRATEGY      latest | in-range     (default: latest)
#   FACET_CLI_VERSION   npm version of the agent-facets CLI (default: latest)
#   FACET_WORKING_DIR   directory holding facets.json (default: .)
#   FACET_DRY_RUN       true | false          (default: false)
#   FACET_OUTPUT        file to append key=value results to (default: none)
#
# Results (written to FACET_OUTPUT, and always printed):
#   updated=true|false      whether any facet version moved
#   count=<n>               how many facets changed version
#   summary=<markdown>      a table of what changed, base64-encoded
#
# Exit status: 0 on success, non-zero only when the update genuinely failed.
# Note that the facet CLI itself exits 0 whether or not anything moved, which
# is why this script works out "did anything change" for itself.

set -euo pipefail

STRATEGY="${FACET_STRATEGY:-latest}"
CLI_VERSION="${FACET_CLI_VERSION:-latest}"
WORKING_DIR="${FACET_WORKING_DIR:-.}"
DRY_RUN="${FACET_DRY_RUN:-false}"
OUTPUT="${FACET_OUTPUT:-}"

# Reject anything that isn't one of the two known strategies before it reaches
# a command line.
case "$STRATEGY" in
  latest | in-range) ;;
  *)
    echo "facet-update: strategy must be 'latest' or 'in-range', got '${STRATEGY}'" >&2
    exit 2
    ;;
esac

# The CLI version is interpolated into an npx package specifier, so it has to
# be a plain version or dist-tag — never arbitrary text.
#
# This uses bash's own [[ =~ ]] rather than grep. grep anchors ^ and $ per
# LINE, so a value like $'1.0.0\n; rm -rf /' passes a grep check that looks
# identical to this one; [[ =~ ]] anchors to the whole string and rejects it.
if [[ ! "$CLI_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "facet-update: cli-version must match [A-Za-z0-9][A-Za-z0-9._-]*, got '${CLI_VERSION}'" >&2
  exit 2
fi

# Anything that is not exactly "false" here has to be rejected rather than
# treated as false. A workflow that says dry-run: True means "preview", and
# silently giving it a real update — commit, push, pull request — is the one
# failure this input exists to prevent.
case "$DRY_RUN" in
  true | false) ;;
  *)
    echo "facet-update: dry-run must be 'true' or 'false', got '${DRY_RUN}'" >&2
    exit 2
    ;;
esac

if [ ! -d "$WORKING_DIR" ]; then
  echo "facet-update: working directory '${WORKING_DIR}' does not exist" >&2
  exit 2
fi

cd "$WORKING_DIR"

if [ ! -f facets.json ]; then
  echo "facet-update: no facets.json in '${WORKING_DIR}' — nothing to update" >&2
  exit 2
fi

# `facet update` refuses to run when a facet in facets.json has no entry in
# facets.lock, so say why in our own words rather than letting the CLI's
# "not in facets.lock" surface from inside a scheduled job.
if [ ! -f facets.lock ]; then
  echo "facet-update: no facets.lock in '${WORKING_DIR}'." >&2
  echo "  facet update needs an existing lockfile. Run 'facet install' and commit" >&2
  echo "  facets.lock before scheduling updates." >&2
  exit 2
fi

# Record the locked versions before we touch anything, so the summary can say
# what moved rather than just that something did.
snapshot() {
  # shellcheck disable=SC2016  # ${...} below is a JS template literal, not shell
  node -e '
    const fs = require("fs")
    if (!fs.existsSync("facets.lock")) { console.log("{}"); process.exit(0) }
    try {
      const lock = JSON.parse(fs.readFileSync("facets.lock", "utf8"))
      const out = {}
      for (const [name, entry] of Object.entries(lock.facets ?? {})) out[name] = entry.version
      console.log(JSON.stringify(out))
    } catch (err) {
      // Swallowing this would make a corrupt lockfile read as an empty one,
      // and every facet would then look newly added.
      process.stderr.write(`facet-update: facets.lock is not valid JSON (${err.message})\n`)
      process.exit(1)
    }
  '
}

BEFORE="$(snapshot)"

FACET_ARGS=(update --accept-mcp)
[ "$STRATEGY" = "latest" ] && FACET_ARGS+=(--latest)
[ "$DRY_RUN" = "true" ] && FACET_ARGS+=(--dry-run)

echo "facet-update: npx agent-facets@${CLI_VERSION} ${FACET_ARGS[*]}"

# stdin is closed so the CLI can never wait on a prompt in a non-interactive
# runner. The interactive picker is opt-in and we never pass --interactive.
set +e
npx --yes "agent-facets@${CLI_VERSION}" "${FACET_ARGS[@]}" < /dev/null
CLI_STATUS=$?
set -e

if [ "$CLI_STATUS" -ne 0 ]; then
  echo "facet-update: the facet CLI exited ${CLI_STATUS}" >&2
  exit "$CLI_STATUS"
fi

AFTER="$(snapshot)"

# What changed comes from comparing the lockfile before and after, not from
# asking git. git cannot answer this reliably: `git diff` is blind to a
# facets.lock that is untracked or gitignored, and in that case it reports no
# change even though every facet moved. The lockfile is the ground truth for
# "what version is installed", so compare that directly.
CHANGES="$(BEFORE="$BEFORE" AFTER="$AFTER" node -e '
  const before = JSON.parse(process.env.BEFORE)
  const after = JSON.parse(process.env.AFTER)
  const rows = []
  for (const [name, to] of Object.entries(after)) {
    const from = before[name]
    if (from === undefined) rows.push({ name, from: "—", to, kind: "added" })
    else if (from !== to) rows.push({ name, from, to, kind: "updated" })
  }
  for (const name of Object.keys(before)) {
    if (!(name in after)) rows.push({ name, from: before[name], to: "—", kind: "removed" })
  }
  rows.sort((a, b) => a.name.localeCompare(b.name))
  console.log(JSON.stringify(rows))
')"

COUNT="$(CHANGES="$CHANGES" node -e 'console.log(JSON.parse(process.env.CHANGES).length)')"

# shellcheck disable=SC2016  # the ${...} below are JS template literals, not shell
SUMMARY="$(CHANGES="$CHANGES" node -e '
  const rows = JSON.parse(process.env.CHANGES)
  if (rows.length === 0) { console.log(""); process.exit(0) }
  const lines = ["| Facet | From | To | |", "| --- | --- | --- | --- |"]
  for (const r of rows) lines.push(`| \`${r.name}\` | ${r.from} | ${r.to} | ${r.kind} |`)
  console.log(lines.join("\n"))
')"

if [ "$DRY_RUN" = "true" ]; then
  CHANGED=false
elif [ "$COUNT" -gt 0 ]; then
  CHANGED=true
else
  CHANGED=false
fi

echo "facet-update: updated=${CHANGED} count=${COUNT}"
[ -n "$SUMMARY" ] && printf '%s\n' "$SUMMARY"

if [ -n "$OUTPUT" ]; then
  {
    echo "updated=${CHANGED}"
    echo "count=${COUNT}"
    # base64 keeps a multi-line markdown table inside a single key=value line.
    echo "summary=$(printf '%s' "$SUMMARY" | base64 | tr -d '\n')"
  } >> "$OUTPUT"
fi
