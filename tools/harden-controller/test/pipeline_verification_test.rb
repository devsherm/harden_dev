# frozen_string_literal: true

require_relative "orchestration_test_helper"

class PipelineVerificationTest < OrchestrationTestCase
  def setup
    super
    @ctrl_name = "posts_controller"
    @ctrl_path = create_controller(@ctrl_name)
    seed_controller(@ctrl_name)
  end

  def test_happy_path
    seed_workflow(@ctrl_name,
                  status: "h_ci_passed",
                  analysis: analysis_fixture,
                  original_source: CONTROLLER_SOURCE,
                  hardened: hardened_fixture)
    stub_claude_call(verification_fixture)

    @pipeline.run_verification(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "h_complete", wf[:status]
    assert wf[:completed_at]
    assert_equal "accept", wf[:verification]["recommendation"]

    # Sidecar written
    sidecar = read_sidecar(@ctrl_path, "verification.json")
    assert_equal "accept", sidecar["recommendation"]

    # Prompt stored
    prompt = @pipeline.get_prompt(@ctrl_name, :h_verify)
    assert_includes prompt, @ctrl_name
  end

  def test_error_sets_error_status
    seed_workflow(@ctrl_name,
                  status: "h_ci_passed",
                  analysis: analysis_fixture,
                  original_source: CONTROLLER_SOURCE,
                  hardened: hardened_fixture)
    stub_claude_call_failure("Verification exploded")

    @pipeline.run_verification(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "error", wf[:status]
    assert_includes wf[:error], "Verification exploded"
    refute sidecar_exists?(@ctrl_path, "verification.json")
  end

  def test_guards_on_ci_passed_status
    seed_workflow(@ctrl_name, status: "pending")
    stub_claude_call(verification_fixture)

    @pipeline.run_verification(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "pending", wf[:status]
    assert_empty @claude_calls
  end

  def test_invalid_json_sets_error
    seed_workflow(@ctrl_name,
                  status: "h_ci_passed",
                  analysis: analysis_fixture,
                  original_source: CONTROLLER_SOURCE,
                  hardened: hardened_fixture)
    calls = @claude_calls
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      calls << { prompt: prompt }
      "not json"
    end

    @pipeline.run_verification(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "error", wf[:status]
  end

  def test_prompt_includes_original_and_hardened
    seed_workflow(@ctrl_name,
                  status: "h_ci_passed",
                  analysis: analysis_fixture,
                  original_source: CONTROLLER_SOURCE,
                  hardened: hardened_fixture)
    stub_claude_call(verification_fixture)

    @pipeline.run_verification(@ctrl_name)

    assert_equal 1, @claude_calls.length
    prompt = @claude_calls.first[:prompt]
    # Original source embedded
    assert_includes prompt, "Blog::Post.all"
    # Hardened source unique marker
    assert_includes prompt, "authenticate_user!"
    # Section markers from Prompts.verify template
    assert_includes prompt, "### Original"
    assert_includes prompt, "### Hardened"
    assert_includes prompt, "### Original Analysis"
    # Analysis findings JSON is embedded
    assert_includes prompt, "finding_001"
    assert_includes prompt, "overall_risk"
    # Controller name appears in the prompt header
    assert_includes prompt, "## Controller: #{@ctrl_name}"
  end
end
