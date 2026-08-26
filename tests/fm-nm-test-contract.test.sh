#!/usr/bin/env bash
# Contract: local no-mistakes Test is intent-targeted; CI owns broad regression.
#
# Firstmate must not configure commands.test as a complete tests/*.test.sh walk
# (that duplicated CI and burned local pipeline time). Lint stays pinned to
# bin/fm-lint.sh. Remote CI owns broad regression through separate portable and
# required real-Herdr Behavior lanes composed around bin/fm-test-run.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"
CI="$ROOT/.github/workflows/ci.yml"

test_nm_yaml_tracked() {
  assert_present "$NM" "tracked .no-mistakes.yaml is missing"
  git -C "$ROOT" ls-files --error-unmatch .no-mistakes.yaml >/dev/null 2>&1 \
    || fail ".no-mistakes.yaml is not tracked by git"
  pass ".no-mistakes.yaml is present and tracked"
}

test_yaml_contracts() {
  assert_present "$CI" "ci.yml is missing"
  ruby -ryaml -rshellwords -e '
    nm = YAML.safe_load(File.read(ARGV.fetch(0))) || {}
    commands = nm.fetch("commands", {})
    abort "commands must be a mapping" unless commands.is_a?(Hash)
    abort "commands.lint must remain exactly bin/fm-lint.sh" unless commands["lint"] == "bin/fm-lint.sh"
    test_command = commands["test"]
    unless test_command.nil? || test_command == false || test_command == ""
      abort "commands.test must be absent or empty so Test stays intent-targeted"
    end

    workflow = YAML.safe_load(File.read(ARGV.fetch(1))) || {}
    jobs = workflow.fetch("jobs")
    abort "jobs must be a mapping" unless jobs.is_a?(Hash)

    logical_commands = lambda do |run|
      commands = []
      pending = ""
      run.to_s.each_line do |line|
        stripped = line.strip
        next if pending.empty? && (stripped.empty? || line.match?(/\A[[:space:]]/))
        if stripped.end_with?("\\")
          pending << stripped.delete_suffix("\\") << " "
          next
        end
        pending << stripped
        unless pending.empty?
          begin
            tokens = Shellwords.shellsplit(pending)
          rescue ArgumentError
            pending = ""
            next
          end
          tokens.shift while tokens.first&.match?(/\A[A-Za-z_][A-Za-z0-9_]*=/)
          commands << tokens unless tokens.empty?
        end
        pending = ""
      end
      abort "workflow run block ends with a continuation" unless pending.empty?
      commands
    end

    normalized_commands = lambda do |run|
      logical_commands.call(run).map do |tokens|
        normalized = tokens.dup
        normalized[0] = normalized.first.delete_prefix("./")
        normalized
      end
    end

    step_commands = lambda do |job|
      job.fetch("steps", []).flat_map do |step|
        run = step["run"]
        run.is_a?(String) ? normalized_commands.call(run) : []
      end
    end

    commands_by_job = jobs.each_with_object({}) do |(job_id, job), inventory|
      inventory[job_id] = step_commands.call(job)
    end

    expected_commands = {
      lint: ["bin/fm-lint.sh"],
      coverage: ["bin/fm-test-run.sh", "--check-coverage"],
      parallel: {
        1 => [
          "bin/fm-test-run.sh", "--lane", "portable-parallel-1", "--json",
          "$RUNNER_TEMP/fm-test/fm-test-timing-portable-parallel-1.json"
        ],
        2 => [
          "bin/fm-test-run.sh", "--lane", "portable-parallel-2", "--json",
          "$RUNNER_TEMP/fm-test/fm-test-timing-portable-parallel-2.json"
        ]
      },
      serial: [
        "bin/fm-test-run.sh", "--lane", "$FM_SERIAL_LANE", "--json",
        "$RUNNER_TEMP/fm-test/fm-test-timing-portable-serial-${FM_SERIAL_SHARD}.json"
      ],
      herdr: [
        "bin/fm-test-run.sh", "--family", "real-herdr-gated",
        "--fail-on-gate-skip", "herdr not found", "--json",
        "$RUNNER_TEMP/fm-test/fm-test-timing-herdr.json"
      ],
      stock_parse: ["bin/fm-lint.sh", "--list-files", ">", "$shell_inventory"],
      invariant: Shellwords.shellsplit(%q{cmp -s CLAUDE.md "$tmp" || { echo "::error::CLAUDE.md must be the canonical @AGENTS.md pointer"; exit 1; }})
    }

    lint_job = commands_by_job.values.find do |commands_for_job|
      commands_for_job.include?(expected_commands.fetch(:lint))
    end
    abort "lint job running bin/fm-lint.sh is missing" unless lint_job

    unless commands_by_job.fetch("test-coverage").include?(expected_commands.fetch(:coverage))
      abort "coverage job does not directly invoke fm-test-run.sh --check-coverage"
    end

    [1, 2].each do |shard|
      expected = expected_commands.fetch(:parallel).fetch(shard)
      unless commands_by_job.fetch("tests-portable-parallel-#{shard}").include?(expected)
        abort "portable parallel shard #{shard} does not directly invoke its lane"
      end
    end

    serial_job = jobs.fetch("tests-portable-serial")
    unless serial_job.dig("strategy", "matrix", "shard") == [1, 2, 3, 4]
      abort "serial shard matrix is not 1..4"
    end
    expected_lane = "portable-serial-${{ matrix.shard }}of${{ strategy.job-total }}"
    serial_step = serial_job.fetch("steps").find do |step|
      step.dig("env", "FM_SERIAL_LANE") == expected_lane &&
        step["run"].is_a?(String) &&
        normalized_commands.call(step["run"]).include?(expected_commands.fetch(:serial))
    end
    abort "serial shards do not directly invoke their derived lane" unless serial_step

    unless commands_by_job.fetch("tests-herdr").include?(expected_commands.fetch(:herdr))
      abort "Herdr job does not directly invoke the required real-Herdr family"
    end

    macos_job = jobs.fetch("macos-stock-bash")
    abort "stock Bash job must run on macos-latest" unless macos_job["runs-on"] == "macos-latest"
    stock_bash_step = macos_job.fetch("steps").find do |step|
      step["shell"] == "/bin/bash {0}" &&
        step["run"].is_a?(String) &&
        normalized_commands.call(step["run"]).include?(expected_commands.fetch(:stock_parse))
    end
    abort "stock Bash job lacks its /bin/bash parse-sweep step" unless stock_bash_step

    invariants_job = jobs.fetch("invariants")
    invariant_steps = invariants_job.fetch("steps")
    has_checkout = invariant_steps.any? { |step| step["uses"].to_s.start_with?("actions/checkout@") }
    has_behavior = commands_by_job.fetch("invariants").include?(expected_commands.fetch(:invariant))
    abort "invariants job lacks checkout or executable behavior" unless has_checkout && has_behavior
  ' "$NM" "$CI" || fail "no-mistakes and CI YAML contracts must remain intact"
  pass "no-mistakes stays targeted and CI owns broad behavior coverage"
}

test_nm_yaml_tracked
test_yaml_contracts
