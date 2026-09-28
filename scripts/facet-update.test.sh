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

assert_file_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "expected '$expected' in $file"
}

write_lock() {
  local destination="$1"
  local lockfile_version="$2"
  local facets="$3"
  printf '{"lockfileVersion":%s,"facets":%s}\n' "$lockfile_version" "$facets" > "$destination/facets.lock"
}

decode_summary() {
  node -e 'const chunks = []; process.stdin.on("data", chunk => chunks.push(chunk)); process.stdin.on("end", () => process.stdout.write(Buffer.from(Buffer.concat(chunks).toString(), "base64")))'
}

run_case() {
  local name="$1"
  local lockfile_version="$2"
  local before="$3"
  local mode="$4"
  local dry_run="${5:-false}"
  local directory="$TMP/$name"
  mkdir -p "$directory/bin" "$directory/tmp"
  printf '{}\n' > "$directory/facets.json"
  write_lock "$directory" "$lockfile_version" "$before"
  cat > "$directory/bin/npx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${FAKE_NPX_MODE:?}" in
  version) node -e 'const fs = require("fs"); const p = "facets.lock"; const l = JSON.parse(fs.readFileSync(p)); l.facets.alpha.version = "2.0.0"; fs.writeFileSync(p, JSON.stringify(l))' ;;
  integrity) node -e 'const fs = require("fs"); const p = "facets.lock"; const l = JSON.parse(fs.readFileSync(p)); l.facets.alpha.integrity = "sha512-new"; fs.writeFileSync(p, JSON.stringify(l))' ;;
  addremove) node -e 'const fs = require("fs"); const p = "facets.lock"; const l = JSON.parse(fs.readFileSync(p)); delete l.facets.old; l.facets.new = { source: { kind: "local", path: "./new" }, version: "1.0.0", integrity: "facet-integrity", assets: [] }; fs.writeFileSync(p, JSON.stringify(l))' ;;
  incomplete) node -e 'const fs = require("fs"); const p = "facets.lock"; const l = JSON.parse(fs.readFileSync(p)); delete l.facets.alpha.assets; fs.writeFileSync(p, JSON.stringify(l))' ;;
  badtype) node -e 'const fs = require("fs"); const p = "facets.lock"; const l = JSON.parse(fs.readFileSync(p)); l.facets.alpha.source = "npm"; fs.writeFileSync(p, JSON.stringify(l))' ;;
  missingmaterialization) node -e 'const fs = require("fs"); const p = "facets.lock"; const l = JSON.parse(fs.readFileSync(p)); delete l.facets.alpha.assets[0].materialization; fs.writeFileSync(p, JSON.stringify(l))' ;;
  duplicate02) printf '%s\n' '{"lockfileVersion":0.2,"facets":{"alpha":{"source":{"kind":"local","path":"./alpha"},"version":"bad","\u0076ersion":"1.0.0","integrity":"facet-integrity","assets":[]}}}' > facets.lock ;;
  duplicate03) printf '%s\n' '{"lockfileVersion":0.3,"facets":{"alpha":{"source":{"kind":"local","path":"./alpha"},"version":"bad","\u0076ersion":"1.0.0","integrity":"facet-integrity","assets":[]}}}' > facets.lock ;;
  protointegrity) node -e 'const fs = require("fs"); const p = "facets.lock"; const l = JSON.parse(fs.readFileSync(p)); l.facets["__proto__"].integrity = "new"; fs.writeFileSync(p, JSON.stringify(l))' ;;
  protoaddremove) node -e 'const fs = require("fs"); const p = "facets.lock"; const l = JSON.parse(fs.readFileSync(p)); delete l.facets.constructor; const entry = { source: { kind: "local", path: "./proto" }, version: "1.0.0", integrity: "new", assets: [] }; Object.defineProperty(l.facets, "__proto__", { value: entry, enumerable: true, configurable: true, writable: true }); fs.writeFileSync(p, JSON.stringify(l))' ;;
  largechange) node -e 'const fs = require("fs"); const p = "facets.lock"; const l = JSON.parse(fs.readFileSync(p)); for (const entry of Object.values(l.facets)) entry.integrity = "new"; fs.writeFileSync(p, JSON.stringify(l))' ;;
  malformed) printf '{bad\n' > facets.lock ;;
  missing | deleted) rm facets.lock ;;
  unsupported) printf '{"lockfileVersion":0.4,"facets":{}}\n' > facets.lock ;;
  unchanged) ;;
  dryrun) ;;
  *) exit 99 ;;
esac
EOF
  chmod +x "$directory/bin/npx"
  local status
  set +e
  PATH="$directory/bin:$PATH" TMPDIR="$directory/tmp" FAKE_NPX_MODE="$mode" FACET_WORKING_DIR="$directory" FACET_DRY_RUN="$dry_run" FACET_OUTPUT="$directory/output" "$SCRIPT" > "$directory/stdout" 2> "$directory/stderr"
  status=$?
  set -e
  if find "$directory/tmp" -mindepth 1 -print -quit | grep -q .; then
    fail "$name left transport files behind"
  fi
  return "$status"
}

base02='{"alpha":{"source":{"kind":"registry","registry":"https://cafe.example"},"version":"1.0.0","integrity":"facet-integrity","assets":[{"scope":"project","type":"agent","name":"reviewer","files":[{"path":"agents/reviewer.md","integrity":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}]}}'
base03='{"alpha":{"source":{"kind":"registry","registry":"https://cafe.example"},"version":"1.0.0","integrity":"facet-integrity","assets":[{"scope":"project","type":"agent","name":"reviewer","materialization":{"kind":"authored"},"files":[{"path":"agents/reviewer.md","integrity":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}]}}'
entry03='{"source":{"kind":"local","path":"./facet"},"version":"1.0.0","integrity":"old","assets":[]}'
proto03="{\"__proto__\":$entry03}"
constructor03="{\"constructor\":$entry03}"
duplicate02='{"lockfileVersion":0.2,"facets":{"alpha":{"source":{"kind":"local","path":"./alpha"},"version":"bad","\u0076ersion":"1.0.0","integrity":"facet-integrity","assets":[]}}}'
duplicate03='{"lockfileVersion":0.3,"facets":{"alpha":{"source":{"kind":"local","path":"./alpha"},"version":"bad","\u0076ersion":"1.0.0","integrity":"facet-integrity","assets":[]}}}'

assert_duplicate_pre_fails() {
  local name="$1"
  local document="$2"
  local directory="$TMP/$name"
  mkdir -p "$directory"
  printf '{}\n' > "$directory/facets.json"
  printf '%s\n' "$document" > "$directory/facets.lock"
  if FACET_WORKING_DIR="$directory" "$SCRIPT" > "$directory/stdout" 2> "$directory/stderr"; then
    fail "$name unexpectedly succeeded"
  fi
  assert_contains "$(cat "$directory/stderr")" 'facet-update: invalid facets.lock (duplicate JSON object member "version" at facets.alpha)'
}

test_duplicate_members() {
  assert_duplicate_pre_fails duplicate-02-pre "$duplicate02"
  assert_duplicate_pre_fails duplicate-03-pre "$duplicate03"
  if run_case duplicate-02-post 0.2 "$base02" duplicate02; then
    fail 'duplicate 0.2 post-lock unexpectedly succeeded'
  fi
  assert_contains "$(cat "$TMP/duplicate-02-post/stderr")" 'facet-update: invalid facets.lock (duplicate JSON object member "version" at facets.alpha)'
  if run_case duplicate-03-post 0.3 "$base03" duplicate03; then
    fail 'duplicate 0.3 post-lock unexpectedly succeeded'
  fi
  assert_contains "$(cat "$TMP/duplicate-03-post/stderr")" 'facet-update: invalid facets.lock (duplicate JSON object member "version" at facets.alpha)'
}

test_prototype_keys() {
  run_case proto-integrity 0.3 "$proto03" protointegrity
  assert_contains "$(cat "$TMP/proto-integrity/stdout")" 'updated=true count=1'
  # shellcheck disable=SC2016  # backticks are literal markdown in the expected table
  assert_contains "$(sed -n 's/^summary=//p' "$TMP/proto-integrity/output" | decode_summary)" '| `__proto__` | 1.0.0 | 1.0.0 | updated |'

  run_case proto-addremove 0.3 "$constructor03" protoaddremove
  assert_contains "$(cat "$TMP/proto-addremove/stdout")" 'updated=true count=2'
  local summary
  summary="$(sed -n 's/^summary=//p' "$TMP/proto-addremove/output" | decode_summary)"
  # shellcheck disable=SC2016  # backticks are literal markdown in the expected table
  assert_contains "$summary" '| `__proto__` | — | 1.0.0 | added |'
  # shellcheck disable=SC2016  # backticks are literal markdown in the expected table
  assert_contains "$summary" '| `constructor` | 1.0.0 | — | removed |'
}

test_large_lock() {
  local facets
  # shellcheck disable=SC2016  # ${...} below is a JS template literal, not shell
  facets="$(node -e '
    const facets = {}
    for (let index = 0; index < 1800; index += 1) {
      const name = `facet-${String(index).padStart(4, "0")}-with-a-long-valid-name-for-large-lock-regression`
      facets[name] = { source: { kind: "local", path: `./${name}` }, version: "1.0.0", integrity: "old", assets: [] }
    }
    process.stdout.write(JSON.stringify(facets))
  ')"

  run_case large-unchanged 0.3 "$facets" unchanged
  local lock_bytes
  lock_bytes="$(wc -c < "$TMP/large-unchanged/facets.lock" | tr -d ' ')"
  [ "$lock_bytes" -gt 163034 ] || fail "large lock is only $lock_bytes bytes"
  assert_file_contains "$TMP/large-unchanged/stdout" 'updated=false count=0'
  assert_equals "$(cat "$TMP/large-unchanged/output")" $'updated=false\ncount=0\nsummary='

  run_case large-changed 0.3 "$facets" largechange
  assert_file_contains "$TMP/large-changed/stdout" 'updated=true count=1800'
  assert_file_contains "$TMP/large-changed/output" 'count=1800'
  sed -n 's/^summary=//p' "$TMP/large-changed/output" | decode_summary > "$TMP/large-changed/summary.md"
  local summary_bytes
  summary_bytes="$(wc -c < "$TMP/large-changed/summary.md" | tr -d ' ')"
  [ "$summary_bytes" -gt 163034 ] || fail "large summary is only $summary_bytes bytes"
  # shellcheck disable=SC2016  # backticks are literal markdown in the expected table
  assert_file_contains "$TMP/large-changed/summary.md" '| `facet-0000-with-a-long-valid-name-for-large-lock-regression` | 1.0.0 | 1.0.0 | updated |'
  # shellcheck disable=SC2016  # backticks are literal markdown in the expected table
  assert_file_contains "$TMP/large-changed/summary.md" '| `facet-1799-with-a-long-valid-name-for-large-lock-regression` | 1.0.0 | 1.0.0 | updated |'
  printf 'facet-update large-lock tests: PASS lock_bytes=%s summary_bytes=%s count=1800\n' "$lock_bytes" "$summary_bytes"
}

case "${1:-all}" in
  duplicate-members)
    test_duplicate_members
    echo 'facet-update duplicate-member tests: PASS'
    exit 0
    ;;
  prototype-keys)
    test_prototype_keys
    echo 'facet-update prototype-key tests: PASS'
    exit 0
    ;;
  large-lock)
    test_large_lock
    exit 0
    ;;
  all) ;;
  *) fail "unknown test selection '$1'" ;;
esac

test_duplicate_members
test_prototype_keys
test_large_lock

run_case version 0.3 "$base03" version
assert_contains "$(cat "$TMP/version/stdout")" 'updated=true count=1'
# shellcheck disable=SC2016  # backticks are literal markdown in the expected table
assert_contains "$(sed -n 's/^summary=//p' "$TMP/version/output" | decode_summary)" '| `alpha` | 1.0.0 | 2.0.0 | updated |'

run_case integrity 0.3 "$base03" integrity
assert_contains "$(cat "$TMP/integrity/stdout")" 'updated=true count=1'
# shellcheck disable=SC2016  # backticks are literal markdown in the expected table
assert_contains "$(sed -n 's/^summary=//p' "$TMP/integrity/output" | decode_summary)" '| `alpha` | 1.0.0 | 1.0.0 | updated |'

run_case addremove 0.3 "${base03//alpha/old}" addremove
assert_contains "$(cat "$TMP/addremove/stdout")" 'updated=true count=2'
SUMMARY="$(sed -n 's/^summary=//p' "$TMP/addremove/output" | decode_summary)"
# shellcheck disable=SC2016  # backticks are literal markdown in the expected table
assert_contains "$SUMMARY" '| `new` | — | 1.0.0 | added |'
# shellcheck disable=SC2016  # backticks are literal markdown in the expected table
assert_contains "$SUMMARY" '| `old` | 1.0.0 | — | removed |'

for invalid in malformed missing deleted unsupported; do
  if run_case "$invalid" 0.3 "$base03" "$invalid"; then
    fail "$invalid post-lock unexpectedly succeeded"
  fi
  assert_contains "$(cat "$TMP/$invalid/stderr")" 'facet-update: invalid facets.lock'
done

run_case valid02 0.2 "$base02" unchanged
assert_contains "$(cat "$TMP/valid02/stdout")" 'updated=false count=0'
run_case valid03 0.3 "$base03" unchanged
assert_contains "$(cat "$TMP/valid03/stdout")" 'updated=false count=0'

PRE_INCOMPLETE="$TMP/pre-incomplete"
mkdir -p "$PRE_INCOMPLETE"
printf '{}\n' > "$PRE_INCOMPLETE/facets.json"
write_lock "$PRE_INCOMPLETE" 0.2 '{"alpha":{"source":{"kind":"local","path":"./alpha"},"version":"1.0.0","integrity":"facet-integrity"}}'
if FACET_WORKING_DIR="$PRE_INCOMPLETE" "$SCRIPT" > "$PRE_INCOMPLETE/stdout" 2> "$PRE_INCOMPLETE/stderr"; then
  fail 'incomplete pre-lock unexpectedly succeeded'
fi
assert_contains "$(cat "$PRE_INCOMPLETE/stderr")" 'facet-update: invalid facets.lock (facet alpha.assets must be an array)'

PRE_BAD_TYPE="$TMP/pre-bad-type"
mkdir -p "$PRE_BAD_TYPE"
printf '{}\n' > "$PRE_BAD_TYPE/facets.json"
write_lock "$PRE_BAD_TYPE" 0.3 '{"alpha":{"source":"npm","version":"1.0.0","integrity":"facet-integrity","assets":[]}}'
if FACET_WORKING_DIR="$PRE_BAD_TYPE" "$SCRIPT" > "$PRE_BAD_TYPE/stdout" 2> "$PRE_BAD_TYPE/stderr"; then
  fail 'bad-type pre-lock unexpectedly succeeded'
fi
assert_contains "$(cat "$PRE_BAD_TYPE/stderr")" 'facet-update: invalid facets.lock (facet alpha.source must be an object)'

PRE_MATERIALIZATION="$TMP/pre-materialization"
mkdir -p "$PRE_MATERIALIZATION"
printf '{}\n' > "$PRE_MATERIALIZATION/facets.json"
write_lock "$PRE_MATERIALIZATION" 0.3 "$base02"
if FACET_WORKING_DIR="$PRE_MATERIALIZATION" "$SCRIPT" > "$PRE_MATERIALIZATION/stdout" 2> "$PRE_MATERIALIZATION/stderr"; then
  fail '0.3 pre-lock without materialization unexpectedly succeeded'
fi
assert_contains "$(cat "$PRE_MATERIALIZATION/stderr")" 'facet-update: invalid facets.lock (facet alpha.assets[0].materialization must be an object)'

if run_case post-incomplete 0.3 "$base03" incomplete; then
  fail 'incomplete post-entry unexpectedly succeeded'
fi
assert_contains "$(cat "$TMP/post-incomplete/stderr")" 'facet-update: invalid facets.lock (facet alpha.assets must be an array)'

if run_case post-badtype 0.3 "$base03" badtype; then
  fail 'bad-type post-entry unexpectedly succeeded'
fi
assert_contains "$(cat "$TMP/post-badtype/stderr")" 'facet-update: invalid facets.lock (facet alpha.source must be an object)'

if run_case post-missingmaterialization 0.3 "$base03" missingmaterialization; then
  fail '0.3 post-entry without materialization unexpectedly succeeded'
fi
assert_contains "$(cat "$TMP/post-missingmaterialization/stderr")" 'facet-update: invalid facets.lock (facet alpha.assets[0].materialization must be an object)'

PRE_DIR="$TMP/pre-missing"
mkdir -p "$PRE_DIR/bin"
printf '{}\n' > "$PRE_DIR/facets.json"
if PATH="$PRE_DIR/bin:$PATH" FACET_WORKING_DIR="$PRE_DIR" "$SCRIPT" > "$PRE_DIR/stdout" 2> "$PRE_DIR/stderr"; then
  fail 'missing pre-lock unexpectedly succeeded'
fi
assert_contains "$(cat "$PRE_DIR/stderr")" 'facet-update: no facets.lock'

run_case unchanged 0.3 "$base03" unchanged
assert_contains "$(cat "$TMP/unchanged/stdout")" 'updated=false count=0'

DRY_DIR="$TMP/dryrun"
mkdir -p "$DRY_DIR/bin"
printf '{}\n' > "$DRY_DIR/facets.json"
write_lock "$DRY_DIR" 0.3 "$base03"
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
