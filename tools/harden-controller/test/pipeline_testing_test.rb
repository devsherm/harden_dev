# frozen_string_literal: true

require_relative "orchestration_test_helper"

class PipelineTestingTest < OrchestrationTestCase
  def setup
    super
    @ctrl_name = "posts_controller"
    @ctrl_path = create_controller(@ctrl_name)
    @test_path = create_test_file(@ctrl_name)
    seed_controller(@ctrl_name)
  end

  def test_pass_on_first_attempt
    seed_workflow(@ctrl_name, status: "hardened", analysis: analysis_fixture)
    stub_spawn(output: "0 failures", success: true)
    ci_recorder = capture_chained_call(:run_ci_checks)

    @pipeline.run_testing(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "tested", wf[:status]
    assert_equal 1, wf[:test_results][:attempts].length
    assert wf[:test_results][:passed]

    # Sidecar written
    sidecar = read_sidecar(@ctrl_path, "test_results.json")
    assert sidecar["passed"]

    # Chained to CI checks
    assert ci_recorder.called?
    assert_equal [@ctrl_name], ci_recorder.args
  end

  def test_fail_then_fix_succeeds
    seed_workflow(@ctrl_name, status: "hardened", analysis: analysis_fixture)
    stub_spawn_sequence([["FAIL output", false], ["0 failures", true]])
    stub_claude_call(fix_tests_fixture)
    ci_recorder = capture_chained_call(:run_ci_checks)

    @pipeline.run_testing(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "tested", wf[:status]
    assert_equal 2, wf[:test_results][:attempts].length
    assert wf[:test_results][:passed]

    # Controller file rewritten by fix
    assert_equal HARDENED_SOURCE, File.read(@ctrl_path)

    assert ci_recorder.called?
  end

  def test_all_attempts_fail
    seed_workflow(@ctrl_name, status: "hardened", analysis: analysis_fixture)
    # 1 initial + MAX_FIX_ATTEMPTS(2) retries = 3 spawn calls
    stub_spawn(output: "FAIL", success: false)
    stub_claude_call(fix_tests_fixture)
    ci_recorder = capture_chained_call(:run_ci_checks)

    @pipeline.run_testing(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "tests_failed", wf[:status]
    assert_equal 3, wf[:test_results][:attempts].length
    refute wf[:test_results][:passed]

    refute ci_recorder.called?
  end

  def test_guards_on_hardened_status
    seed_workflow(@ctrl_name, status: "pending")
    stub_spawn(output: "OK", success: true)
    ci_recorder = capture_chained_call(:run_ci_checks)

    @pipeline.run_testing(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "pending", wf[:status]
    assert_empty @spawn_calls
    refute ci_recorder.called?
  end

  def test_no_test_file_runs_full_suite
    FileUtils.rm(@test_path)

    seed_workflow(@ctrl_name, status: "hardened", analysis: analysis_fixture)
    stub_spawn(output: "OK", success: true)
    capture_chained_call(:run_ci_checks)

    @pipeline.run_testing(@ctrl_name)

    assert_equal 1, @spawn_calls.length
    assert_equal ["bin/rails", "test"], @spawn_calls.first[:cmd]
  end

  def test_with_test_file_runs_specific
    seed_workflow(@ctrl_name, status: "hardened", analysis: analysis_fixture)
    stub_spawn(output: "OK", success: true)
    capture_chained_call(:run_ci_checks)

    @pipeline.run_testing(@ctrl_name)

    assert_equal 1, @spawn_calls.length
    expected_test_path = File.join(@tmpdir, "test", "controllers", "blog",
                                   "#{@ctrl_name}_test.rb")
    assert_equal ["bin/rails", "test", expected_test_path], @spawn_calls.first[:cmd]
  end

  def test_spawn_error_sets_error_status
    seed_workflow(@ctrl_name, status: "hardened", analysis: analysis_fixture)
    @pipeline.define_singleton_method(:spawn_with_timeout) do |*cmd, timeout:, chdir: nil|
      raise RuntimeError, "Spawn exploded"
    end
    ci_recorder = capture_chained_call(:run_ci_checks)

    @pipeline.run_testing(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "error", wf[:status]
    assert_includes wf[:error], "Spawn exploded"
    refute ci_recorder.called?
  end

end
