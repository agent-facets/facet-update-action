#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/facet-update.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local actual="$1"
  local expected="$2"
  [[ "$actual" == *"$expected"* ]] || fail "expected '$expected' in: $actual"
}

assert_equals() {
  [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}

write_lock() {
  local destination="$1"
  local facets="$2"
  printf '{"lockfileVersion":0.3,"facets":%s}\n' "$facets" > "$destination/facets.lock"
}

run_case() {
  local name="$1"
  local before="$2"
  local mode="$3"
  local dry_run="${4:-false}"
  local directory="$TMP/$name"
  mkdir -p "$directory/bin"
  printf '{}\n' > "$directory/facets.json"
  write_lock "$directory" "$before"
  cat > "$directory/bin/npx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${FAKE_NPX_MODE:?}" in
  version) node -e 'const fs = require("fs"); const p = "facets.lock"; const l = JSON.parse(fs.readFileSync(p)); l.facets.alpha.version = "2.0.0"; fs.writeFileSync(p, JSON.stringify(l))' ;;
  integrity) node -e 'const fs = require("fs"); const p = "facets.lock"; const l = JSON.parse(fs.readFileSync(p)); l.facets.alpha.integrity = "sha512-new"; fs.writeFileSync(p, JSON.stringify(l))' ;;
  addremove) node -e 'const fs = require("fs"); const p = "facets.lock"; const l = JSON.parse(fs.readFileSync(p)); delete l.facets.old; l.facets.new = { source: "npm", version: "1.0.0", integrity: "sha512-new", assets: [] }; fs.writeFileSync(p, JSON.stringify(l))' ;;
  malformed) printf '{bad\n' > facets.lock ;;
  missing | deleted) rm facets.lock ;;
  unsupported) printf '{"lockfileVersion":0.4,"facets":{}}\n' > facets.lock ;;
  unchanged) ;;
  dryrun) ;;
  *) exit 99 ;;
esac
EOF
  chmod +x "$directory/bin/npx"
  PATH="$directory/bin:$PATH" FAKE_NPX_MODE="$mode" FACET_WORKING_DIR="$directory" FACET_DRY_RUN="$dry_run" FACET_OUTPUT="$directory/output" "$SCRIPT" > "$directory/stdout" 2> "$directory/stderr"
}

base='{"alpha":{"source":"npm","version":"1.0.0","integrity":"sha512-old","assets":[]}}'

run_case version "$base" version
assert_contains "$(cat "$TMP/version/stdout")" 'updated=true count=1'
# shellcheck disable=SC2016  # backticks are literal markdown in the expected table
assert_contains "$(base64 -D < <(sed -n 's/^summary=//p' "$TMP/version/output"))" '| `alpha` | 1.0.0 | 2.0.0 | updated |'

run_case integrity "$base" integrity
assert_contains "$(cat "$TMP/integrity/stdout")" 'updated=true count=1'
# shellcheck disable=SC2016  # backticks are literal markdown in the expected table
assert_contains "$(base64 -D < <(sed -n 's/^summary=//p' "$TMP/integrity/output"))" '| `alpha` | 1.0.0 | 1.0.0 | updated |'

run_case addremove '{"old":{"source":"npm","version":"1.0.0","integrity":"sha512-old","assets":[]}}' addremove
assert_contains "$(cat "$TMP/addremove/stdout")" 'updated=true count=2'
SUMMARY="$(base64 -D < <(sed -n 's/^summary=//p' "$TMP/addremove/output"))"
# shellcheck disable=SC2016  # backticks are literal markdown in the expected table
assert_contains "$SUMMARY" '| `new` | — | 1.0.0 | added |'
# shellcheck disable=SC2016  # backticks are literal markdown in the expected table
assert_contains "$SUMMARY" '| `old` | 1.0.0 | — | removed |'

for invalid in malformed missing deleted unsupported; do
  if run_case "$invalid" "$base" "$invalid"; then
    fail "$invalid post-lock unexpectedly succeeded"
  fi
  assert_contains "$(cat "$TMP/$invalid/stderr")" 'facet-update: invalid facets.lock'
done

PRE_DIR="$TMP/pre-missing"
mkdir -p "$PRE_DIR/bin"
printf '{}\n' > "$PRE_DIR/facets.json"
if PATH="$PRE_DIR/bin:$PATH" FACET_WORKING_DIR="$PRE_DIR" "$SCRIPT" > "$PRE_DIR/stdout" 2> "$PRE_DIR/stderr"; then
  fail 'missing pre-lock unexpectedly succeeded'
fi
assert_contains "$(cat "$PRE_DIR/stderr")" 'facet-update: no facets.lock'

run_case unchanged "$base" unchanged
assert_contains "$(cat "$TMP/unchanged/stdout")" 'updated=false count=0'

DRY_DIR="$TMP/dryrun"
mkdir -p "$DRY_DIR/bin"
printf '{}\n' > "$DRY_DIR/facets.json"
write_lock "$DRY_DIR" "$base"
cat > "$DRY_DIR/bin/npx" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$DRY_DIR/bin/npx"
cp "$DRY_DIR/facets.lock" "$DRY_DIR/before.lock"
PATH="$DRY_DIR/bin:$PATH" FACET_WORKING_DIR="$DRY_DIR" FACET_DRY_RUN=true FACET_OUTPUT="$DRY_DIR/output" "$SCRIPT" > "$DRY_DIR/stdout" 2> "$DRY_DIR/stderr"
cmp -s "$DRY_DIR/before.lock" "$DRY_DIR/facets.lock" || fail 'dry-run changed facets.lock bytes'
assert_contains "$(cat "$DRY_DIR/stdout")" 'facet-update: updated=false count=0'
assert_equals "$(cat "$DRY_DIR/output")" $'updated=false\ncount=0\nsummary='

echo 'facet-update tests: PASS'
