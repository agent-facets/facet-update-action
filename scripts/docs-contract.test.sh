#!/usr/bin/env bash
# shellcheck disable=SC2016 # Regexes and embedded Ruby must remain literal.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readme="${DOCS_CONTRACT_README:-$repo_root/README.md}"
action="${DOCS_CONTRACT_ACTION:-$repo_root/action.yml}"
example="${DOCS_CONTRACT_EXAMPLE:-$repo_root/examples/facet-update.yml}"
workflow="${DOCS_CONTRACT_WORKFLOW:-$repo_root/.github/workflows/test.yml}"
publisher="${DOCS_CONTRACT_PUBLISHER:-$repo_root/scripts/publish-update.sh}"

fail() { echo "docs contract: $*" >&2; exit 1; }

ruby -ryaml - "$readme" "$action" "$example" "$workflow" "$publisher" <<'RUBY' || fail 'semantic README/YAML contract differs'
readme_path, action_path, example_path, workflow_path, publisher_path = ARGV
readme = File.read(readme_path)
action = YAML.load_file(action_path)
example = YAML.load_file(example_path)
workflow = YAML.load_file(workflow_path)
publisher = File.read(publisher_path)

def reject(message)
  warn "docs contract: #{message}"
  exit 1
end

def section(document, heading)
  match = document.match(/^## #{Regexp.escape(heading)}\n(?<body>.*?)(?=^## |\z)/m)
  reject("missing README section: #{heading}") unless match
  match[:body]
end

def require_claim(body, heading, claim, literal)
  reject("#{heading} missing claim: #{claim}") unless body.include?(literal)
end

def fenced_blocks(body, language)
  body.scan(/^```#{Regexp.escape(language)}\n(.*?)^```$/m).flatten
end

def yaml_blocks(document, heading)
  blocks = fenced_blocks(section(document, heading), 'yaml')
  reject("#{heading} missing fenced YAML example") if blocks.empty?
  blocks.map { |block| YAML.safe_load(block, aliases: false) }
end

def table_rows(body)
  rows = body.lines.each_with_object([]) do |line, found|
    next unless line.start_with?('|')
    cells = line.split('|')[1...-1].map { |cell| cell.strip }
    next if cells.empty? || cells.all? { |cell| cell.match?(/\A-+\z/) }
    found << cells
  end
  rows.drop(1)
end

def normalized_cell(value)
  value.to_s.sub(/\A`/, '').sub(/`\z/, '')
end

inputs = action.fetch('inputs')
adapter_input = inputs.fetch('adapter')
reject('action adapter input must be required without a default') unless adapter_input['required'] == true && !adapter_input.key?('default')
action_env = action.fetch('runs').fetch('steps').fetch(0).fetch('env')
reject('action adapter env wiring missing') unless action_env['FACET_ADAPTER'] == '${{ inputs.adapter }}'
reject('publisher adapter env read missing') unless publisher.include?('ADAPTER="${FACET_ADAPTER-}"')
reject('publisher adapter validation must precede repository discovery') unless
  publisher.index('case "${ADAPTER%%@*}"') && publisher.index('[[ "$ADAPTER" =~') &&
  publisher.index('[[ "$ADAPTER" =~') < publisher.index('REPO_ROOT="$(git rev-parse --show-toplevel')
bootstrap = 'npx --yes "agent-facets@${CLI_VERSION}" adapter add "$ADAPTER" < /dev/null'
update = 'bash "$(dirname "$0")/facet-update.sh"'
reject('publisher must bootstrap pinned adapter once before update') unless
  publisher.scan(bootstrap).length == 1 && publisher.index(bootstrap) < publisher.index(update)
outputs = action.fetch('outputs')
fenced_blocks(readme, 'yaml').each_with_index do |block, index|
  YAML.safe_load(block, aliases: false)
rescue Psych::SyntaxError => error
  reject("README fenced YAML example #{index + 1} is invalid: #{error.message.lines.first.strip}")
end
input_rows = table_rows(section(readme, 'Inputs')).to_h do |row|
  [normalized_cell(row.fetch(0)), normalized_cell(row.fetch(1))]
end
output_rows = table_rows(section(readme, 'Outputs')).to_h do |row|
  [normalized_cell(row.fetch(0)), row.fetch(1)]
end

reject('README input names differ from action.yml') unless input_rows.keys.sort == inputs.keys.sort
reject('README output names differ from action.yml') unless output_rows.keys.sort == outputs.keys.sort

display_default = lambda do |name, value|
  return 'repo default' if name == 'base' && value.to_s.empty?
  return 'none' if name == 'labels' && value.to_s.empty?
  return 'github.token' if name == 'token' && value == '${{ github.token }}'
  value.to_s
end
inputs.each do |name, definition|
  expected = definition.key?('default') ? display_default.call(name, definition.fetch('default')) : 'required'
  reject("Inputs default #{name} differs from action.yml") unless input_rows.fetch(name) == expected
end
outputs.each do |name, definition|
  expected_value = "${{ steps.update.outputs.#{name} }}"
  reject("action.yml output #{name} wiring differs") unless definition.fetch('value') == expected_value
end
reject('Outputs updated semantics differ') unless output_rows.fetch('updated').include?('non-dry-run update changed at least one facet') && output_rows.fetch('updated').include?('dry runs always report `"false"`')
reject('Outputs count semantics differ') unless output_rows.fetch('count').include?('upgrades, downgrades, additions, and removals') && output_rows.fetch('count').include?('not a proposed-change count')
reject('Outputs pr-url semantics differ') unless output_rows.fetch('pr-url').include?('opened or refreshed') && output_rows.fetch('pr-url').include?('empty when none was')

quickstart = yaml_blocks(readme, 'Quickstart').fetch(0)
quickstart_steps = quickstart.dig('jobs', 'update', 'steps') || []
quickstart_action = quickstart_steps.find { |step| step['uses']&.start_with?('agent-facets/facet-update-action@') }
reject('Quickstart action step missing') unless quickstart_action
reject('Quickstart action ref must be exactly @v1') unless quickstart_action['uses'] == 'agent-facets/facet-update-action@v1'
reject('Quickstart CLI pin differs from action.yml') unless quickstart_action.dig('with', 'cli-version').to_s == inputs.dig('cli-version', 'default').to_s
reject('Quickstart contents permission must be write') unless quickstart.dig('permissions', 'contents') == 'write'
reject('Quickstart pull-requests permission must be write') unless quickstart.dig('permissions', 'pull-requests') == 'write'

def assert_branch_concurrency(workflow, action_default, label)
  action_step = workflow.dig('jobs', 'update', 'steps')&.find { |step| step['uses'] == 'agent-facets/facet-update-action@v1' }
  reject("#{label} action step must use exactly @v1") unless action_step
  branch = action_step.dig('with', 'branch') || action_default
  group = workflow.dig('concurrency', 'group')
  prefix = 'facet-update-${{ github.repository }}-'
  reject("#{label} concurrency must start with repository prefix") unless group&.start_with?(prefix)
  reject("#{label} branch must equal concurrency suffix") unless branch == group.delete_prefix(prefix)
  reject("#{label} must not cancel an in-progress update") unless workflow.dig('concurrency', 'cancel-in-progress') == false
  action_step
end

quickstart_action = assert_branch_concurrency(quickstart, inputs.dig('branch', 'default'), 'Quickstart')
example_action = assert_branch_concurrency(example, inputs.dig('branch', 'default'), 'standalone example')
reject('standalone example CLI pin differs from action.yml') unless example_action.dig('with', 'cli-version').to_s == inputs.dig('cli-version', 'default').to_s

custom_branch = yaml_blocks(readme, 'Update branch').fetch(0)
custom_branch_action = assert_branch_concurrency(custom_branch, inputs.dig('branch', 'default'), 'custom-branch example')

credential_example = yaml_blocks(readme, 'Permissions').fetch(0)
checkout_step = credential_example.find { |step| step['uses'] == 'actions/checkout@v7' }
credential_action = credential_example.find { |step| step['uses'] == 'agent-facets/facet-update-action@v1' }
reject('Permissions custom credential example missing checkout') unless checkout_step
reject('Permissions custom credential example missing action') unless credential_action
checkout_token = checkout_step.dig('with', 'token')
action_token = credential_action.dig('with', 'token')
reject('Permissions custom credential must be supplied to checkout and action') unless checkout_token == '${{ secrets.FACET_UPDATE_TOKEN }}' && action_token == checkout_token

adapter_pattern = /\A(?:claude-code|opencode|codex)@(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z/
{
  'Quickstart' => quickstart_action,
  'custom-branch example' => custom_branch_action,
  'Permissions custom credential example' => credential_action,
  'standalone example' => example_action
}.each do |label, step|
  reject("#{label} must pin an exact first-party adapter") unless step.dig('with', 'adapter').to_s.match?(adapter_pattern)
end

published_steps = workflow.fetch('jobs').fetch('published-cli').fetch('steps')
def require_published_adapter_before_install(steps, step_name, label)
  install_step = steps.find { |step| step['name'] == step_name }
  reject("#{label} install step missing") unless install_step
  lines = install_step.fetch('run').lines.map(&:strip)
  adapter = 'npx --yes "agent-facets@${FACET_CLI_PIN}" adapter add codex@0.9.0 < /dev/null'
  install = 'npx --yes "agent-facets@${FACET_CLI_PIN}" install --accept-mcp < /dev/null'
  reject("#{label} must configure pinned Codex adapter before install") unless
    lines.count(adapter) == 1 && lines.count(install) == 1 && lines.index(adapter) < lines.index(install)
end

require_published_adapter_before_install(published_steps, 'Install with the published CLI', 'published CLI fixture')
dry_run_step = published_steps.find { |step| step['name'] == 'Preserve bytes during dry-run' }
reject('published CLI dry-run step missing') unless dry_run_step
dry_run_lines = dry_run_step.fetch('run').lines.map(&:strip)
result_line = 'facet-update: updated=false count=0'
required_dry_run_commands = {
  'valid prior installation restore' => 'git restore --source=HEAD^ --worktree -- .',
  'complete tracked file manifest' => 'git ls-tree -r -z --name-only HEAD^ | LC_ALL=C sort -z | xargs -0 -r sha256sum -- > /tmp/published-cli.sha',
  'nonempty tracked file manifest' => 'test -s /tmp/published-cli.sha',
  'exactly one result line' => %q{result_count="$(grep -Fxc -- 'facet-update: updated=false count=0' /tmp/dry-run.log || true)"},
  'result count check' => %q{[ "$result_count" = 1 ] || { echo "expected one dry-run result line, found $result_count"; exit 1; }},
  'final console line' => %q{[ "$(tail -n 1 /tmp/dry-run.log)" = 'facet-update: updated=false count=0' ] || { echo 'dry-run result was not the final console line'; exit 1; }},
  'exact machine output' => %q{printf 'updated=false\ncount=0\nsummary=\n' > /tmp/dry-run.expected},
  'machine output comparison' => 'cmp /tmp/dry-run.expected /tmp/dry-run.out',
  'byte identity' => 'sha256sum --check --status /tmp/published-cli.sha'
}
required_dry_run_commands.each do |claim, command|
  reject("published CLI dry-run missing #{claim}") unless dry_run_lines.include?(command)
end
restore_index = dry_run_lines.index(required_dry_run_commands.fetch('valid prior installation restore'))
manifest = required_dry_run_commands.fetch('complete tracked file manifest')
manifest_index = dry_run_lines.index(manifest)
dry_run_index = dry_run_lines.index { |line| line.include?('FACET_DRY_RUN=true FACET_OUTPUT=/tmp/dry-run.out') }
reject('published CLI dry-run must restore and hash prior installation before execution') unless dry_run_index && restore_index < manifest_index && manifest_index < dry_run_index
reject('published CLI dry-run must hash only the complete tracked file manifest') unless dry_run_lines.select { |line| line.end_with?('> /tmp/published-cli.sha') } == [manifest]
reject('published CLI dry-run must not corrupt installed lock entries') if dry_run_lines.any? { |line| line.include?('entry.version = "1.0.0"') }
reject('published CLI dry-run must allow preceding diagnostics') if dry_run_lines.any? { |line| line.match?(/\Acmp .*\/tmp\/dry-run\.log\z/) }

action_steps = workflow.fetch('jobs').fetch('action').fetch('steps')
action_checkout = action_steps.first
reject('action CI must use a full-depth checkout before pushing fixture to bare origin') unless action_checkout['uses'] == 'actions/checkout@v7' && action_checkout.dig('with', 'fetch-depth') == 0
fixture_step = action_steps.find { |step| step['name'] == 'Build and publish a local fixture base' }
reject('action CI tracked fixture setup missing') unless fixture_step
require_published_adapter_before_install(action_steps, 'Build and publish a local fixture base', 'action CI fixture')
fixture_run = fixture_step.fetch('run')
%w[git\ add\ -A\ --\ fixture git\ init\ --bare git\ remote\ set-url\ origin git\ push\ origin\ HEAD:refs/heads/ci-fixture-base git\ ls-files\ --error-unmatch].each do |command|
  reject("action CI fixture setup missing #{command}") unless fixture_run.include?(command)
end
reject('action CI fixture commit missing') unless fixture_run.include?("git -c commit.gpgsign=false commit -m 'test: add tracked facet fixture'")
reject('action CI fixture must be clean') unless fixture_run.include?('[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]')
action_step = action_steps.find { |step| step['uses'] == './' }
reject('action CI composite invocation missing') unless action_step
home = '${{ runner.temp }}/facet-update-action-${{ github.run_id }}-${{ github.run_attempt }}'
pre_step = action_steps.find { |step| step['name'] == 'Assert action adapter home starts absent' }
reject('action CI missing pre-action adapter-home absence assertion') unless pre_step
reject('action CI adapter home must be unique and shared across assertions and invocation') unless
  [pre_step, action_step, action_steps.find { |step| step['name'] == 'Dry-run reports no change and writes nothing' }].all? { |step| step && step.dig('env', 'FACET_DIR') == home }
reject('action CI must assert adapter home absent without preseed') unless pre_step.fetch('run').lines.map(&:strip) == ['set -euo pipefail', 'test ! -e "$FACET_DIR"']
reject('action CI must assert absence before composite invocation') unless action_steps.index(pre_step) < action_steps.index(action_step)
reject('action CI must not preseed the action adapter home') if action_steps[0...action_steps.index(pre_step)].any? { |step| step.to_s.include?('FACET_DIR') || step.to_s.include?(home) }
reject('action CI must select exact Codex adapter') unless action_step.dig('with', 'adapter') == 'codex@0.9.0'
reject('action CI must select fixture remote base') unless action_step.dig('with', 'base') == 'ci-fixture-base'
reject('action CI must select tracked fixture directory') unless action_step.dig('with', 'working-directory') == 'fixture'
reject('action CI must run dry-run') unless action_step.dig('with', 'dry-run').to_s == 'true'
output_step = action_steps.find { |step| step['name'] == 'Dry-run reports no change and writes nothing' }
reject('action CI output assertion missing') unless output_step
reject('action CI must assert selected adapter presence afterward') unless
  action_steps.index(output_step) > action_steps.index(action_step) &&
  output_step.fetch('run').include?('test -d "$FACET_DIR/adapters/codex"')
reject('action CI must not assert undeclared summary output') if output_step.fetch('env').key?('SUMMARY') || output_step.fetch('run').include?('$SUMMARY')

output_literal = dry_run_lines.find { |line| line.start_with?("printf '") && line.end_with?(' > /tmp/dry-run.expected') }
reject('published CLI dry-run expected machine-output literal missing') unless output_literal
machine_lines = output_literal.delete_prefix("printf '").delete_suffix("' > /tmp/dry-run.expected").gsub('\\n', "\n")
expected_dry_run = result_line + "\n" + machine_lines
output_text_blocks = fenced_blocks(section(readme, 'Outputs'), 'text')
reject('Outputs missing final console result plus three machine lines') unless output_text_blocks == [expected_dry_run]
require_claim(section(readme, 'Outputs'), 'Outputs', 'result is the final console line, with preceding diagnostics allowed', 'The CLI may print diagnostics before the result line')
require_claim(section(readme, 'Outputs'), 'Outputs', 'machine output file has three exact lines', 'three exact machine-output file lines')

requirements = section(readme, 'Requirements')
require_claim(requirements, 'Requirements', 'clean tree is insufficient without tracked facets.lock', 'The action rejects a missing, ignored, or untracked lockfile: a clean working tree alone is not evidence that the lockfile records the proposed versions.')
require_claim(requirements, 'Requirements', 'hosted Ubuntu runner and tool assumptions', 'GitHub-hosted Ubuntu runner with Bash, Git, Node/npm (`npx`), and the GitHub CLI available')
require_claim(requirements, 'Requirements', 'network access to GitHub and npm', 'outbound network access to GitHub (checkout, push, and pull-request API calls) and the npm registry')

update_branch = section(readme, 'Update branch')
require_claim(update_branch, 'Update branch', 'explicit lease uses the fetched tip', 'uses an explicit `--force-with-lease` against the fetched tip')
require_claim(update_branch, 'Update branch', 'losing concurrent run refuses to push', 'the losing run refuses to push; it does not overwrite the winner')
require_claim(update_branch, 'Update branch', 'bot-tip provenance check refuses replacement', 'If the existing tip was not made by `github-actions[bot]`, it also refuses to replace it.')
require_claim(update_branch, 'Update branch', 'provenance is structural and non-cryptographic', 'These are structural provenance checks for a trusted repository, not cryptographic proof of who authored a commit and not a security boundary against a repository attacker.')
require_claim(update_branch, 'Update branch', 'custom branch and concurrency suffix must agree', 'change the last segment of `concurrency.group` to the same literal')
require_claim(update_branch, 'Update branch', 'closed PR recurrence creates a new PR', 'A closed historical pull request is not reused: the next update creates a new PR.')
require_claim(update_branch, 'Update branch', 'sole matching open PR is refreshed', 'One matching open PR is refreshed as the branch advances.')
require_claim(update_branch, 'Update branch', 'open-pr false cannot refresh an existing branch', '`open-pr: false` can create an absent update branch, but it cannot refresh an existing update branch')

permissions = section(readme, 'Permissions')
require_claim(permissions, 'Permissions', 'contents write permission', '`contents: write` to push')
require_claim(permissions, 'Permissions', 'pull-requests write permission', '`pull-requests: write` to create or refresh the pull request')
require_claim(permissions, 'Permissions', 'token permissions primary documentation', 'https://docs.github.com/en/actions/security-for-github-actions/security-guides/automatic-token-authentication#permissions-for-the-github_token')
require_claim(permissions, 'Permissions', 'Actions-created-PR repository setting', '[Allow GitHub Actions to create and approve pull requests](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository#preventing-github-actions-from-creating-or-approving-pull-requests)')
require_claim(permissions, 'Permissions', 'pr-author validates ownership and defaults to the bot', '`pr-author` is an assertion, not a way to choose an identity: the created or refreshed PR must be owned by that login (default `github-actions[bot]`) or the action fails.')
require_claim(permissions, 'Permissions', 'default-token checks require approval', 'The default `GITHUB_TOKEN` creates PR events in GitHub\'s approval-required workflow state, so downstream checks do not begin automatically.')
require_claim(permissions, 'Permissions', 'App or PAT checks can begin automatically', 'An App installation token or PAT can create events that start checks automatically, subject to your repository settings.')

supply_chain = section(readme, 'Supply chain')
require_claim(supply_chain, 'Supply chain', 'action, CLI, and adapter are separate pins', 'Pin the action and both executable packages separately')
require_claim(supply_chain, 'Supply chain', 'adapter exact pin example', '`adapter: codex@0.9.0`')
require_claim(supply_chain, 'Supply chain', 'CLI and adapter install scripts execute with job credentials', 'Both npm packages and their install scripts execute with the job\'s credentials')

pinning_rows = table_rows(section(readme, 'Pinning')).to_h { |row| [normalized_cell(row.fetch(0)), row.fetch(1)] }
reject('Pinning references must be distinct SHA, v1.0.0, and v1 rows') unless pinning_rows.keys == ['Full commit SHA', 'v1.0.0', 'v1']
reject('Pinning missing strongest full-SHA policy') unless pinning_rows.fetch('Full commit SHA').include?('Strongest action pin')
reject('Pinning missing immutable v1.0.0 policy') unless pinning_rows.fetch('v1.0.0').include?('immutable release tag')
reject('Pinning missing movable v1 policy') unless pinning_rows.fetch('v1').include?('it can move') && pinning_rows.fetch('v1').include?("repository's immutable-release policy")
RUBY

run_mutation_probe() {
  local label="$1" expected="$2" mutation="$3"
  local probe_readme="$probe_dir/$label.md" probe_output="$probe_dir/$label.out"
  cp "$readme" "$probe_readme"
  ruby -e "$mutation" "$probe_readme"
  if DOCS_CONTRACT_README="$probe_readme" DOCS_CONTRACT_SKIP_PROBES=1 bash "$0" >"$probe_output" 2>&1; then
    fail "mutation probe unexpectedly passed: $label"
  fi
  grep -Fq -- "$expected" "$probe_output" || fail "mutation probe failed for the wrong reason: $label"
  echo "docs contract mutation: $label rejected"
}

run_workflow_mutation_probe() {
  local label="$1" expected="$2" mutation="$3"
  local probe_workflow="$probe_dir/$label.yml" probe_output="$probe_dir/$label.out"
  cp "$workflow" "$probe_workflow"
  ruby -e "$mutation" "$probe_workflow"
  if DOCS_CONTRACT_WORKFLOW="$probe_workflow" DOCS_CONTRACT_SKIP_PROBES=1 bash "$0" >"$probe_output" 2>&1; then
    fail "mutation probe unexpectedly passed: $label"
  fi
  grep -Fq -- "$expected" "$probe_output" || fail "mutation probe failed for the wrong reason: $label"
  echo "docs contract mutation: $label rejected"
}

run_artifact_mutation_probe() {
  local label="$1" expected="$2" source="$3" override="$4" mutation="$5"
  local probe_file="$probe_dir/$label" probe_output="$probe_dir/$label.out"
  cp "$source" "$probe_file"
  ruby -e "$mutation" "$probe_file"
  if env "$override=$probe_file" DOCS_CONTRACT_SKIP_PROBES=1 bash "$0" > "$probe_output" 2>&1; then
    fail "mutation probe unexpectedly passed: $label"
  fi
  grep -Fq -- "$expected" "$probe_output" || fail "mutation probe failed for the wrong reason: $label"
  echo "docs contract mutation: $label rejected"
}

if [[ "${DOCS_CONTRACT_SKIP_PROBES:-0}" != 1 ]]; then
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/docs-contract.XXXXXX")"
  trap 'rm -rf "$probe_dir"' EXIT
  run_mutation_probe missing-tracked-lock 'Requirements missing claim: clean tree is insufficient without tracked facets.lock' '
    path = ARGV.fetch(0); text = File.read(path)
    claim = "The action rejects a missing, ignored, or untracked lockfile: a clean working tree alone is not evidence that the lockfile records the proposed versions."
    abort "mutation anchor missing" unless text.include?(claim)
    File.write(path, text.sub(claim, ""))
  '
  run_mutation_probe misplaced-actions-setting 'Permissions missing claim: Actions-created-PR repository setting' '
    path = ARGV.fetch(0); text = File.read(path)
    claim = "Repository or organization Actions settings must also enable [Allow GitHub Actions to create and approve pull requests](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository#preventing-github-actions-from-creating-or-approving-pull-requests)."
    abort "mutation anchor missing" unless text.include?(claim)
    text = text.sub(claim, "")
    text = text.sub("## Requirements\n", "## Requirements\n\n#{claim}\n")
    File.write(path, text)
  '
  run_mutation_probe overlapping-major-tag 'Pinning references must be distinct SHA, v1.0.0, and v1 rows' '
    path = ARGV.fetch(0); text = File.read(path)
    row = "| `v1` | Convenient major-line tag; it can move to compatible releases and therefore depends on the repository\x27s immutable-release policy. |"
    abort "mutation anchor missing" unless text.include?(row)
    File.write(path, text.sub(row, "| `v1.0.0` | Duplicate patch row. |"))
  '
  run_mutation_probe false-complete-console-promise 'Outputs missing claim: result is the final console line, with preceding diagnostics allowed' '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = "The CLI may print diagnostics before the result line"
    abort "mutation anchor missing" unless text.include?(anchor)
    File.write(path, text.sub(anchor, "The console contains only the result line"))
  '
  for index in 0 1 2; do
    case "$index" in
      0) label=quickstart ;;
      1) label=custom-branch ;;
      2) label=credentials ;;
    esac
    run_mutation_probe "missing-$label-adapter" 'must pin an exact first-party adapter' "
      path = ARGV.fetch(0); text = File.read(path)
      anchor = 'adapter: codex@0.9.0'
      positions = text.enum_for(:scan, anchor).map { Regexp.last_match.begin(0) }
      abort 'mutation anchor count differs' unless positions.length == 4
      offset = positions.fetch($index)
      File.write(path, text[0...offset] + 'adapter: codex@latest' + text[(offset + anchor.length)..])
    "
  done
  run_artifact_mutation_probe floating-example-adapter 'standalone example must pin an exact first-party adapter' "$example" DOCS_CONTRACT_EXAMPLE '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = "adapter: codex@0.9.0"
    abort "mutation anchor missing" unless text.include?(anchor)
    File.write(path, text.sub(anchor, "adapter: codex@latest"))
  '
  run_artifact_mutation_probe missing-action-input 'action adapter input must be required without a default' "$action" DOCS_CONTRACT_ACTION '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = "    required: true\n"
    abort "mutation anchor missing" unless text.include?(anchor)
    File.write(path, text.sub(anchor, "    required: false\n"))
  '
  run_artifact_mutation_probe missing-action-env 'action adapter env wiring missing' "$action" DOCS_CONTRACT_ACTION '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = %q{        FACET_ADAPTER: ${{ inputs.adapter }}}
    abort "mutation anchor missing" unless text.include?(anchor)
    File.write(path, text.sub(anchor, ""))
  '
  run_artifact_mutation_probe missing-publisher-bootstrap 'publisher must bootstrap pinned adapter once before update' "$publisher" DOCS_CONTRACT_PUBLISHER '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = %q{npx --yes "agent-facets@${CLI_VERSION}" adapter add "$ADAPTER" < /dev/null}
    abort "mutation anchor missing" unless text.include?(anchor)
    File.write(path, text.sub(anchor, ""))
  '
  run_artifact_mutation_probe late-publisher-bootstrap 'publisher must bootstrap pinned adapter once before update' "$publisher" DOCS_CONTRACT_PUBLISHER '
    path = ARGV.fetch(0); text = File.read(path)
    bootstrap = %q{npx --yes "agent-facets@${CLI_VERSION}" adapter add "$ADAPTER" < /dev/null}
    update = %q{bash "$(dirname "$0")/facet-update.sh"}
    abort "mutation anchor missing" unless text.include?(bootstrap) && text.include?(update)
    text = text.sub(bootstrap, "")
    File.write(path, text.sub(update, "#{update}\n#{bootstrap}"))
  '
  run_artifact_mutation_probe missing-publisher-validation 'publisher adapter validation must precede repository discovery' "$publisher" DOCS_CONTRACT_PUBLISHER '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = %q{[[ "$ADAPTER" =~}
    abort "mutation anchor missing" unless text.include?(anchor)
    File.write(path, text.sub(anchor, "[[ \"DISABLED_ADAPTER\" =~"))
  '
  run_workflow_mutation_probe missing-final-result-check 'published CLI dry-run missing final console line' '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = "tail -n 1 /tmp/dry-run.log"
    abort "mutation anchor missing" unless text.include?(anchor)
    File.write(path, text.sub(anchor, "head -n 1 /tmp/dry-run.log"))
  '
  run_workflow_mutation_probe corrupt-dry-run-lock 'published CLI dry-run must not corrupt installed lock entries' '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = "git restore --source=HEAD^ --worktree -- ."
    abort "mutation anchor missing" unless text.include?(anchor)
    q = 39.chr
    corruption = "node -e #{q}const fs = require(\"fs\"); const lock = JSON.parse(fs.readFileSync(\"facets.lock\", \"utf8\")); for (const entry of Object.values(lock.facets)) entry.version = \"1.0.0\"; fs.writeFileSync(\"facets.lock\", JSON.stringify(lock))#{q}"
    File.write(path, text.sub(anchor, "#{anchor}\n          #{corruption}"))
  '
  run_workflow_mutation_probe metadata-only-dry-run-hash 'published CLI dry-run missing complete tracked file manifest' '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = "git ls-tree -r -z --name-only HEAD^ | LC_ALL=C sort -z | xargs -0 -r sha256sum -- > /tmp/published-cli.sha"
    abort "mutation anchor missing" unless text.include?(anchor)
    File.write(path, text.sub(anchor, "sha256sum facets.json facets.lock > /tmp/published-cli.sha"))
  '
  run_workflow_mutation_probe missing-published-adapter 'published CLI fixture must configure pinned Codex adapter before install' '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = %q{npx --yes "agent-facets@${FACET_CLI_PIN}" adapter add codex@0.9.0 < /dev/null}
    abort "mutation anchor count differs" unless text.scan(anchor).length == 2
    File.write(path, text.sub(anchor, ""))
  '
  run_workflow_mutation_probe late-published-adapter 'published CLI fixture must configure pinned Codex adapter before install' '
    path = ARGV.fetch(0); text = File.read(path)
    adapter = %q{npx --yes "agent-facets@${FACET_CLI_PIN}" adapter add codex@0.9.0 < /dev/null}
    install = %q{npx --yes "agent-facets@${FACET_CLI_PIN}" install --accept-mcp < /dev/null}
    pair = "#{adapter}\n          #{install}"
    abort "mutation anchor count differs" unless text.scan(pair).length == 2
    File.write(path, text.sub(pair, "#{install}\n          #{adapter}"))
  '
  run_workflow_mutation_probe missing-action-adapter 'action CI fixture must configure pinned Codex adapter before install' '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = %q{npx --yes "agent-facets@${FACET_CLI_PIN}" adapter add codex@0.9.0 < /dev/null}
    abort "mutation anchor count differs" unless text.scan(anchor).length == 2
    offset = text.rindex(anchor)
    File.write(path, text[0...offset] + text[(offset + anchor.length)..])
  '
  run_workflow_mutation_probe late-action-fixture-adapter 'action CI fixture must configure pinned Codex adapter before install' '
    path = ARGV.fetch(0); text = File.read(path)
    adapter = %q{npx --yes "agent-facets@${FACET_CLI_PIN}" adapter add codex@0.9.0 < /dev/null}
    install = %q{npx --yes "agent-facets@${FACET_CLI_PIN}" install --accept-mcp < /dev/null}
    pair = "#{adapter}\n          #{install}"
    abort "mutation anchor count differs" unless text.scan(pair).length == 2
    offset = text.rindex(pair)
    File.write(path, text[0...offset] + "#{install}\n          #{adapter}" + text[(offset + pair.length)..])
  '
  run_workflow_mutation_probe floating-published-adapter 'published CLI fixture must configure pinned Codex adapter before install' '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = %q{adapter add codex@0.9.0}
    abort "mutation anchor count differs" unless text.scan(anchor).length == 2
    File.write(path, text.sub(anchor, "adapter add codex@latest"))
  '
  run_workflow_mutation_probe floating-action-fixture-adapter 'action CI fixture must configure pinned Codex adapter before install' '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = %q{adapter add codex@0.9.0}
    abort "mutation anchor count differs" unless text.scan(anchor).length == 2
    offset = text.rindex(anchor)
    File.write(path, text[0...offset] + "adapter add codex" + text[(offset + anchor.length)..])
  '
  run_workflow_mutation_probe missing-action-input 'action CI must select exact Codex adapter' '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = "          adapter: codex@0.9.0\n"
    abort "mutation anchor missing" unless text.include?(anchor)
    File.write(path, text.sub(anchor, ""))
  '
  run_workflow_mutation_probe missing-pre-action-absence 'action CI must assert adapter home absent without preseed' '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = %q{test ! -e "$FACET_DIR"}
    abort "mutation anchor missing" unless text.include?(anchor)
    File.write(path, text.sub(anchor, %q{test -e "$FACET_DIR"}))
  '
  run_workflow_mutation_probe preseeded-action-home 'action CI must assert adapter home absent without preseed' '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = %q{test ! -e "$FACET_DIR"}
    abort "mutation anchor missing" unless text.include?(anchor)
    File.write(path, text.sub(anchor, %Q{mkdir -p "$FACET_DIR/adapters/codex"\n          #{anchor}}))
  '
  run_workflow_mutation_probe missing-post-action-presence 'action CI must assert selected adapter presence afterward' '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = %q{test -d "$FACET_DIR/adapters/codex"}
    abort "mutation anchor missing" unless text.include?(anchor)
    File.write(path, text.sub(anchor, ""))
  '
  run_workflow_mutation_probe wrong-action-home 'action CI adapter home must be unique and shared across assertions and invocation' '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = %q{FACET_DIR: ${{ runner.temp }}/facet-update-action-${{ github.run_id }}-${{ github.run_attempt }}}
    abort "mutation anchor count differs" unless text.scan(anchor).length == 3
    File.write(path, text.sub(anchor, "FACET_DIR: /tmp/preseeded-home"))
  '
  run_workflow_mutation_probe untracked-action-fixture 'action CI fixture setup missing git add -A -- fixture' '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = "git add -A -- fixture"
    abort "mutation anchor missing" unless text.include?(anchor)
    File.write(path, text.sub(anchor, "git status --short -- fixture"))
  '
  run_workflow_mutation_probe wrong-action-base 'action CI must select fixture remote base' '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = "base: ci-fixture-base"
    abort "mutation anchor missing" unless text.include?(anchor)
    File.write(path, text.sub(anchor, "base: main"))
  '
  run_workflow_mutation_probe default-shallow-checkout 'action CI must use a full-depth checkout before pushing fixture to bare origin' '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = "        with:\n          fetch-depth: 0\n"
    abort "mutation anchor missing" unless text.include?(anchor)
    File.write(path, text.sub(anchor, ""))
  '
  run_workflow_mutation_probe depth-one-checkout 'action CI must use a full-depth checkout before pushing fixture to bare origin' '
    path = ARGV.fetch(0); text = File.read(path)
    anchor = "          fetch-depth: 0"
    abort "mutation anchor missing" unless text.include?(anchor)
    File.write(path, text.sub(anchor, "          fetch-depth: 1"))
  '
fi

echo 'docs contract: PASS'
