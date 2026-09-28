#!/usr/bin/env bash
# shellcheck disable=SC2016 # Regexes and embedded Ruby must remain literal.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readme="$repo_root/README.md"
action="$repo_root/action.yml"
example="$repo_root/examples/facet-update.yml"

fail() { echo "docs contract: $*" >&2; exit 1; }

section() {
  local heading="$1"
  awk -v heading="## $heading" '$0 == heading { found = 1; next } found && /^## / { exit } found { print } END { if (!found) exit 1 }' "$readme"
}

require_section_claim() {
  local heading="$1" claim="$2" pattern="$3"
  section "$heading" | rg -q -- "$pattern" || fail "$heading missing claim: $claim"
}

ruby -ryaml -e '
  action = YAML.load_file(ARGV[0]); example = YAML.load_file(ARGV[1])
  { "cli-version" => "0.33.1", "branch" => "facet-updates", "pr-author" => "github-actions[bot]" }.each { |key, value| abort("action default #{key} differs") unless action.dig("inputs", key, "default").to_s == value }
  abort("action updated output differs") unless action.dig("outputs", "updated", "value") == "${{ steps.update.outputs.updated }}"
  abort("action count output differs") unless action.dig("outputs", "count", "value") == "${{ steps.update.outputs.count }}"
  abort("example concurrency must use repository plus destination branch") unless example.dig("concurrency", "group") == "facet-update-${{ github.repository }}-facet-updates"
  abort("example must keep active updates") unless example.dig("concurrency", "cancel-in-progress") == false
  steps = example.dig("jobs", "update", "steps")
  action_step = steps.find { |step| step["uses"] == "agent-facets/facet-update-action@v1" }
  abort("example must use action @v1") unless action_step
  abort("example CLI pin differs") unless action_step.dig("with", "cli-version").to_s == "0.33.1"
' "$action" "$example" || fail "YAML defaults or example wiring differs"

expected_dry_run=$'facet-update: updated=false count=0\nupdated=false\ncount=0\nsummary='
actual_dry_run="$(awk '/^```text$/{inside=1; next} inside && /^```$/{exit} inside{print}' < <(section Outputs))"
[[ "$actual_dry_run" == "$expected_dry_run" ]] || fail 'Outputs missing exact four-line dry-run result'

require_section_claim Requirements 'hosted Ubuntu runner and tool assumptions' 'GitHub-hosted Ubuntu runner with Bash, Git, Node/npm \(`npx`\), and the GitHub CLI'
require_section_claim Requirements 'network access to GitHub and npm' 'outbound network access to GitHub.*npm registry'
require_section_claim Permissions 'repository Actions PR setting' 'Actions settings must also allow GitHub Actions to create pull requests'
require_section_claim Permissions 'pr-author validates ownership' '`pr-author` is an assertion'
require_section_claim Permissions 'default-token checks require approval' 'approval-required workflow state'
require_section_claim Permissions 'App or PAT checks can begin automatically' 'App installation token or PAT can create events that start checks automatically'
require_section_claim Permissions 'custom credential reaches checkout and action' 'secrets.FACET_UPDATE_TOKEN'
require_section_claim 'Supply chain' 'CLI is exactly pinned' "cli-version: '0.33.1'"
require_section_claim 'Supply chain' 'action and CLI are supply-chain pins' 'Pin both executable dependencies'
require_section_claim 'Update branch' 'structural provenance is non-cryptographic' 'not cryptographic proof'
require_section_claim 'Update branch' 'existing branch cannot refresh with open-pr false' 'cannot refresh an existing update branch'
require_section_claim 'Update branch' 'branch and concurrency suffix must match' 'last segment of `concurrency.group` to the same literal'
require_section_claim Pinning 'full SHA is strongest action pin' 'Full commit SHA'
require_section_claim Pinning 'immutable patch tag policy' '`v1.0.0`'
require_section_claim Pinning 'movable major tag policy' '`v1`'

echo 'docs contract: PASS'
