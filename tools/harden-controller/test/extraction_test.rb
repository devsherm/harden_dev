# frozen_string_literal: true

require_relative "orchestration_test_helper"

class ExtractionTest < OrchestrationTestCase
  def setup
    super
    @ctrl_name = "posts_controller"
    @ctrl_path = create_controller(@ctrl_name)
    seed_controller(@ctrl_name)
    seed_workflow_with_research
  end

  # ── Fixtures ───────────────────────────────────────────────

  ENHANCE_ANALYSIS = {
    "controller" => "posts_controller",
    "intent" => "Manages CRUD operations for blog posts",
    "architecture_notes" => "Standard scaffold controller",
    "improvement_areas" => [
      { "area" => "performance", "description" => "N+1 queries on index action" }
    ],
    "research_topics" => [
      "Rails N+1 prevention patterns for index actions",
      "ActiveRecord scopes for query encapsulation"
    ]
  }.freeze

  RESEARCH_RESULTS = [
    "N+1 queries can be prevented using eager loading with includes()...",
    "ActiveRecord scopes encapsulate reusable query logic..."
  ].freeze

  EXTRACT_FIXTURE = {
    "possible_items" => [
      {
        "id" => "item_001",
        "title" => "Add eager loading to index action",
        "description" => "Use includes(:comments) to prevent N+1 queries",
        "source" => "Research on N+1 prevention",
        "files_likely_affected" => ["app/controllers/blog/posts_controller.rb"]
      },
      {
        "id" => "item_002",
        "title" => "Extract query to named scope",
        "description" => "Move Post.all to a published scope on the model",
        "source" => "Research on ActiveRecord scopes",
        "files_likely_affected" => [
          "app/controllers/blog/posts_controller.rb",
          "app/models/blog/post.rb"
        ]
      }
    ]
  }.freeze

  def seed_workflow_with_research(statuses: nil)
    topics = ENHANCE_ANALYSIS["research_topics"].each_with_index.map do |prompt, i|
      status = statuses ? statuses[i] : "completed"
      result = status == "completed" ? RESEARCH_RESULTS[i] : nil
      { prompt: prompt, status: status, result: result }
    end
    seed_workflow(@ctrl_name,
                  status: "e_extracting",
                  e_analysis: ENHANCE_ANALYSIS,
                  research_topics: topics)
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

  # ── Happy path: POSSIBLE item generation ──────────────────

  def test_happy_path_produces_possible_items
    stub_claude_call(EXTRACT_FIXTURE)

    @pipeline.run_extraction(@ctrl_name)

    assert enhance_sidecar_exists?("extract.json"),
           "Expected extract.json to be written"
    sidecar = read_enhance_sidecar("extract.json")
    assert sidecar.key?("possible_items"), "Expected possible_items key in extract.json"
    assert_equal 2, sidecar["possible_items"].length
  end

  def test_happy_path_returns_parsed_response
    stub_claude_call(EXTRACT_FIXTURE)

    result = @pipeline.run_extraction(@ctrl_name)

    refute_nil result
    assert result.is_a?(Hash), "Expected Hash return value"
    assert result.key?("possible_items")
    assert_equal 2, result["possible_items"].length
  end

  def test_possible_items_have_required_fields
    stub_claude_call(EXTRACT_FIXTURE)

    @pipeline.run_extraction(@ctrl_name)

    sidecar = read_enhance_sidecar("extract.json")
    item = sidecar["possible_items"].first
    assert item.key?("id"),          "item must have id"
    assert item.key?("title"),       "item must have title"
    assert item.key?("description"), "item must have description"
    assert item.key?("source"),      "item must have source"
    assert item.key?("files_likely_affected"), "item must have files_likely_affected"
  end

  # ── POSSIBLE item output format ────────────────────────────

  def test_possible_items_use_correct_ids
    stub_claude_call(EXTRACT_FIXTURE)

    @pipeline.run_extraction(@ctrl_name)

    sidecar = read_enhance_sidecar("extract.json")
    ids = sidecar["possible_items"].map { |i| i["id"] }
    assert_equal %w[item_001 item_002], ids
  end

  def test_extract_json_is_valid_json
    stub_claude_call(EXTRACT_FIXTURE)

    @pipeline.run_extraction(@ctrl_name)

    content = File.read(enhance_sidecar_path("extract.json"))
    parsed = JSON.parse(content)
    assert_instance_of Hash, parsed
  end

  def test_sidecar_written_under_enhance_dir
    stub_claude_call(EXTRACT_FIXTURE)

    @pipeline.run_extraction(@ctrl_name)

    # Verify under .enhance/, not .harden/
    harden_path = File.join(File.dirname(@ctrl_path), ".harden", @ctrl_name, "extract.json")
    enhance_path = File.join(File.dirname(@ctrl_path), ".enhance", @ctrl_name, "extract.json")
    assert File.exist?(enhance_path), "Expected extract.json under .enhance/"
    refute File.exist?(harden_path), "Should NOT write extract.json under .harden/"
  end

  # ── Does NOT set workflow status ───────────────────────────

  def test_does_not_change_workflow_status
    stub_claude_call(EXTRACT_FIXTURE)

    @pipeline.run_extraction(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "e_extracting", wf[:status],
                 "run_extraction must not set workflow status (that is run_extraction_chain's job)"
  end

  # ── Research results from workflow ─────────────────────────

  def test_uses_completed_research_results
    # Verify the prompt includes research results (indirectly via claude_call capture)
    captured_prompt = nil
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      captured_prompt = prompt
      JSON.generate(EXTRACT_FIXTURE)
    end

    @pipeline.run_extraction(@ctrl_name)

    refute_nil captured_prompt
    assert_includes captured_prompt, "N+1 queries can be prevented using eager loading",
                    "Expected first research result in prompt"
    assert_includes captured_prompt, "ActiveRecord scopes encapsulate reusable query logic",
                    "Expected second research result in prompt"
  end

  def test_analysis_included_in_prompt
    captured_prompt = nil
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      captured_prompt = prompt
      JSON.generate(EXTRACT_FIXTURE)
    end

    @pipeline.run_extraction(@ctrl_name)

    refute_nil captured_prompt
    assert_includes captured_prompt, "Manages CRUD operations for blog posts",
                    "Expected analysis intent in prompt"
  end

  def test_rejected_research_topics_excluded_from_prompt
    # Seed with one rejected topic
    topics = ENHANCE_ANALYSIS["research_topics"].each_with_index.map do |prompt, i|
      if i == 0
        { prompt: prompt, status: "rejected", result: nil }
      else
        { prompt: prompt, status: "completed", result: RESEARCH_RESULTS[i] }
      end
    end
    @pipeline.instance_variable_get(:@mutex).synchronize do
      wf = @pipeline.instance_variable_get(:@state)[:workflows][@ctrl_name]
      wf[:research_topics] = topics
    end

    captured_prompt = nil
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      captured_prompt = prompt
      JSON.generate(EXTRACT_FIXTURE)
    end

    @pipeline.run_extraction(@ctrl_name)

    refute_nil captured_prompt
    # First topic was rejected — its result should not appear
    refute_includes captured_prompt, "N+1 queries can be prevented using eager loading",
                    "Rejected topic result should be excluded from prompt"
    # Second topic was completed — its result should appear
    assert_includes captured_prompt, "ActiveRecord scopes encapsulate reusable query logic",
                    "Completed topic result should be included in prompt"
  end

  # ── Error handling ─────────────────────────────────────────

  def test_claude_failure_raises
    stub_claude_call_failure("Claude service unavailable")

    assert_raises(RuntimeError) { @pipeline.run_extraction(@ctrl_name) }
  end

  def test_claude_failure_does_not_write_sidecar
    stub_claude_call_failure("Claude exploded")

    begin
      @pipeline.run_extraction(@ctrl_name)
    rescue RuntimeError
      # expected
    end

    refute enhance_sidecar_exists?("extract.json"),
           "Should not write extract.json when claude_call raises"
  end

  def test_invalid_json_raises
    @pipeline.define_singleton_method(:claude_call) do |_prompt|
      "this is not json"
    end

    assert_raises(RuntimeError) { @pipeline.run_extraction(@ctrl_name) }
  end

  def test_cancelled_pipeline_raises
    response = JSON.generate(EXTRACT_FIXTURE)
    @pipeline.define_singleton_method(:claude_call) do |_prompt|
      @cancelled = true
      response
    end

    assert_raises(RuntimeError) { @pipeline.run_extraction(@ctrl_name) }
  end

  # ── Sidecar write ──────────────────────────────────────────

  def test_sidecar_content_includes_all_items
    stub_claude_call(EXTRACT_FIXTURE)

    @pipeline.run_extraction(@ctrl_name)

    sidecar = read_enhance_sidecar("extract.json")
    titles = sidecar["possible_items"].map { |i| i["title"] }
    assert_includes titles, "Add eager loading to index action"
    assert_includes titles, "Extract query to named scope"
  end

  def test_sidecar_write_is_idempotent
    stub_claude_call(EXTRACT_FIXTURE)

    @pipeline.run_extraction(@ctrl_name)
    @pipeline.run_extraction(@ctrl_name)

    # Should overwrite without error
    sidecar = read_enhance_sidecar("extract.json")
    assert_equal 2, sidecar["possible_items"].length
  end

  # ── Missing workflow guard ─────────────────────────────────

  def test_returns_nil_for_missing_workflow
    result = @pipeline.run_extraction("nonexistent_controller")
    assert_nil result
  end
end
