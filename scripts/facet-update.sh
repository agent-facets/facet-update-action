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
#   updated=true|false      whether any lock entry changed
#   count=<n>               how many lock entries changed
#   summary=<markdown>      a table of what changed, base64-encoded
#
# Exit status: 0 on success, non-zero only when the update genuinely failed.
# Note that the facet CLI itself exits 0 whether or not anything moved, which
# is why this script works out "did any lock entry change" for itself.

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

TRANSPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/facet-update.XXXXXX")"
trap 'rm -rf "$TRANSPORT_DIR"' EXIT
BEFORE_FILE="$TRANSPORT_DIR/before.json"
AFTER_FILE="$TRANSPORT_DIR/after.json"
CHANGES_FILE="$TRANSPORT_DIR/changes.json"
SUMMARY_FILE="$TRANSPORT_DIR/summary.md"

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

# Record the complete locked entries before we touch anything. A version alone
# is not the lock state: a changed integrity or asset set needs reporting too.
snapshot() {
  # shellcheck disable=SC2016  # ${...} below is a JS template literal, not shell
  node -e '
    const fs = require("fs")
    const findDuplicateJsonMember = text => {
      const stack = []
      let expectKey = false
      let pendingSegment = ""
      let index = 0
      const currentPath = () => stack.map(frame => frame.pathSegment).filter(Boolean).join(".")
      while (index < text.length) {
        const character = text[index]
        if (character === "\"") {
          let end = index + 1
          while (end < text.length) {
            if (text[end] === "\\") {
              end += 2
              continue
            }
            if (text[end] === "\"") break
            end += 1
          }
          const top = stack[stack.length - 1]
          if (top?.kind === "object" && expectKey) {
            const key = JSON.parse(text.slice(index, end + 1))
            if (top.keys.has(key)) return { key, path: currentPath() || "root" }
            top.keys.add(key)
            pendingSegment = key
            expectKey = false
          }
          index = end + 1
          continue
        }
        if (character === "{") {
          stack.push({ kind: "object", keys: new Set(), pathSegment: pendingSegment })
          pendingSegment = ""
          expectKey = true
        } else if (character === "[") {
          stack.push({ kind: "array", index: 0, pathSegment: pendingSegment })
          pendingSegment = "0"
        } else if (character === "}" || character === "]") {
          stack.pop()
          pendingSegment = ""
        } else if (character === ",") {
          const top = stack[stack.length - 1]
          if (top?.kind === "object") expectKey = true
          else if (top?.kind === "array") {
            top.index += 1
            pendingSegment = String(top.index)
          }
        }
        index += 1
      }
      return null
    }
    const object = (value, path) => {
      if (value === null || typeof value !== "object" || Array.isArray(value)) {
        throw new Error(`${path} must be an object`)
      }
      return value
    }
    const string = (value, path) => {
      if (typeof value !== "string") throw new Error(`${path} must be a string`)
      return value
    }
    const oneOf = (value, choices, path) => {
      if (!choices.includes(value)) throw new Error(`${path} must be one of ${choices.join(", ")}`)
      return value
    }
    const assetSegment = (value, path) => {
      string(value, path)
      if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(value) || value.length > 64) {
        throw new Error(`${path} must be a lowercase asset-name segment`)
      }
    }
    const safePath = (value, path) => {
      string(value, path)
      if (value.includes("\\") || value.split("/").some(segment => ["", ".", ".."].includes(segment))) {
        throw new Error(`${path} must be a safe relative path`)
      }
    }
    const source = (value, path) => {
      object(value, path)
      oneOf(value.kind, ["registry", "git", "local"], `${path}.kind`)
      if (value.kind === "registry") string(value.registry, `${path}.registry`)
      if (value.kind === "local") string(value.path, `${path}.path`)
      if (value.kind === "git") {
        string(value.url, `${path}.url`)
        string(value.commit, `${path}.commit`)
        if (!/^[0-9a-f]{8,}$/.test(value.commit)) {
          throw new Error(`${path}.commit must be a lowercase hex commit SHA of at least 8 characters`)
        }
      }
    }
    const version = (value, path) => {
      string(value, path)
      const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(value)
      if (match === null || !match.slice(1).every(component => Number.isSafeInteger(Number(component)))) {
        throw new Error(`${path} must be an exact M.N.P version with safe numeric components`)
      }
    }
    const materialization = (value, path) => {
      object(value, path)
      oneOf(value.kind, ["authored", "aliased", "omitted"], `${path}.kind`)
      if (value.kind === "aliased") assetSegment(value.as, `${path}.as`)
      else if ("as" in value) throw new Error(`${path}.as is only valid for aliased materialization`)
    }
    const asset = (value, lockfileVersion, path) => {
      object(value, path)
      oneOf(value.scope, ["system", "user", "project"], `${path}.scope`)
      oneOf(value.type, ["skill", "agent", "command"], `${path}.type`)
      safePath(value.name, `${path}.name`)
      if (lockfileVersion === 0.3) materialization(value.materialization, `${path}.materialization`)
      if (!Array.isArray(value.files)) throw new Error(`${path}.files must be an array`)
      if (value.files.length === 0) throw new Error(`${path}.files must contain at least one file`)
      let previous = null
      for (let index = 0; index < value.files.length; index += 1) {
        const file = object(value.files[index], `${path}.files[${index}]`)
        safePath(file.path, `${path}.files[${index}].path`)
        string(file.integrity, `${path}.files[${index}].integrity`)
        if (!/^sha256:[a-f0-9]{64}$/.test(file.integrity)) {
          throw new Error(`${path}.files[${index}].integrity must be sha256 followed by 64 lowercase hex characters`)
        }
        if (previous !== null && file.path <= previous) {
          throw new Error(`${path}.files must be sorted by path with no duplicates`)
        }
        previous = file.path
      }
      const primary = `${value.type}s/${value.name}${value.type === "skill" ? "/SKILL.md" : ".md"}`
      if (value.type === "skill") {
        const root = `skills/${value.name}/`
        if (!value.files.some(file => file.path === primary) || value.files.some(file => !file.path.startsWith(root))) {
          throw new Error(`${path}.files must contain ${primary} and stay under ${root}`)
        }
      } else if (value.files.length !== 1 || value.files[0].path !== primary) {
        throw new Error(`${path}.files must contain only ${primary}`)
      }
    }
    const entry = (value, lockfileVersion, path) => {
      object(value, path)
      source(value.source, `${path}.source`)
      version(value.version, `${path}.version`)
      string(value.integrity, `${path}.integrity`)
      if (!Array.isArray(value.assets)) throw new Error(`${path}.assets must be an array`)
      value.assets.forEach((item, index) => asset(item, lockfileVersion, `${path}.assets[${index}]`))
    }
    try {
      if (!fs.existsSync("facets.lock")) throw new Error("file is missing")
      const text = fs.readFileSync("facets.lock", "utf8")
      const lock = JSON.parse(text)
      const duplicate = findDuplicateJsonMember(text)
      if (duplicate !== null) {
        throw new Error(`duplicate JSON object member ${JSON.stringify(duplicate.key)} at ${duplicate.path}`)
      }
      object(lock, "root")
      if (lock.lockfileVersion !== 0.2 && lock.lockfileVersion !== 0.3) {
        throw new Error("lockfileVersion must be numeric 0.2 or 0.3")
      }
      object(lock.facets, "facets")
      const out = Object.create(null)
      for (const [name, value] of Object.entries(lock.facets)) {
        entry(value, lock.lockfileVersion, `facet ${name}`)
        out[name] = value
      }
      console.log(JSON.stringify(out))
    } catch (err) {
      process.stderr.write(`facet-update: invalid facets.lock (${err.message})\n`)
      process.exit(1)
    }
  '
}

snapshot > "$BEFORE_FILE"

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

snapshot > "$AFTER_FILE"

# What changed comes from comparing the lockfile before and after, not from
# asking git. git cannot answer this reliably: `git diff` is blind to a
# facets.lock that is untracked or gitignored, and in that case it reports no
# change even though every facet moved. The lockfile is the ground truth for
# "what version is installed", so compare that directly.
# shellcheck disable=SC2016  # the ${...} below are JS template literals, not shell
node -e '
  const fs = require("fs")
  const before = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
  const after = JSON.parse(fs.readFileSync(process.argv[2], "utf8"))
  const hasOwn = (object, key) => Object.prototype.hasOwnProperty.call(object, key)
  const stable = value => {
    if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`
    if (value && typeof value === "object") {
      return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stable(value[key])}`).join(",")}}`
    }
    return JSON.stringify(value)
  }
  const displayVersion = entry => typeof entry.version === "string" ? entry.version : "unknown"
  const rows = []
  for (const [name, to] of Object.entries(after)) {
    const from = before[name]
    if (!hasOwn(before, name)) rows.push({ name, from: "—", to: displayVersion(to), kind: "added" })
    else if (stable(from) !== stable(to)) rows.push({ name, from: displayVersion(from), to: displayVersion(to), kind: "updated" })
  }
  for (const name of Object.keys(before)) {
    if (!hasOwn(after, name)) rows.push({ name, from: displayVersion(before[name]), to: "—", kind: "removed" })
  }
  rows.sort((a, b) => a.name.localeCompare(b.name))
  console.log(JSON.stringify(rows))
' "$BEFORE_FILE" "$AFTER_FILE" > "$CHANGES_FILE"

COUNT="$(node -e 'const fs = require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).length)' "$CHANGES_FILE")"

# shellcheck disable=SC2016  # the ${...} below are JS template literals, not shell
node -e '
  const fs = require("fs")
  const rows = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
  if (rows.length === 0) process.exit(0)
  const lines = ["| Facet | From | To | |", "| --- | --- | --- | --- |"]
  for (const r of rows) lines.push(`| \`${r.name}\` | ${r.from} | ${r.to} | ${r.kind} |`)
  process.stdout.write(lines.join("\n"))
' "$CHANGES_FILE" > "$SUMMARY_FILE"

if [ "$DRY_RUN" = "true" ]; then
  CHANGED=false
  COUNT=0
  : > "$SUMMARY_FILE"
elif [ "$COUNT" -gt 0 ]; then
  CHANGED=true
else
  CHANGED=false
fi

echo "facet-update: updated=${CHANGED} count=${COUNT}"
if [ -s "$SUMMARY_FILE" ]; then
  cat "$SUMMARY_FILE"
  printf '\n'
fi

if [ -n "$OUTPUT" ]; then
  {
    echo "updated=${CHANGED}"
    echo "count=${COUNT}"
    # base64 keeps a multi-line markdown table inside a single key=value line.
    printf 'summary='
    base64 < "$SUMMARY_FILE" | tr -d '\n'
    printf '\n'
  } >> "$OUTPUT"
fi
