# frozen_string_literal: true

require_relative "orchestration_test_helper"

class EnhanceAnalysisTest < OrchestrationTestCase
  def setup
    super
    @ctrl_name = "posts_controller"
    @ctrl_path = create_controller(@ctrl_name)
    seed_controller(@ctrl_name)
  end

  # ── Fixtures ───────────────────────────────────────────────

  def enhance_analysis_fixture
    {
      "controller" => "posts_controller",
      "intent" => "Manages CRUD operations for blog posts",
      "architecture_notes" => "Standard scaffold controller with no service objects",
      "improvement_areas" => [
        { "area" => "performance", "description" => "N+1 queries on index action" },
        { "area" => "maintainability", "description" => "Consider extracting query logic to scope" }
      ],
      "research_topics" => [
        "Rails N+1 prevention patterns for index actions",
        "ActiveRecord scopes for query encapsulation"
      ]
    }
  end

  def seed_h_complete_workflow(name)
    seed_workflow(name, status: "h_complete", verification: verification_fixture)
  end

  def seed_e_enhance_complete_workflow(name)
    seed_workflow(name, status: "e_enhance_complete", e_analysis: enhance_analysis_fixture,
                  research_topics: [], e_decisions: {})
  end

  def enhance_sidecar_path(filename)
    File.join(File.dirname(@ctrl_path), ".enhance", @ctrl_name, filename)
  end

  def enhance_sidecar_exists?(filename)
    File.exist?(enhance_sidecar_path(filename))
  end

  def read_enhance_sidecar(filename)
    JSON.parse(File.read(enhance_sidecar_path(filename)))
  end

  # ── Happy path ─────────────────────────────────────────────

  def test_happy_path_produces_structured_output_and_research_topics
    seed_h_complete_workflow(@ctrl_name)
    stub_claude_call(enhance_analysis_fixture)

    @pipeline.run_enhance_analysis(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "e_awaiting_research", wf[:status]
    assert_equal "enhance", wf[:mode]

    # Analysis stored in workflow
    assert_equal "Manages CRUD operations for blog posts", wf[:e_analysis]["intent"]
    assert_equal 2, wf[:e_analysis]["improvement_areas"].length
    assert_equal 2, wf[:e_analysis]["research_topics"].length

    # Research topics built as topic objects
    topics = wf[:research_topics]
    assert_equal 2, topics.length
    assert_equal "Rails N+1 prevention patterns for index actions", topics[0][:prompt]
    assert_equal "pending", topics[0][:status]
    assert_nil topics[0][:result]
    assert_equal "ActiveRecord scopes for query encapsulation", topics[1][:prompt]
    assert_equal "pending", topics[1][:status]
  end

  def test_happy_path_writes_analysis_sidecar
    seed_h_complete_workflow(@ctrl_name)
    stub_claude_call(enhance_analysis_fixture)

    @pipeline.run_enhance_analysis(@ctrl_name)

    assert enhance_sidecar_exists?("analysis.json"),
           "Expected .enhance/posts_controller/analysis.json to exist"

    sidecar = read_enhance_sidecar("analysis.json")
    assert_equal "Manages CRUD operations for blog posts", sidecar["intent"]
    assert_equal 2, sidecar["research_topics"].length
  end

  def test_happy_path_stores_prompt
    seed_h_complete_workflow(@ctrl_name)
    stub_claude_call(enhance_analysis_fixture)

    @pipeline.run_enhance_analysis(@ctrl_name)

    prompt = @pipeline.get_prompt(@ctrl_name, :e_analyze)
    refute_nil prompt
    assert_includes prompt, @ctrl_name
  end

  # ── Entry from e_enhance_complete ──────────────────────────

  def test_entry_from_e_enhance_complete_succeeds
    seed_e_enhance_complete_workflow(@ctrl_name)
    stub_claude_call(enhance_analysis_fixture)

    @pipeline.run_enhance_analysis(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "e_awaiting_research", wf[:status]
    assert_equal "enhance", wf[:mode]
  end

  # ── Hardening prerequisite check ───────────────────────────
  # try_transition enforces the guard — we test run_enhance_analysis is
  # callable after the transition already moved status to e_analyzing.
  # What we verify here: if run_enhance_analysis is called on a workflow that
  # was NOT properly transitioned (wrong status), it still transitions it
  # to e_analyzing (the method sets status on entry).

  def test_method_sets_e_analyzing_status_on_entry
    # Seed with pending status (simulates calling before transition guard)
    seed_workflow(@ctrl_name, status: "pending")
    stub_claude_call(enhance_analysis_fixture)

    @pipeline.run_enhance_analysis(@ctrl_name)

    # Even from pending, method proceeds (try_transition guard is done at route level)
    wf = workflow_state(@ctrl_name)
    assert_equal "e_awaiting_research", wf[:status]
  end

  # ── Error handling ─────────────────────────────────────────

  def test_claude_failure_sets_error_status
    seed_h_complete_workflow(@ctrl_name)
    stub_claude_call_failure("Claude service unavailable")

    @pipeline.run_enhance_analysis(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "error", wf[:status]
    assert_includes wf[:error], "Claude service unavailable"

    errors = global_errors
    assert errors.any? { |e| e[:message].include?("Enhance analysis failed") },
           "Expected global error about enhance analysis failure, got: #{errors}"
  end

  def test_invalid_json_sets_error
    seed_h_complete_workflow(@ctrl_name)
    calls = @claude_calls
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      calls << { prompt: prompt }
      "this is not json"
    end

    @pipeline.run_enhance_analysis(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "error", wf[:status]
    assert_match(/parse|JSON/i, wf[:error])
  end

  def test_cancelled_pipeline_sets_error
    seed_h_complete_workflow(@ctrl_name)
    response = JSON.generate(enhance_analysis_fixture)
    calls = @claude_calls
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      calls << { prompt: prompt }
      @cancelled = true
      response
    end

    @pipeline.run_enhance_analysis(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "error", wf[:status]
    assert_match(/cancelled/i, wf[:error])
  end

  def test_error_does_not_write_sidecar
    seed_h_complete_workflow(@ctrl_name)
    stub_claude_call_failure("Claude exploded")

    @pipeline.run_enhance_analysis(@ctrl_name)

    refute enhance_sidecar_exists?("analysis.json"),
           "Should not have written analysis.json on error"
  end

  # ── Mode field ─────────────────────────────────────────────

  def test_mode_set_to_enhance
    seed_h_complete_workflow(@ctrl_name)
    stub_claude_call(enhance_analysis_fixture)

    @pipeline.run_enhance_analysis(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "enhance", wf[:mode]
  end

  # ── Sidecar write verification ──────────────────────────────

  def test_sidecar_written_under_enhance_dir
    seed_h_complete_workflow(@ctrl_name)
    stub_claude_call(enhance_analysis_fixture)

    @pipeline.run_enhance_analysis(@ctrl_name)

    # Verify it's in .enhance/ not .harden/
    harden_path = File.join(File.dirname(@ctrl_path), ".harden", @ctrl_name, "analysis.json")
    enhance_path = File.join(File.dirname(@ctrl_path), ".enhance", @ctrl_name, "analysis.json")
    assert File.exist?(enhance_path), "Expected analysis.json under .enhance/"
    refute File.exist?(harden_path), "Should NOT have written analysis.json under .harden/"
  end

  def test_sidecar_content_is_valid_json
    seed_h_complete_workflow(@ctrl_name)
    stub_claude_call(enhance_analysis_fixture)

    @pipeline.run_enhance_analysis(@ctrl_name)

    content = File.read(enhance_sidecar_path("analysis.json"))
    parsed = JSON.parse(content)
    assert_instance_of Hash, parsed
    assert parsed.key?("intent")
    assert parsed.key?("research_topics")
  end

  # ── Empty research topics ────────────────────────────────────

  def test_empty_research_topics_produces_empty_array
    seed_h_complete_workflow(@ctrl_name)
    fixture = enhance_analysis_fixture.merge("research_topics" => [])
    stub_claude_call(fixture)

    @pipeline.run_enhance_analysis(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "e_awaiting_research", wf[:status]
    assert_equal [], wf[:research_topics]
  end
end
