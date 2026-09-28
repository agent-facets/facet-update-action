#!/usr/bin/env bash

set -euo pipefail

STRATEGY="${FACET_STRATEGY:-latest}"
CLI_VERSION="${FACET_CLI_VERSION:-0.33.1}"
WORKING_DIR="${FACET_WORKING_DIR:-.}"
DRY_RUN="${FACET_DRY_RUN:-false}"
OUTPUT="${FACET_OUTPUT:-${GITHUB_OUTPUT:-}}"
BRANCH="${BRANCH:-facet-updates}"
BASE="${BASE:-}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-chore(facets): update facets}"
PR_TITLE="${PR_TITLE:-chore(facets): update facets}"
PR_AUTHOR="${PR_AUTHOR:-github-actions[bot]}"
LABELS="${LABELS:-}"
OPEN_PR="${OPEN_PR:-true}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
GITHUB_REPOSITORY_OWNER="${GITHUB_REPOSITORY_OWNER:-}"
BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
GENERATED_KEY='Facet-Update-Generated'
AUTHOR_KEY='Facet-Update-PR-Author'

fail() {
  echo "facet-update: $*" >&2
  exit 2
}

case "$DRY_RUN" in true | false) ;; *) fail "dry-run must be 'true' or 'false', got '${DRY_RUN}'" ;; esac
case "$OPEN_PR" in true | false) ;; *) fail "open-pr must be 'true' or 'false', got '${OPEN_PR}'" ;; esac
case "$STRATEGY" in latest | in-range) ;; *) fail "strategy must be 'latest' or 'in-range', got '${STRATEGY}'" ;; esac
[[ "$CLI_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid cli-version '${CLI_VERSION}'"
[[ "$PR_AUTHOR" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*(\[bot\])?$ ]] || fail "invalid pr-author '${PR_AUTHOR}'"
[[ "$GITHUB_REPOSITORY_OWNER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || fail "invalid repository owner"
[[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || fail "invalid repository"
[ "${GITHUB_REPOSITORY%%/*}" = "$GITHUB_REPOSITORY_OWNER" ] || fail "repository owner does not match repository"
[ -n "$DEFAULT_BRANCH" ] || fail 'default branch is required'
[ -n "$COMMIT_MESSAGE" ] && [[ "$COMMIT_MESSAGE" != *$'\n'* ]] || fail 'commit-message must be one non-empty line'
[ -n "$PR_TITLE" ] && [[ "$PR_TITLE" != *$'\n'* ]] || fail 'pr-title must be one non-empty line'
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || fail "invalid branch '${BRANCH}'"
EFFECTIVE_BASE="${BASE:-$DEFAULT_BRANCH}"
git check-ref-format --branch "$EFFECTIVE_BASE" >/dev/null 2>&1 || fail "invalid base '${EFFECTIVE_BASE}'"
[ "$BRANCH" != "$EFFECTIVE_BASE" ] || fail "branch '${BRANCH}' must differ from base"
[ "$BRANCH" != "$DEFAULT_BRANCH" ] || fail "refusing to push the default branch '${DEFAULT_BRANCH}'"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || fail 'not inside a git repository'
REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"
[ -d "$WORKING_DIR" ] || fail "working directory '${WORKING_DIR}' does not exist"
WORKING_ABS="$(cd "$WORKING_DIR" && pwd -P)"
case "$WORKING_ABS/" in "$REPO_ROOT/"*) ;; *) fail "working directory '${WORKING_DIR}' is outside the repository" ;; esac
if [ "$WORKING_ABS" = "$REPO_ROOT" ]; then
  WORKING_REL='.'
else
  WORKING_REL="${WORKING_ABS#"$REPO_ROOT"/}"
fi
LOCKFILE_REL="${WORKING_REL%/}/facets.lock"
[ "$WORKING_REL" = '.' ] && LOCKFILE_REL='facets.lock'

[ -z "$(git status --porcelain=v1 --untracked-files=all)" ] || fail 'caller repository must be completely clean'
git ls-files --error-unmatch -- "$LOCKFILE_REL" >/dev/null 2>&1 || fail "'${LOCKFILE_REL}' must be tracked before the update runs"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/publish-update.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
UPDATE_OUTPUT="$TMP/update-output"
PR_LIST="$TMP/pr-list.json"
PR_MATCH="$TMP/pr-match"
PR_RESPONSE="$TMP/pr-response.json"

fetch_base() {
  local refspec="+refs/heads/${EFFECTIVE_BASE}:refs/remotes/origin/${EFFECTIVE_BASE}"
  if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    git fetch --no-tags --unshallow origin "$refspec"
  else
    git fetch --no-tags origin "$refspec"
  fi
}

fetch_base || fail "could not fetch base '${EFFECTIVE_BASE}'"
BASE_SHA="$(git rev-parse "refs/remotes/origin/${EFFECTIVE_BASE}^{commit}")"

set +e
REMOTE_LINE="$(git ls-remote --exit-code --heads origin "refs/heads/${BRANCH}" 2>"$TMP/ls-remote.err")"
REMOTE_STATUS=$?
set -e
case "$REMOTE_STATUS" in
  0)
    [ "$(printf '%s\n' "$REMOTE_LINE" | wc -l | tr -d ' ')" = 1 ] || fail "ambiguous remote branch '${BRANCH}'"
    EXPECTED_TIP="${REMOTE_LINE%%[[:space:]]*}"
    [[ "$EXPECTED_TIP" =~ ^[0-9a-f]{40}$ ]] || fail "invalid remote tip for '${BRANCH}'"
    ;;
  2) EXPECTED_TIP='' ;;
  *) cat "$TMP/ls-remote.err" >&2; fail "could not observe remote branch '${BRANCH}'" ;;
esac

validate_pr_records() {
  node - "$PR_LIST" "$GITHUB_REPOSITORY" "$GITHUB_REPOSITORY_OWNER" "$BRANCH" "$EFFECTIVE_BASE" "$EXPECTED_TIP" "$PR_AUTHOR" > "$PR_MATCH" <<'NODE'
const fs = require('fs')
const [file, repository, owner, branch, base, expectedTip, author] = process.argv.slice(2)
const bad = message => { throw new Error(message) }
const object = (value, path) => value && typeof value === 'object' && !Array.isArray(value) ? value : bad(`${path} must be an object`)
const string = (value, path) => typeof value === 'string' ? value : bad(`${path} must be a string`)
const number = (value, path) => Number.isInteger(value) ? value : bad(`${path} must be an integer`)
try {
  const pages = JSON.parse(fs.readFileSync(file, 'utf8'))
  if (!Array.isArray(pages) || pages.some(page => !Array.isArray(page))) bad('response must be an array of pages')
  const records = pages.flat()
  for (let index = 0; index < records.length; index += 1) {
    const record = object(records[index], `record[${index}]`)
    number(record.number, `record[${index}].number`)
    string(record.state, `record[${index}].state`)
    if (!['open', 'closed'].includes(record.state)) bad(`record[${index}].state is invalid`)
    string(record.html_url, `record[${index}].html_url`)
    const head = object(record.head, `record[${index}].head`)
    const headRepo = object(head.repo, `record[${index}].head.repo`)
    const baseRecord = object(record.base, `record[${index}].base`)
    const baseRepo = object(baseRecord.repo, `record[${index}].base.repo`)
    const user = object(record.user, `record[${index}].user`)
    if (string(headRepo.full_name, 'head.repo.full_name') !== repository ||
        string(baseRepo.full_name, 'base.repo.full_name') !== repository ||
        string(head.ref, 'head.ref') !== branch || string(baseRecord.ref, 'base.ref') !== base) {
      bad(`record[${index}] is cross-repository or has the wrong head/base ref`)
    }
    string(head.sha, `record[${index}].head.sha`)
    string(user.login, `record[${index}].user.login`)
  }
  const open = records.filter(record => record.state === 'open')
  if (open.length > 1) bad('more than one open pull request record')
  const exact = records.filter(record => record.head.sha === expectedTip)
  if (exact.length !== 1) bad(`expected exactly one record at ${expectedTip}, found ${exact.length}`)
  if (open.length === 1 && open[0].head.sha !== expectedTip) bad('open pull request points at an older tip')
  if (exact[0].user.login !== author) bad(`pull request author ${exact[0].user.login} does not match ${author}`)
  process.stdout.write(`${exact[0].state}\t${exact[0].number}\t${exact[0].html_url}\n`)
} catch (error) {
  process.stderr.write(`facet-update: unsafe pull request metadata: ${error.message}\n`)
  process.exit(1)
}
NODE
}

PR_STATE=''
PR_NUMBER=''
PR_URL=''
if [ -n "$EXPECTED_TIP" ]; then
  [ "$OPEN_PR" = true ] || fail "existing branch '${BRANCH}' cannot be refreshed with open-pr=false"
  if ! gh api --method GET "/repos/${GITHUB_REPOSITORY}/pulls" \
    -f state=all \
    -f head="${GITHUB_REPOSITORY_OWNER}:${BRANCH}" \
    -f base="$EFFECTIVE_BASE" \
    -F per_page=100 --paginate --slurp > "$PR_LIST"; then
    fail 'pull request lookup failed'
  fi
  validate_pr_records || exit $?
  IFS=$'\t' read -r PR_STATE PR_NUMBER PR_URL < "$PR_MATCH"

  git fetch --no-tags origin "+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}" || fail "could not fetch observed branch '${BRANCH}'"
  FETCHED_TIP="$(git rev-parse "refs/remotes/origin/${BRANCH}^{commit}")"
  [ "$FETCHED_TIP" = "$EXPECTED_TIP" ] || fail "remote branch '${BRANCH}' moved after observation"

  read -r -a PARENTS <<< "$(git rev-list --parents -n 1 "$EXPECTED_TIP")"
  [ "${#PARENTS[@]}" = 2 ] || fail "remote tip '${EXPECTED_TIP}' is not exactly one generated commit"
  PRIOR_PARENT="${PARENTS[1]}"
  git merge-base --is-ancestor "$PRIOR_PARENT" "$BASE_SHA" || fail 'prior generated parent is not an ancestor of the resolved base'
  [ "$(git show -s --format=%s "$EXPECTED_TIP")" = "$COMMIT_MESSAGE" ] || fail 'remote tip subject does not match commit-message'
  [ "$(git show -s --format='%ae%n%ce' "$EXPECTED_TIP")" = "$BOT_EMAIL"$'\n'"$BOT_EMAIL" ] || fail 'remote tip author/committer email is not the action bot email'
  [ "$(git show -s --format="%(trailers:key=${GENERATED_KEY},valueonly)" "$EXPECTED_TIP")" = 1 ] || fail "remote tip must contain exactly one '${GENERATED_KEY}: 1' trailer"
  [ "$(git show -s --format="%(trailers:key=${AUTHOR_KEY},valueonly)" "$EXPECTED_TIP")" = "$PR_AUTHOR" ] || fail "remote tip must contain exactly one '${AUTHOR_KEY}: ${PR_AUTHOR}' trailer"
  git ls-tree -r --name-only "$EXPECTED_TIP" -- "$LOCKFILE_REL" | grep -Fx -- "$LOCKFILE_REL" >/dev/null || fail "remote tip does not contain tracked '${LOCKFILE_REL}'"
  while IFS= read -r -d '' changed_path; do
    if [ "$WORKING_REL" != '.' ] && [[ "$changed_path" != "$WORKING_REL/"* ]]; then
      fail "remote tip changes path outside '${WORKING_REL}': ${changed_path}"
    fi
  done < <(git diff-tree --no-commit-id --name-only -r -z "$EXPECTED_TIP")
fi

git checkout -B "$BRANCH" "$BASE_SHA"
git config user.name 'github-actions[bot]'
git config user.email "$BOT_EMAIL"

FACET_STRATEGY="$STRATEGY" \
FACET_CLI_VERSION="$CLI_VERSION" \
FACET_WORKING_DIR="$WORKING_REL" \
FACET_DRY_RUN="$DRY_RUN" \
FACET_OUTPUT="$UPDATE_OUTPUT" \
  bash "$(dirname "$0")/facet-update.sh"

cat "$UPDATE_OUTPUT"
[ -z "$OUTPUT" ] || cat "$UPDATE_OUTPUT" >> "$OUTPUT"
UPDATED="$(sed -n 's/^updated=//p' "$UPDATE_OUTPUT")"
COUNT="$(sed -n 's/^count=//p' "$UPDATE_OUTPUT")"
SUMMARY_B64="$(sed -n 's/^summary=//p' "$UPDATE_OUTPUT")"
[ "$UPDATED" = true ] || {
  [ -z "$OUTPUT" ] || echo 'pr-url=' >> "$OUTPUT"
  exit 0
}
[ "$DRY_RUN" = false ] || fail 'facet-update.sh reported a change during dry-run'

git add -A -- "$WORKING_REL"
git diff --cached --quiet && fail 'facets moved but nothing is staged'
while IFS= read -r -d '' staged_path; do
  if [ "$WORKING_REL" != '.' ] && [[ "$staged_path" != "$WORKING_REL/"* ]]; then
    fail "staged path outside '${WORKING_REL}': ${staged_path}"
  fi
done < <(git diff --cached --name-only -z)
git ls-files --error-unmatch -- "$LOCKFILE_REL" >/dev/null 2>&1 || fail "staged update lost tracked '${LOCKFILE_REL}'"

BODY="$(printf '%s' "$SUMMARY_B64" | base64 --decode)"
{
  printf '%s\n\n%s\n\n' "$COMMIT_MESSAGE" "$BODY"
  printf '%s: 1\n%s: %s\n' "$GENERATED_KEY" "$AUTHOR_KEY" "$PR_AUTHOR"
} > "$TMP/commit-message"
git commit --file="$TMP/commit-message"
[ "$(git rev-parse HEAD^)" = "$BASE_SHA" ] || fail 'generated tip parent is not the resolved base'

if [ -n "$EXPECTED_TIP" ]; then
  git push --force-with-lease="refs/heads/${BRANCH}:${EXPECTED_TIP}" origin "HEAD:refs/heads/${BRANCH}"
else
  git push --force-with-lease="refs/heads/${BRANCH}:" origin "HEAD:refs/heads/${BRANCH}"
fi

if [ "$OPEN_PR" = false ]; then
  [ -z "$OUTPUT" ] || echo 'pr-url=' >> "$OUTPUT"
  exit 0
fi

SUMMARY="$(printf '%s' "$SUMMARY_B64" | base64 --decode)"
if [ "$STRATEGY" = latest ]; then
  NOTE='Each facet was moved to its newest release, including exactly pinned entries.'
else
  NOTE='Only releases satisfying the existing facets.json range were selected.'
fi
PR_BODY="$(printf '%s\n\n%s\n\n%s\n' "${COUNT} facet(s) changed." "$SUMMARY" "$NOTE")"

if [ "$PR_STATE" = open ]; then
  gh api --method PATCH "/repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" \
    -f title="$PR_TITLE" -f body="$PR_BODY" > "$PR_RESPONSE" || fail 'pull request edit failed'
else
  gh api --method POST "/repos/${GITHUB_REPOSITORY}/pulls" \
    -f head="$BRANCH" -f base="$EFFECTIVE_BASE" -f title="$PR_TITLE" -f body="$PR_BODY" > "$PR_RESPONSE" || fail 'pull request creation failed'
  PR_URL="$(node - "$PR_RESPONSE" "$PR_AUTHOR" <<'NODE'
const fs = require('fs')
const [file, author] = process.argv.slice(2)
try {
  const response = JSON.parse(fs.readFileSync(file, 'utf8'))
  if (!response || typeof response !== 'object' || Array.isArray(response)) throw new Error('response must be an object')
  if (!response.user || typeof response.user.login !== 'string') throw new Error('response.user.login must be a string')
  if (response.user.login !== author) throw new Error(`created pull request author ${response.user.login} does not match ${author}`)
  if (typeof response.html_url !== 'string') throw new Error('response.html_url must be a string')
  process.stdout.write(response.html_url)
} catch (error) {
  process.stderr.write(`facet-update: invalid pull request creation response: ${error.message}\n`)
  process.exit(1)
}
NODE
)" || exit $?
fi

if [ -n "$LABELS" ]; then
  IFS=',' read -r -a PARSED_LABELS <<< "$LABELS"
  for label in "${PARSED_LABELS[@]}"; do
    trimmed="${label//[[:space:]]/}"
    [ -z "$trimmed" ] && continue
    gh pr edit "$PR_URL" --add-label "$trimmed" || echo "facet-update: label '${trimmed}' could not be applied, skipping" >&2
  done
fi

[ -z "$OUTPUT" ] || echo "pr-url=${PR_URL}" >> "$OUTPUT"
echo "facet-update: ${PR_URL}"
