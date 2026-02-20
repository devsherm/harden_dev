# frozen_string_literal: true

require_relative "orchestration_test_helper"

class PipelineCiChecksTest < OrchestrationTestCase
  def setup
    super
    @ctrl_name = "posts_controller"
    @ctrl_path = create_controller(@ctrl_name)
    seed_controller(@ctrl_name)
  end

  def test_all_pass
    seed_workflow(@ctrl_name, status: "tested", analysis: analysis_fixture)
    stub_ci_checks_pass
    verification_recorder = capture_chained_call(:run_verification)

    @pipeline.run_ci_checks(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "ci_passed", wf[:status]
    assert wf[:ci_results][:passed]

    # Raw checks array preserved for UI display
    assert_kind_of Array, wf[:ci_results][:checks]
    assert_equal Pipeline::CI_CHECKS.length, wf[:ci_results][:checks].length
    wf[:ci_results][:checks].each do |check|
      assert check[:passed], "Expected all checks to pass, but #{check[:name]} failed"
      assert check[:name], "Check should have a name"
    end

    # Sidecar written
    sidecar = read_sidecar(@ctrl_path, "ci_results.json")
    assert sidecar["passed"]

    assert verification_recorder.called?
    assert_equal [@ctrl_name], verification_recorder.args
  end

  def test_fail_then_fix_succeeds
    seed_workflow(@ctrl_name, status: "tested", analysis: analysis_fixture)
    stub_ci_checks_sequence([failing_ci_results, passing_ci_results])
    stub_claude_call(fix_ci_fixture)
    verification_recorder = capture_chained_call(:run_verification)

    @pipeline.run_ci_checks(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "ci_passed", wf[:status]
    assert_equal 1, wf[:ci_results][:fix_attempts].length

    assert verification_recorder.called?
  end

  def test_all_fix_attempts_fail
    seed_workflow(@ctrl_name, status: "tested", analysis: analysis_fixture)
    # 1 initial + MAX_CI_FIX_ATTEMPTS(2) retries = 3 CI check calls, all fail
    stub_ci_checks_sequence([failing_ci_results, failing_ci_results, failing_ci_results])
    stub_claude_call(fix_ci_fixture)
    verification_recorder = capture_chained_call(:run_verification)

    @pipeline.run_ci_checks(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "ci_failed", wf[:status]
    assert_equal 2, wf[:ci_results][:fix_attempts].length
    refute wf[:ci_results][:passed]

    refute verification_recorder.called?
  end

  def test_guards_on_tested_status
    seed_workflow(@ctrl_name, status: "pending")
    stub_ci_checks_pass
    verification_recorder = capture_chained_call(:run_verification)

    @pipeline.run_ci_checks(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "pending", wf[:status]
    refute verification_recorder.called?
  end

  def test_error_sets_error_status
    seed_workflow(@ctrl_name, status: "tested", analysis: analysis_fixture)
    @pipeline.define_singleton_method(:run_all_ci_checks) do |controller_relative|
      raise RuntimeError, "CI exploded"
    end
    verification_recorder = capture_chained_call(:run_verification)

    @pipeline.run_ci_checks(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "error", wf[:status]
    assert_includes wf[:error], "CI exploded"
    refute verification_recorder.called?
  end

  def test_fix_rewrites_controller
    fixed_source = "class Fixed; end"
    seed_workflow(@ctrl_name, status: "tested", analysis: analysis_fixture)
    stub_ci_checks_sequence([failing_ci_results, passing_ci_results])
    stub_claude_call(fix_ci_fixture(fixed_source))
    capture_chained_call(:run_verification)

    @pipeline.run_ci_checks(@ctrl_name)

    assert_equal fixed_source, File.read(@ctrl_path)
  end

end
