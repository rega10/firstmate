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

    step_commands = lambda do |job|
      job.fetch("steps", []).flat_map do |step|
        run = step["run"]
        run.is_a?(String) ? logical_commands.call(run) : []
      end
    end

    direct_command = lambda do |job, executable, arguments = []|
      step_commands.call(job).any? do |tokens|
        tokens.first&.delete_prefix("./") == executable && tokens.drop(1).first(arguments.length) == arguments
      end
    end

    lint_job = jobs.values.find do |job|
      step_commands.call(job).any? do |tokens|
        tokens.length == 1 && tokens.first.delete_prefix("./") == "bin/fm-lint.sh"
      end
    end
    abort "lint job running bin/fm-lint.sh is missing" unless lint_job

    coverage_job = jobs.fetch("test-coverage")
    unless direct_command.call(coverage_job, "bin/fm-test-run.sh", ["--check-coverage"])
      abort "coverage job does not directly invoke fm-test-run.sh --check-coverage"
    end

    [1, 2].each do |shard|
      job = jobs.fetch("tests-portable-parallel-#{shard}")
      lane = "portable-parallel-#{shard}"
      unless direct_command.call(job, "bin/fm-test-run.sh", ["--lane", lane])
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
        logical_commands.call(step["run"]).any? do |tokens|
          tokens.first&.delete_prefix("./") == "bin/fm-test-run.sh" &&
            tokens.drop(1).first(2) == ["--lane", "$FM_SERIAL_LANE"]
        end
    end
    abort "serial shards do not directly invoke their derived lane" unless serial_step

    herdr_job = jobs.fetch("tests-herdr")
    herdr_arguments = ["--family", "real-herdr-gated", "--fail-on-gate-skip", "herdr not found"]
    unless direct_command.call(herdr_job, "bin/fm-test-run.sh", herdr_arguments)
      abort "Herdr job does not directly invoke the required real-Herdr family"
    end

    macos_job = jobs.fetch("macos-stock-bash")
    abort "stock Bash job must run on macos-latest" unless macos_job["runs-on"] == "macos-latest"
    stock_bash_step = macos_job.fetch("steps").find do |step|
      step["shell"] == "/bin/bash {0}" &&
        step["run"].is_a?(String) &&
        logical_commands.call(step["run"]).any? do |tokens|
          tokens.first&.delete_prefix("./") == "bin/fm-lint.sh" && tokens.drop(1).first == "--list-files"
        end
    end
    abort "stock Bash job lacks its /bin/bash parse-sweep step" unless stock_bash_step

    invariants_job = jobs.fetch("invariants")
    invariant_steps = invariants_job.fetch("steps")
    has_checkout = invariant_steps.any? { |step| step["uses"].to_s.start_with?("actions/checkout@") }
    has_behavior = direct_command.call(invariants_job, "cmp", ["-s", "CLAUDE.md", "$tmp"])
    abort "invariants job lacks checkout or executable behavior" unless has_checkout && has_behavior
  ' "$NM" "$CI" || fail "no-mistakes and CI YAML contracts must remain intact"
  pass "no-mistakes stays targeted and CI owns broad behavior coverage"
}

test_nm_yaml_tracked
test_yaml_contracts
