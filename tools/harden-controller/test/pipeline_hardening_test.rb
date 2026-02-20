# frozen_string_literal: true

require_relative "orchestration_test_helper"

class PipelineHardeningTest < OrchestrationTestCase
  def setup
    super
    @ctrl_name = "posts_controller"
    @ctrl_path = create_controller(@ctrl_name)
    seed_controller(@ctrl_name)
  end

  def test_happy_path_approve
    seed_workflow(@ctrl_name,
                  status: "awaiting_decisions",
                  analysis: analysis_fixture,
                  decision: decision_fixture(action: "approve"))
    stub_claude_call(hardened_fixture)
    testing_recorder = capture_chained_call(:run_testing)

    @pipeline.run_hardening(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "hardened", wf[:status]
    assert_equal CONTROLLER_SOURCE, wf[:original_source]
    assert_equal "hardened", wf[:hardened]["status"]

    # Controller file rewritten
    assert_equal HARDENED_SOURCE, File.read(@ctrl_path)

    # Sidecar written
    sidecar = read_sidecar(@ctrl_path, "hardened.json")
    assert_equal "hardened", sidecar["status"]
    assert sidecar["changes_applied"].length >= 1

    # Chained to testing
    assert testing_recorder.called?
    assert_equal [@ctrl_name], testing_recorder.args
  end

  def test_skip_decision
    seed_workflow(@ctrl_name,
                  status: "awaiting_decisions",
                  analysis: analysis_fixture,
                  decision: decision_fixture(action: "skip"))
    stub_claude_call(hardened_fixture)
    testing_recorder = capture_chained_call(:run_testing)

    @pipeline.run_hardening(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "skipped", wf[:status]
    assert wf[:completed_at]

    assert_empty @claude_calls
    refute testing_recorder.called?
  end

  def test_error_sets_error_status
    seed_workflow(@ctrl_name,
                  status: "awaiting_decisions",
                  analysis: analysis_fixture,
                  decision: decision_fixture(action: "approve"))
    stub_claude_call_failure("Hardening exploded")
    testing_recorder = capture_chained_call(:run_testing)

    @pipeline.run_hardening(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "error", wf[:status]
    assert_includes wf[:error], "Hardening exploded"

    # Controller file unchanged
    assert_equal CONTROLLER_SOURCE, File.read(@ctrl_path)

    refute testing_recorder.called?
  end

  def test_no_hardened_source_skips_file_write
    fixture = hardened_fixture.tap { |h| h.delete("hardened_source") }
    seed_workflow(@ctrl_name,
                  status: "awaiting_decisions",
                  analysis: analysis_fixture,
                  decision: decision_fixture(action: "approve"))
    stub_claude_call(fixture)
    testing_recorder = capture_chained_call(:run_testing)

    @pipeline.run_hardening(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "hardened", wf[:status]

    # Controller file unchanged (no hardened_source in response)
    assert_equal CONTROLLER_SOURCE, File.read(@ctrl_path)

    # Still chains to testing
    assert testing_recorder.called?
  end

  def test_submit_decision_triggers_hardening
    seed_workflow(@ctrl_name,
                  status: "awaiting_decisions",
                  analysis: analysis_fixture)
    stub_claude_call(hardened_fixture)
    testing_recorder = capture_chained_call(:run_testing)

    @pipeline.submit_decision(@ctrl_name, decision_fixture(action: "approve"))

    wf = workflow_state(@ctrl_name)
    assert_equal "approve", wf[:decision]["action"]
    assert_equal "hardened", wf[:status]
    assert testing_recorder.called?
  end

  def test_cancelled_pipeline_sets_error
    seed_workflow(@ctrl_name,
                  status: "awaiting_decisions",
                  analysis: analysis_fixture,
                  decision: decision_fixture(action: "approve"))
    response = JSON.generate(hardened_fixture)
    calls = @claude_calls
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      calls << { prompt: prompt }
      @cancelled = true
      response
    end
    testing_recorder = capture_chained_call(:run_testing)

    @pipeline.run_hardening(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "error", wf[:status]
    assert_match(/cancelled/i, wf[:error])
    refute testing_recorder.called?
  end
end
