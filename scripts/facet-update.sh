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
#   updated=true|false      whether facets.json or facets.lock actually changed
#   count=<n>               how many facets moved
#   summary=<markdown>      a table of what moved, base64-encoded
#
# Exit status: 0 on success, non-zero only when the update genuinely failed.
# Note that the facet CLI itself exits 0 whether or not anything moved, which
# is why this script diffs the files instead of trusting the exit code.

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
if ! printf '%s' "$CLI_VERSION" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
  echo "facet-update: cli-version must match [A-Za-z0-9][A-Za-z0-9._-]*, got '${CLI_VERSION}'" >&2
  exit 2
fi

if [ ! -d "$WORKING_DIR" ]; then
  echo "facet-update: working directory '${WORKING_DIR}' does not exist" >&2
  exit 2
fi

cd "$WORKING_DIR"

if [ ! -f facets.json ]; then
  echo "facet-update: no facets.json in '${WORKING_DIR}' — nothing to update" >&2
  exit 2
fi

# Record the locked versions before we touch anything, so the summary can say
# what moved rather than just that something did.
snapshot() {
  node -e '
    const fs = require("fs")
    if (!fs.existsSync("facets.lock")) { console.log("{}"); process.exit(0) }
    try {
      const lock = JSON.parse(fs.readFileSync("facets.lock", "utf8"))
      const out = {}
      for (const [name, entry] of Object.entries(lock.facets ?? {})) out[name] = entry.version
      console.log(JSON.stringify(out))
    } catch {
      console.log("{}")
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

# Decide "did anything change?" from the files, never from the CLI's exit code.
if [ "$DRY_RUN" = "true" ]; then
  CHANGED=false
elif git diff --quiet -- facets.json facets.lock 2>/dev/null; then
  CHANGED=false
else
  CHANGED=true
fi

# shellcheck disable=SC2016  # the ${...} below are JS template literals, not shell
SUMMARY="$(BEFORE="$BEFORE" AFTER="$AFTER" node -e '
  const before = JSON.parse(process.env.BEFORE)
  const after = JSON.parse(process.env.AFTER)
  const rows = []
  for (const [name, to] of Object.entries(after)) {
    const from = before[name]
    if (from === undefined) rows.push([name, "—", to, "added"])
    else if (from !== to) rows.push([name, from, to, "updated"])
  }
  for (const name of Object.keys(before)) {
    if (!(name in after)) rows.push([name, before[name], "—", "removed"])
  }
  if (rows.length === 0) { console.log(""); process.exit(0) }
  const lines = ["| Facet | From | To | |", "| --- | --- | --- | --- |"]
  for (const r of rows.sort((a, b) => a[0].localeCompare(b[0]))) {
    lines.push(`| \`${r[0]}\` | ${r[1]} | ${r[2]} | ${r[3]} |`)
  }
  console.log(lines.join("\n"))
')"

COUNT="$(BEFORE="$BEFORE" AFTER="$AFTER" node -e '
  const before = JSON.parse(process.env.BEFORE)
  const after = JSON.parse(process.env.AFTER)
  const names = new Set([...Object.keys(before), ...Object.keys(after)])
  let n = 0
  for (const name of names) if (before[name] !== after[name]) n++
  console.log(n)
')"

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
