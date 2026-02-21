# frozen_string_literal: true

require_relative "orchestration_test_helper"

class SynthesisTest < OrchestrationTestCase
  def setup
    super
    @ctrl_name = "posts_controller"
    @ctrl_path = create_controller(@ctrl_name)
    seed_controller(@ctrl_name)
    seed_workflow_for_synthesis
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
      "Rails N+1 prevention patterns for index actions"
    ]
  }.freeze

  POSSIBLE_ITEMS = {
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
      },
      {
        "id" => "item_003",
        "title" => "Already implemented caching",
        "description" => "Add fragment caching — already done",
        "source" => "Analysis",
        "files_likely_affected" => ["app/controllers/blog/posts_controller.rb"]
      }
    ]
  }.freeze

  SYNTHESIZE_FIXTURE = {
    "ready_items" => [
      {
        "id" => "item_001",
        "title" => "Add eager loading to index action",
        "description" => "Use includes(:comments) to prevent N+1 queries",
        "impact" => "high",
        "effort" => "low",
        "rationale" => "High impact because it eliminates N+1, low effort as it's a one-liner",
        "files_likely_affected" => ["app/controllers/blog/posts_controller.rb"]
      },
      {
        "id" => "item_002",
        "title" => "Extract query to named scope",
        "description" => "Move Post.all to a published scope on the model",
        "impact" => "medium",
        "effort" => "medium",
        "rationale" => "Improves maintainability but requires model changes",
        "files_likely_affected" => [
          "app/controllers/blog/posts_controller.rb",
          "app/models/blog/post.rb"
        ]
      }
    ],
    "excluded_items" => [
      {
        "id" => "item_003",
        "title" => "Already implemented caching",
        "reason" => "already_implemented"
      }
    ]
  }.freeze

  def seed_workflow_for_synthesis
    seed_workflow(@ctrl_name,
                  status: "e_synthesizing",
                  e_analysis: ENHANCE_ANALYSIS,
                  e_possible_items: POSSIBLE_ITEMS)
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

  # ── Impact/effort rating ────────────────────────────────────

  def test_happy_path_produces_ready_items_with_ratings
    stub_claude_call(SYNTHESIZE_FIXTURE)

    @pipeline.run_synthesis(@ctrl_name)

    assert enhance_sidecar_exists?("synthesize.json"),
           "Expected synthesize.json to be written"
    sidecar = read_enhance_sidecar("synthesize.json")
    assert sidecar.key?("ready_items"), "Expected ready_items key in synthesize.json"
    assert_equal 2, sidecar["ready_items"].length
  end

  def test_ready_items_have_impact_and_effort_ratings
    stub_claude_call(SYNTHESIZE_FIXTURE)

    @pipeline.run_synthesis(@ctrl_name)

    sidecar = read_enhance_sidecar("synthesize.json")
    item = sidecar["ready_items"].first
    assert item.key?("impact"),   "item must have impact"
    assert item.key?("effort"),   "item must have effort"
    assert item.key?("rationale"), "item must have rationale"
    assert_includes %w[high medium low], item["impact"]
    assert_includes %w[high medium low], item["effort"]
  end

  def test_ready_items_have_required_fields
    stub_claude_call(SYNTHESIZE_FIXTURE)

    @pipeline.run_synthesis(@ctrl_name)

    sidecar = read_enhance_sidecar("synthesize.json")
    item = sidecar["ready_items"].first
    assert item.key?("id"),          "item must have id"
    assert item.key?("title"),       "item must have title"
    assert item.key?("description"), "item must have description"
    assert item.key?("files_likely_affected"), "item must have files_likely_affected"
  end

  # ── Filtering already-implemented items ────────────────────

  def test_excluded_items_are_tracked
    stub_claude_call(SYNTHESIZE_FIXTURE)

    @pipeline.run_synthesis(@ctrl_name)

    sidecar = read_enhance_sidecar("synthesize.json")
    assert sidecar.key?("excluded_items"), "Expected excluded_items key in synthesize.json"
    assert_equal 1, sidecar["excluded_items"].length
    excluded = sidecar["excluded_items"].first
    assert_equal "item_003", excluded["id"]
    assert_equal "already_implemented", excluded["reason"]
  end

  def test_already_implemented_items_not_in_ready_list
    stub_claude_call(SYNTHESIZE_FIXTURE)

    @pipeline.run_synthesis(@ctrl_name)

    sidecar = read_enhance_sidecar("synthesize.json")
    ready_ids = sidecar["ready_items"].map { |i| i["id"] }
    refute_includes ready_ids, "item_003",
                    "Already-implemented item should not appear in ready_items"
  end

  # ── READY item generation ───────────────────────────────────

  def test_happy_path_returns_parsed_response
    stub_claude_call(SYNTHESIZE_FIXTURE)

    result = @pipeline.run_synthesis(@ctrl_name)

    refute_nil result
    assert result.is_a?(Hash), "Expected Hash return value"
    assert result.key?("ready_items")
    assert_equal 2, result["ready_items"].length
  end

  def test_ready_items_use_correct_ids
    stub_claude_call(SYNTHESIZE_FIXTURE)

    @pipeline.run_synthesis(@ctrl_name)

    sidecar = read_enhance_sidecar("synthesize.json")
    ids = sidecar["ready_items"].map { |i| i["id"] }
    assert_equal %w[item_001 item_002], ids
  end

  # ── Prompt includes required inputs ────────────────────────

  def test_analysis_included_in_prompt
    captured_prompt = nil
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      captured_prompt = prompt
      JSON.generate(SYNTHESIZE_FIXTURE)
    end

    @pipeline.run_synthesis(@ctrl_name)

    refute_nil captured_prompt
    assert_includes captured_prompt, "Manages CRUD operations for blog posts",
                    "Expected analysis intent in prompt"
  end

  def test_possible_items_included_in_prompt
    captured_prompt = nil
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      captured_prompt = prompt
      JSON.generate(SYNTHESIZE_FIXTURE)
    end

    @pipeline.run_synthesis(@ctrl_name)

    refute_nil captured_prompt
    assert_includes captured_prompt, "Add eager loading to index action",
                    "Expected possible item title in prompt"
  end

  def test_controller_source_included_in_prompt
    captured_prompt = nil
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      captured_prompt = prompt
      JSON.generate(SYNTHESIZE_FIXTURE)
    end

    @pipeline.run_synthesis(@ctrl_name)

    refute_nil captured_prompt
    assert_includes captured_prompt, "Blog::PostsController",
                    "Expected controller source in prompt"
  end

  # ── Does NOT set workflow status ───────────────────────────

  def test_does_not_change_workflow_status
    stub_claude_call(SYNTHESIZE_FIXTURE)

    @pipeline.run_synthesis(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "e_synthesizing", wf[:status],
                 "run_synthesis must not set workflow status (that is run_extraction_chain's job)"
  end

  # ── Sidecar write ──────────────────────────────────────────

  def test_synthesize_json_is_valid_json
    stub_claude_call(SYNTHESIZE_FIXTURE)

    @pipeline.run_synthesis(@ctrl_name)

    content = File.read(enhance_sidecar_path("synthesize.json"))
    parsed = JSON.parse(content)
    assert_instance_of Hash, parsed
  end

  def test_sidecar_written_under_enhance_dir
    stub_claude_call(SYNTHESIZE_FIXTURE)

    @pipeline.run_synthesis(@ctrl_name)

    harden_path = File.join(File.dirname(@ctrl_path), ".harden", @ctrl_name, "synthesize.json")
    enhance_path = File.join(File.dirname(@ctrl_path), ".enhance", @ctrl_name, "synthesize.json")
    assert File.exist?(enhance_path), "Expected synthesize.json under .enhance/"
    refute File.exist?(harden_path), "Should NOT write synthesize.json under .harden/"
  end

  def test_sidecar_content_includes_all_ready_items
    stub_claude_call(SYNTHESIZE_FIXTURE)

    @pipeline.run_synthesis(@ctrl_name)

    sidecar = read_enhance_sidecar("synthesize.json")
    titles = sidecar["ready_items"].map { |i| i["title"] }
    assert_includes titles, "Add eager loading to index action"
    assert_includes titles, "Extract query to named scope"
  end

  def test_sidecar_write_is_idempotent
    stub_claude_call(SYNTHESIZE_FIXTURE)

    @pipeline.run_synthesis(@ctrl_name)
    @pipeline.run_synthesis(@ctrl_name)

    sidecar = read_enhance_sidecar("synthesize.json")
    assert_equal 2, sidecar["ready_items"].length
  end

  # ── Error handling ─────────────────────────────────────────

  def test_claude_failure_raises
    stub_claude_call_failure("Claude service unavailable")

    assert_raises(RuntimeError) { @pipeline.run_synthesis(@ctrl_name) }
  end

  def test_claude_failure_does_not_write_sidecar
    stub_claude_call_failure("Claude exploded")

    begin
      @pipeline.run_synthesis(@ctrl_name)
    rescue RuntimeError
      # expected
    end

    refute enhance_sidecar_exists?("synthesize.json"),
           "Should not write synthesize.json when claude_call raises"
  end

  def test_invalid_json_raises
    @pipeline.define_singleton_method(:claude_call) do |_prompt|
      "this is not json"
    end

    assert_raises(RuntimeError) { @pipeline.run_synthesis(@ctrl_name) }
  end

  def test_cancelled_pipeline_raises
    response = JSON.generate(SYNTHESIZE_FIXTURE)
    @pipeline.define_singleton_method(:claude_call) do |_prompt|
      @cancelled = true
      response
    end

    assert_raises(RuntimeError) { @pipeline.run_synthesis(@ctrl_name) }
  end

  # ── Missing workflow guard ─────────────────────────────────

  def test_returns_nil_for_missing_workflow
    result = @pipeline.run_synthesis("nonexistent_controller")
    assert_nil result
  end
end
