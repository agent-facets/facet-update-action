#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REAL_GIT="$(command -v git)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/publish-update-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
PASS_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "ok $PASS_COUNT - $*"
}

fail_test() {
  echo "not ok - $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail_test "$3: expected '$2', got '$1'"
}

assert_contains() {
  grep -F -- "$2" "$1" >/dev/null || fail_test "$3: '$2' not found in $1"
}

cat > "$FAKE_BIN/npx" <<'FAKE_NPX'
#!/usr/bin/env bash
set -euo pipefail
case "${FAKE_NPX_MODE:-change}" in
  fail) exit 19 ;;
  no-change) exit 0 ;;
  change)
    node - "${FAKE_VALUE:-1}" <<'NODE'
const fs = require('fs')
const value = process.argv[2]
const lock = JSON.parse(fs.readFileSync('facets.lock', 'utf8'))
lock.facets.demo.version = "2.0." + value
fs.writeFileSync('facets.lock', JSON.stringify(lock, null, 2) + "\n")
fs.mkdirSync('agents', { recursive: true })
fs.writeFileSync('agents/demo.md', "generated " + value + "\n")
NODE
    ;;
  *) exit 97 ;;
esac
FAKE_NPX

cat > "$FAKE_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
if [ "${1:-}" = api ]; then
  method=GET
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --method) method="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$method" in
    GET)
      if [ -n "${FAKE_GH_HOOK:-}" ] && [ ! -e "${FAKE_GH_HOOK_DONE:-/dev/null}" ]; then
        : > "$FAKE_GH_HOOK_DONE"
        "$FAKE_GH_HOOK"
      fi
      [ "${FAKE_GH_GET_FAIL:-0}" = 0 ] || exit 41
      cat "${FAKE_PR_LIST:?}"
      ;;
    POST)
      [ "${FAKE_GH_POST_FAIL:-0}" = 0 ] || exit 42
      printf '{"number":99,"state":"open","html_url":"https://example.test/pr/99","user":{"login":"%s"}}\n' "${FAKE_CREATE_AUTHOR:-github-actions[bot]}"
      ;;
    PATCH)
      [ "${FAKE_GH_PATCH_FAIL:-0}" = 0 ] || exit 43
      printf '{"number":1,"state":"open","html_url":"https://example.test/pr/1","user":{"login":"%s"}}\n' "${FAKE_CREATE_AUTHOR:-github-actions[bot]}"
      ;;
    *) exit 44 ;;
  esac
elif [ "${1:-}" = pr ] && [ "${2:-}" = edit ]; then
  [ "${FAKE_LABEL_FAIL:-0}" = 0 ] || exit 45
else
  exit 46
fi
FAKE_GH

cat > "$FAKE_BIN/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail
git_args=("$@")
if [ "${FAKE_FETCH_FAIL:-0}" = 1 ] && [ "${1:-}" = fetch ]; then
  for argument in "$@"; do
    case "$argument" in
      +refs/heads/facet-updates:*) exit 51 ;;
    esac
  done
fi
if [ "${1:-}" = push ] && [ -n "${BARRIER_N:-}" ]; then
  mkdir -p "$BARRIER_DIR"
  : > "$BARRIER_DIR/ready.$$"
  while :; do
    set -- "$BARRIER_DIR"/ready.*
    [ "$#" -ge "$BARRIER_N" ] && break
    sleep 0.02
  done
  : > "$BARRIER_DIR/release"
  while [ ! -e "$BARRIER_DIR/release" ]; do sleep 0.02; done
  printf '%s ' "${git_args[@]}" > "$BARRIER_DIR/push.$$"
fi
exec "${REAL_GIT:?}" "${git_args[@]}"
FAKE_GIT

chmod +x "$FAKE_BIN/npx" "$FAKE_BIN/gh" "$FAKE_BIN/git"

write_project() {
  local root="$1"
  mkdir -p "$root/project/agents"
  printf '{"facets":{"demo":"1.0.0"}}\n' > "$root/project/facets.json"
  cat > "$root/project/facets.lock" <<'LOCK'
{
  "lockfileVersion": 0.3,
  "facets": {
    "demo": {
      "source": {"kind": "registry", "registry": "https://example.test"},
      "version": "1.0.0",
      "integrity": "sha256:demo",
      "assets": [{
        "scope": "project",
        "type": "agent",
        "name": "demo",
        "materialization": {"kind": "authored"},
        "files": [{
          "path": "agents/demo.md",
          "integrity": "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        }]
      }]
    }
  }
}
LOCK
  printf 'generated 0\n' > "$root/project/agents/demo.md"
}

new_fixture() {
  local name="$1"
  FIXTURE="$TEST_ROOT/$name"
  REMOTE="$FIXTURE/remote.git"
  SEED="$FIXTURE/seed"
  mkdir -p "$FIXTURE"
  "$REAL_GIT" init --bare -q "$REMOTE"
  "$REAL_GIT" init -q -b main "$SEED"
  write_project "$SEED"
  mkdir -p "$SEED/scripts"
  cp "$SCRIPT_DIR/facet-update.sh" "$SCRIPT_DIR/publish-update.sh" "$SEED/scripts/"
  (
    cd "$SEED"
    "$REAL_GIT" config user.name tester
    "$REAL_GIT" config user.email tester@example.test
    "$REAL_GIT" config commit.gpgsign false
    "$REAL_GIT" add project scripts
    "$REAL_GIT" commit -q -m base
    "$REAL_GIT" remote add origin "$REMOTE"
    "$REAL_GIT" push -q -u origin main
  )
  "$REAL_GIT" --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main
  printf '[[]]\n' > "$FIXTURE/pr-list.json"
  : > "$FIXTURE/gh.log"
}

fresh_clone() {
  local name="$1"
  local target="$FIXTURE/$name"
  "$REAL_GIT" clone -q "$REMOTE" "$target"
  (
    cd "$target"
    "$REAL_GIT" config user.name tester
    "$REAL_GIT" config user.email tester@example.test
    "$REAL_GIT" config commit.gpgsign false
  )
  printf '%s\n' "$target"
}

run_publish() {
  local clone="$1"
  local value="$2"
  shift 2
  (
    cd "$clone"
    env \
      PATH="$FAKE_BIN:$PATH" \
      REAL_GIT="$REAL_GIT" \
      FACET_WORKING_DIR=project \
      FACET_CLI_VERSION=0.33.1 \
      FACET_STRATEGY=latest \
      FACET_DRY_RUN=false \
      FACET_OUTPUT="$FIXTURE/output" \
      BRANCH=facet-updates \
      BASE=main \
      DEFAULT_BRANCH=main \
      COMMIT_MESSAGE='chore(facets): update facets' \
      PR_TITLE='chore(facets): update facets' \
      PR_AUTHOR='github-actions[bot]' \
      OPEN_PR=true \
      GITHUB_REPOSITORY=acme/widgets \
      GITHUB_REPOSITORY_OWNER=acme \
      FAKE_PR_LIST="$FIXTURE/pr-list.json" \
      FAKE_GH_LOG="$FIXTURE/gh.log" \
      FAKE_CREATE_AUTHOR='github-actions[bot]' \
      FAKE_VALUE="$value" \
      "$@" \
      bash "$clone/scripts/publish-update.sh"
  )
}

remote_tip() {
  "$REAL_GIT" --git-dir="$REMOTE" rev-parse "refs/heads/$1"
}

write_records() {
  local target="$1"
  shift
  node - "$target" "$@" <<'NODE'
const fs = require('fs')
const [target, ...specs] = process.argv.slice(2)
const records = specs.map(spec => {
  const [state, sha, author, headRepo, head, baseRepo, base, number] = spec.split('|')
  return {
    number: Number(number),
    state,
    html_url: "https://example.test/pr/" + number,
    user: { login: author },
    head: { sha, ref: head, repo: { full_name: headRepo } },
    base: { ref: base, repo: { full_name: baseRepo } }
  }
})
fs.writeFileSync(target, JSON.stringify([records]) + "\n")
NODE
}

valid_record() {
  local target="$1"
  local state="$2"
  local sha="$3"
  local author="${4:-github-actions[bot]}"
  write_records "$target" "$state|$sha|$author|acme/widgets|facet-updates|acme/widgets|main|1"
}

make_tip() {
  local kind="$1"
  local trailer_author="${2:-github-actions[bot]}"
  local builder="$FIXTURE/builder-$kind-$RANDOM"
  "$REAL_GIT" clone -q "$REMOTE" "$builder"
  (
    cd "$builder"
    "$REAL_GIT" config user.name 'github-actions[bot]'
    "$REAL_GIT" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
    "$REAL_GIT" config commit.gpgsign false
    "$REAL_GIT" checkout -q -B facet-updates origin/main
    case "$kind" in
      prior-not-ancestor)
        "$REAL_GIT" checkout -q --orphan unrelated
        "$REAL_GIT" rm -q -r --cached .
        write_project "$builder"
        mkdir -p scripts
        cp "$SCRIPT_DIR/facet-update.sh" "$SCRIPT_DIR/publish-update.sh" scripts/
        "$REAL_GIT" add .
        "$REAL_GIT" commit -q -m unrelated
        ;;
      merge)
        "$REAL_GIT" checkout -q -b side
        printf 'side\n' > side.txt
        "$REAL_GIT" add side.txt
        "$REAL_GIT" commit -q -m side
        "$REAL_GIT" checkout -q facet-updates
        ;;
    esac
    printf 'generated %s\n' "$kind" > project/agents/demo.md
    node - "project/facets.lock" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const lock = JSON.parse(fs.readFileSync(file, 'utf8'))
lock.facets.demo.version = '2.0.1'
fs.writeFileSync(file, JSON.stringify(lock, null, 2) + '\n')
NODE
    "$REAL_GIT" add project
    [ "$kind" != wrong-path ] || {
      printf 'outside\n' > outside.txt
      "$REAL_GIT" add outside.txt
    }
    [ "$kind" != human-email ] || "$REAL_GIT" config user.email human@example.test
    subject='chore(facets): update facets'
    [ "$kind" != wrong-subject ] || subject='wrong subject'
    {
      printf '%s\n\n' "$subject"
      case "$kind" in
        missing-trailer | email-only) ;;
        duplicate-trailer)
          printf 'Facet-Update-Generated: 1\nFacet-Update-Generated: 1\n'
          printf 'Facet-Update-PR-Author: %s\n' "$trailer_author"
          ;;
        *)
          printf 'Facet-Update-Generated: 1\n'
          printf 'Facet-Update-PR-Author: %s\n' "$trailer_author"
          ;;
      esac
    } > "$builder/message"
    "$REAL_GIT" commit -q -F "$builder/message"
    if [ "$kind" = two-commits ]; then
      printf 'second\n' >> project/agents/demo.md
      "$REAL_GIT" add project/agents/demo.md
      "$REAL_GIT" commit -q -F "$builder/message"
    elif [ "$kind" = merge ]; then
      "$REAL_GIT" merge -q --no-ff side -m 'merge proposal'
    fi
    "$REAL_GIT" push -q --force origin HEAD:refs/heads/facet-updates
  )
  remote_tip facet-updates
}

expect_rejected() {
  local label="$1"
  local clone="$2"
  shift 2
  local before
  before="$(remote_tip facet-updates)"
  if run_publish "$clone" 7 "$@" > "$FIXTURE/rejected.log" 2>&1; then
    fail_test "$label unexpectedly succeeded"
  fi
  assert_eq "$(remote_tip facet-updates)" "$before" "$label changed the remote"
  pass "$label refuses without a push"
}

new_fixture legacy-red
legacy="$(fresh_clone legacy)"
(
  cd "$legacy"
  "$REAL_GIT" checkout -q -b feature
  printf 'feature\n' > feature.txt
  "$REAL_GIT" add feature.txt
  "$REAL_GIT" commit -q -m feature
  feature_tip="$("$REAL_GIT" rev-parse HEAD)"
  "$REAL_GIT" checkout -q -B legacy-update
  printf 'legacy\n' > project/agents/demo.md
  printf 'dirty\n' > accidental.txt
  "$REAL_GIT" add -A -- .
  "$REAL_GIT" commit -q -m legacy
  [ "$("$REAL_GIT" rev-parse HEAD^)" = "$feature_tip" ] || exit 1
  "$REAL_GIT" show --name-only --format= HEAD | grep -Fx accidental.txt >/dev/null
  "$REAL_GIT" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
  printf 'email only\n' > project/agents/demo.md
  "$REAL_GIT" add project
  "$REAL_GIT" commit -q -m email-only
  [ "$("$REAL_GIT" log -1 --format=%ae)" = '41898282+github-actions[bot]@users.noreply.github.com' ]
  [ -z "$("$REAL_GIT" show -s --format='%(trailers:key=Facet-Update-Generated,valueonly)' HEAD)" ]
) || fail_test 'legacy defect reproduction did not turn red'
pass 'old inline behavior reproduces wrong parent, dirty inclusion, and email-only admission'

for dirty_kind in staged modified untracked untracked-lock; do
  new_fixture "dirty-$dirty_kind"
  clone="$(fresh_clone caller)"
  case "$dirty_kind" in
    staged) printf 'x\n' >> "$clone/project/facets.json"; (cd "$clone" && "$REAL_GIT" add project/facets.json) ;;
    modified) printf 'x\n' >> "$clone/project/facets.json" ;;
    untracked) printf 'x\n' > "$clone/untracked.txt" ;;
    untracked-lock)
      (cd "$clone" && "$REAL_GIT" rm -q project/facets.lock && "$REAL_GIT" commit -q -m 'remove lock')
      cp "$SEED/project/facets.lock" "$clone/project/facets.lock"
      ;;
  esac
  if run_publish "$clone" 1 > "$FIXTURE/dirty.log" 2>&1; then fail_test "$dirty_kind caller state accepted"; fi
  if "$REAL_GIT" --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/facet-updates; then fail_test "$dirty_kind pushed"; fi
  pass "dirty caller state is rejected: $dirty_kind"
done

new_fixture absent-from-feature
clone="$(fresh_clone caller)"
(
  cd "$clone"
  "$REAL_GIT" checkout -q -b feature
  printf 'feature\n' > feature.txt
  "$REAL_GIT" add feature.txt
  "$REAL_GIT" commit -q -m feature
)
run_publish "$clone" 2 > "$FIXTURE/run.log" 2>&1
tip="$(remote_tip facet-updates)"
assert_eq "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse "$tip^")" "$(remote_tip main)" 'proposal parent'
assert_contains "$FIXTURE/gh.log" 'api --method POST /repos/acme/widgets/pulls' 'create call'
pass 'nonbase trigger creates a one-commit proposal from the captured base'

new_fixture open-refresh
clone="$(fresh_clone first)"
run_publish "$clone" 1 > "$FIXTURE/first.log" 2>&1
old_tip="$(remote_tip facet-updates)"
valid_record "$FIXTURE/pr-list.json" open "$old_tip"
clone="$(fresh_clone second)"
run_publish "$clone" 2 > "$FIXTURE/second.log" 2>&1
[ "$(remote_tip facet-updates)" != "$old_tip" ] || fail_test 'open refresh did not replace tip'
assert_contains "$FIXTURE/gh.log" 'api --method PATCH /repos/acme/widgets/pulls/1' 'open refresh'
pass 'admitted open proposal refreshes through PATCH'

new_fixture api-mutations
clone="$(fresh_clone create-failure)"
if run_publish "$clone" 1 FAKE_GH_POST_FAIL=1 > "$FIXTURE/create-failure.log" 2>&1; then fail_test 'PR create API failure accepted'; fi
assert_contains "$FIXTURE/create-failure.log" 'pull request creation failed' 'create failure diagnostic'
pass 'PR create API failure is diagnostic and fatal'

new_fixture create-author
clone="$(fresh_clone caller)"
if run_publish "$clone" 1 FAKE_CREATE_AUTHOR=human > "$FIXTURE/create-author.log" 2>&1; then fail_test 'wrong created PR author accepted'; fi
assert_contains "$FIXTURE/create-author.log" 'created pull request author human does not match github-actions[bot]' 'created author diagnostic'
pass 'created PR author must equal explicit pr-author'

new_fixture edit-failure
clone="$(fresh_clone first)"
run_publish "$clone" 1 > "$FIXTURE/first.log" 2>&1
old_tip="$(remote_tip facet-updates)"
valid_record "$FIXTURE/pr-list.json" open "$old_tip"
clone="$(fresh_clone second)"
if run_publish "$clone" 2 FAKE_GH_PATCH_FAIL=1 > "$FIXTURE/edit-failure.log" 2>&1; then fail_test 'PR edit API failure accepted'; fi
assert_contains "$FIXTURE/edit-failure.log" 'pull request edit failed' 'edit failure diagnostic'
pass 'PR edit API failure is diagnostic and fatal'

new_fixture label-failure
clone="$(fresh_clone caller)"
run_publish "$clone" 1 LABELS=triage FAKE_LABEL_FAIL=1 > "$FIXTURE/label.log" 2>&1
assert_contains "$FIXTURE/label.log" "label 'triage' could not be applied, skipping" 'label failure diagnostic'
pass 'label API failure is diagnostic and nonfatal'

new_fixture closed-history
clone="$(fresh_clone first)"
run_publish "$clone" 1 > "$FIXTURE/first.log" 2>&1
first_tip="$(remote_tip facet-updates)"
valid_record "$FIXTURE/pr-list.json" closed "$first_tip"
clone="$(fresh_clone second)"
run_publish "$clone" 2 > "$FIXTURE/second.log" 2>&1
second_tip="$(remote_tip facet-updates)"
write_records "$FIXTURE/pr-list.json" \
  "closed|$first_tip|github-actions[bot]|acme/widgets|facet-updates|acme/widgets|main|1" \
  "open|$second_tip|github-actions[bot]|acme/widgets|facet-updates|acme/widgets|main|2"
clone="$(fresh_clone third)"
run_publish "$clone" 3 > "$FIXTURE/third.log" 2>&1
assert_contains "$FIXTURE/gh.log" 'api --method POST /repos/acme/widgets/pulls' 'closed recurrence create'
assert_contains "$FIXTURE/gh.log" 'api --method PATCH /repos/acme/widgets/pulls/2' 'history refresh'
pass 'closed recurrence creates, then multiple exact-ref history refreshes the sole open PR'

for principal in octocat 'renovate[bot]'; do
  new_fixture "principal-${principal//[^A-Za-z0-9]/-}"
  clone="$(fresh_clone caller)"
  run_publish "$clone" 4 PR_AUTHOR="$principal" FAKE_CREATE_AUTHOR="$principal" > "$FIXTURE/run.log" 2>&1
  pass "explicit PR principal fixture creates successfully: $principal"
done

for kind in human-email email-only missing-trailer duplicate-trailer wrong-subject wrong-path merge two-commits prior-not-ancestor; do
  new_fixture "tip-$kind"
  tip="$(make_tip "$kind")"
  valid_record "$FIXTURE/pr-list.json" open "$tip"
  clone="$(fresh_clone caller)"
  expect_rejected "generated-tip predicate: $kind" "$clone"
done

new_fixture metadata
tip="$(make_tip valid)"
clone_for_case() { fresh_clone "case-$1-$RANDOM"; }

printf '[[{"number":1}]]\n' > "$FIXTURE/pr-list.json"
expect_rejected 'malformed PR record' "$(clone_for_case malformed)"

write_records "$FIXTURE/pr-list.json" \
  "open|$tip|github-actions[bot]|acme/widgets|facet-updates|acme/widgets|main|1" \
  "closed|$tip|github-actions[bot]|acme/widgets|facet-updates|acme/widgets|main|2"
expect_rejected 'multiple exact-tip PR records' "$(clone_for_case multiple)"

for variant in wrong-repo wrong-head wrong-base wrong-author cross-repo; do
  repo=acme/widgets
  head=facet-updates
  base=main
  author='github-actions[bot]'
  case "$variant" in
    wrong-repo | cross-repo) repo=outsider/widgets ;;
    wrong-head) head=other ;;
    wrong-base) base=develop ;;
    wrong-author) author=human ;;
  esac
  write_records "$FIXTURE/pr-list.json" "open|$tip|$author|$repo|$head|acme/widgets|$base|1"
  expect_rejected "PR metadata: $variant" "$(clone_for_case "$variant")"
done

write_records "$FIXTURE/pr-list.json" \
  "open|$(remote_tip main)|github-actions[bot]|acme/widgets|facet-updates|acme/widgets|main|1" \
  "closed|$tip|github-actions[bot]|acme/widgets|facet-updates|acme/widgets|main|2"
expect_rejected 'open PR at older tip' "$(clone_for_case old-open)"

valid_record "$FIXTURE/pr-list.json" open "$tip"
expect_rejected 'changed token principal' "$(clone_for_case principal)" PR_AUTHOR='renovate[bot]'

valid_record "$FIXTURE/pr-list.json" open "$tip"
expect_rejected 'destination fetch failure' "$(clone_for_case fetch)" FAKE_FETCH_FAIL=1

valid_record "$FIXTURE/pr-list.json" open "$tip"
expect_rejected 'PR API failure' "$(clone_for_case api)" FAKE_GH_GET_FAIL=1

printf '{"not":"pages"}\n' > "$FIXTURE/pr-list.json"
expect_rejected 'pagination shape failure' "$(clone_for_case pagination)"

for race in advance delete-recreate; do
  new_fixture "race-$race"
  old_tip="$(make_tip valid)"
  valid_record "$FIXTURE/pr-list.json" open "$old_tip"
  race_sha="$(remote_tip main)"
  if [ "$race" = advance ]; then
    hidden="$(fresh_clone hidden)"
    (
      cd "$hidden"
      "$REAL_GIT" checkout -q -B hidden origin/main
      printf 'race\n' > race.txt
      "$REAL_GIT" add race.txt
      "$REAL_GIT" commit -q -m race
      "$REAL_GIT" rev-parse HEAD > "$FIXTURE/race-sha"
      "$REAL_GIT" push -q origin HEAD:refs/heads/race-candidate
    )
    race_sha="$(cat "$FIXTURE/race-sha")"
  fi
  if [ "$race" = advance ]; then
    hook_body="\"$REAL_GIT\" --git-dir=\"$REMOTE\" update-ref refs/heads/facet-updates \"$race_sha\""
  else
    hook_body="\"$REAL_GIT\" --git-dir=\"$REMOTE\" update-ref -d refs/heads/facet-updates
\"$REAL_GIT\" --git-dir=\"$REMOTE\" update-ref refs/heads/facet-updates \"$race_sha\""
  fi
  cat > "$FIXTURE/hook" <<HOOK
#!/usr/bin/env bash
set -euo pipefail
$hook_body
HOOK
  chmod +x "$FIXTURE/hook"
  clone="$(fresh_clone caller)"
  if run_publish "$clone" 7 FAKE_GH_HOOK="$FIXTURE/hook" FAKE_GH_HOOK_DONE="$FIXTURE/hook.done" > "$FIXTURE/rejected.log" 2>&1; then
    fail_test "remote $race race unexpectedly succeeded"
  fi
  assert_eq "$(remote_tip facet-updates)" "$race_sha" "remote $race race overwrote the competing tip"
  pass "remote $race race refuses without overwriting the competing tip"
done

for mode in no-change dry-run; do
  new_fixture "$mode"
  clone="$(fresh_clone caller)"
  if [ "$mode" = no-change ]; then
    run_publish "$clone" 1 FAKE_NPX_MODE=no-change > "$FIXTURE/run.log" 2>&1
  else
    run_publish "$clone" 1 FACET_DRY_RUN=true > "$FIXTURE/run.log" 2>&1
  fi
  if "$REAL_GIT" --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/facet-updates; then fail_test "$mode pushed"; fi
  [ ! -s "$FIXTURE/gh.log" ] || fail_test "$mode called GitHub API"
  pass "$mode performs no GitHub mutation"
done

new_fixture open-pr-false
clone="$(fresh_clone first)"
run_publish "$clone" 1 OPEN_PR=false > "$FIXTURE/first.log" 2>&1
tip="$(remote_tip facet-updates)"
valid_record "$FIXTURE/pr-list.json" open "$tip"
clone="$(fresh_clone second)"
expect_rejected 'open-pr=false existing branch reuse' "$clone" OPEN_PR=false
pass 'open-pr=false may create an absent branch'

run_concurrency() {
  local workers="$1"
  new_fixture "concurrency-$workers"
  first="$(fresh_clone first)"
  run_publish "$first" 1 > "$FIXTURE/first.log" 2>&1
  observed="$(remote_tip facet-updates)"
  valid_record "$FIXTURE/pr-list.json" open "$observed"
  barrier="$FIXTURE/barrier"
  mkdir -p "$barrier"
  pids=()
  for ((index = 1; index <= workers; index += 1)); do
    clone="$(fresh_clone "worker-$index")"
    (
      set +e
      run_publish "$clone" "$((index + 10))" BARRIER_N="$workers" BARRIER_DIR="$barrier" > "$FIXTURE/worker-$index.log" 2>&1
      printf '%s\n' "$?" > "$FIXTURE/status-$index"
    ) &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  successes=0
  failures=0
  for ((index = 1; index <= workers; index += 1)); do
    status="$(cat "$FIXTURE/status-$index")"
    if [ "$status" = 0 ]; then successes=$((successes + 1)); else failures=$((failures + 1)); fi
  done
  if [ "$successes" != 1 ]; then
    for ((index = 1; index <= workers; index += 1)); do
      echo "--- N=$workers worker=$index status=$(cat "$FIXTURE/status-$index") ---" >&2
      tail -20 "$FIXTURE/worker-$index.log" >&2
    done
  fi
  assert_eq "$successes" 1 "N=$workers successful pushes"
  assert_eq "$failures" "$((workers - 1))" "N=$workers rejected leases"
  set -- "$barrier"/push.*
  assert_eq "$#" "$workers" "N=$workers barrier arrivals"
  for push_file in "$barrier"/push.*; do
    push_args="$(cat "$push_file")"
    case "$push_args" in
      *"--force-with-lease=refs/heads/facet-updates:$observed"*"HEAD:refs/heads/facet-updates"*) ;;
      *) fail_test "N=$workers push lacked the captured explicit lease: $push_args" ;;
    esac
  done
  pass "N=$workers real wrapper processes release together: one lease wins, $((workers - 1)) reject"
}

run_concurrency 2
run_concurrency 20

echo "1..$PASS_COUNT"
