# frozen_string_literal: true

require_relative "orchestration_test_helper"

class PipelineAnalysisTest < OrchestrationTestCase
  def setup
    super
    @ctrl_name = "posts_controller"
    @ctrl_path = create_controller(@ctrl_name)
    seed_controller(@ctrl_name)
  end

  def test_happy_path
    seed_workflow(@ctrl_name)
    stub_claude_call(analysis_fixture)

    @pipeline.run_analysis(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "awaiting_decisions", wf[:status]
    assert_equal 2, wf[:analysis]["findings"].length
    assert_equal "high", wf[:analysis]["overall_risk"]

    # Sidecar written
    sidecar = read_sidecar(@ctrl_path, "analysis.json")
    assert_equal "high", sidecar["overall_risk"]
    assert_equal 2, sidecar["findings"].length

    # Prompt stored
    prompt = @pipeline.get_prompt(@ctrl_name, :analyze)
    assert_includes prompt, @ctrl_name
  end

  def test_error_sets_error_status
    seed_workflow(@ctrl_name)
    stub_claude_call_failure("Claude exploded")

    @pipeline.run_analysis(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "error", wf[:status]
    assert_includes wf[:error], "Claude exploded"

    errors = global_errors
    assert errors.any? { |e| e[:message].include?("Analysis failed") },
           "Expected global error about analysis failure, got: #{errors}"

    refute sidecar_exists?(@ctrl_path, "analysis.json")
  end

  def test_invalid_json_sets_error
    seed_workflow(@ctrl_name)
    calls = @claude_calls
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      calls << { prompt: prompt }
      "this is not json at all"
    end

    @pipeline.run_analysis(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "error", wf[:status]
    assert_match(/parse|JSON/i, wf[:error])
  end

  def test_cancelled_pipeline_sets_error
    seed_workflow(@ctrl_name)
    response = JSON.generate(analysis_fixture)
    calls = @claude_calls
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      calls << { prompt: prompt }
      @cancelled = true
      response
    end

    @pipeline.run_analysis(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "error", wf[:status]
    assert_match(/cancelled/i, wf[:error])
  end

  def test_load_existing_analysis_from_sidecar
    # Write a sidecar file directly
    sidecar_dir = File.join(File.dirname(@ctrl_path), ".harden", @ctrl_name)
    File.write(File.join(sidecar_dir, "analysis.json"),
               JSON.pretty_generate(analysis_fixture))

    # Stub claude_call to track any unexpected calls
    stub_claude_call(analysis_fixture)

    @pipeline.load_existing_analysis(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "awaiting_decisions", wf[:status]
    assert_equal 2, wf[:analysis]["findings"].length

    # No claude call should have been made
    assert_empty @claude_calls
  end

  # ── Edge-case fixture tests ──────────────────────────────

  def test_zero_findings_still_succeeds
    seed_workflow(@ctrl_name)
    fixture = analysis_fixture.merge("findings" => [], "overall_risk" => "low")
    stub_claude_call(fixture)

    @pipeline.run_analysis(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "awaiting_decisions", wf[:status]
    assert_equal 0, wf[:analysis]["findings"].length
    assert_equal "low", wf[:analysis]["overall_risk"]
  end

  def test_extra_unknown_keys_ignored
    seed_workflow(@ctrl_name)
    fixture = analysis_fixture.merge(
      "llm_confidence" => 0.95,
      "model_version" => "claude-4",
      "internal_debug" => { "tokens" => 1234 }
    )
    stub_claude_call(fixture)

    @pipeline.run_analysis(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "awaiting_decisions", wf[:status]
    # Core fields still correct
    assert_equal 2, wf[:analysis]["findings"].length
    assert_equal "high", wf[:analysis]["overall_risk"]
  end

  def test_missing_overall_risk_still_succeeds
    seed_workflow(@ctrl_name)
    fixture = analysis_fixture.tap { |f| f.delete("overall_risk") }
    stub_claude_call(fixture)

    @pipeline.run_analysis(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "awaiting_decisions", wf[:status]
    assert_nil wf[:analysis]["overall_risk"]
    assert_equal 2, wf[:analysis]["findings"].length
  end
end
