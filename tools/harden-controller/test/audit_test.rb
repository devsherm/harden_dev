# frozen_string_literal: true

require_relative "orchestration_test_helper"

class AuditTest < OrchestrationTestCase
  def setup
    super
    @ctrl_name = "posts_controller"
    @ctrl_path = create_controller(@ctrl_name)
    seed_controller(@ctrl_name)
    seed_workflow_for_audit
  end

  # ── Fixtures ───────────────────────────────────────────────

  ENHANCE_ANALYSIS = {
    "controller" => "posts_controller",
    "intent" => "Manages CRUD operations for blog posts",
    "architecture_notes" => "Standard scaffold controller",
    "improvement_areas" => [],
    "research_topics" => []
  }.freeze

  READY_ITEMS = {
    "ready_items" => [
      {
        "id" => "item_001",
        "title" => "Add eager loading to index action",
        "description" => "Use includes(:comments) to prevent N+1 queries",
        "impact" => "high",
        "effort" => "low",
        "rationale" => "High impact, low effort",
        "files_likely_affected" => ["app/controllers/blog/posts_controller.rb"]
      },
      {
        "id" => "item_002",
        "title" => "Extract query to named scope",
        "description" => "Move Post.all to a published scope on the model",
        "impact" => "medium",
        "effort" => "medium",
        "rationale" => "Improves maintainability",
        "files_likely_affected" => [
          "app/controllers/blog/posts_controller.rb",
          "app/models/blog/post.rb"
        ]
      },
      {
        "id" => "item_003",
        "title" => "Previously deferred item",
        "description" => "An item that was deferred in a prior cycle",
        "impact" => "low",
        "effort" => "high",
        "rationale" => "Low priority",
        "files_likely_affected" => ["app/controllers/blog/posts_controller.rb"]
      }
    ],
    "excluded_items" => []
  }.freeze

  DEFERRED_ITEMS = [
    {
      "id" => "item_003",
      "title" => "Previously deferred item",
      "description" => "An item that was deferred in a prior cycle",
      "decision" => "DEFER",
      "notes" => "Will revisit next quarter",
      "timestamp" => "2026-01-15T10:00:00Z"
    }
  ].freeze

  REJECTED_ITEMS = [
    {
      "id" => "item_legacy",
      "title" => "A previously rejected item",
      "description" => "Something the operator rejected",
      "decision" => "REJECT",
      "notes" => "Not applicable to our stack",
      "timestamp" => "2026-01-10T09:00:00Z"
    }
  ].freeze

  AUDIT_FIXTURE = {
    "annotated_items" => [
      {
        "id" => "item_001",
        "title" => "Add eager loading to index action",
        "description" => "Use includes(:comments) to prevent N+1 queries",
        "impact" => "high",
        "effort" => "low",
        "rationale" => "High impact, low effort",
        "files_likely_affected" => ["app/controllers/blog/posts_controller.rb"],
        "prior_decision" => nil,
        "prior_notes" => nil,
        "suggested_default" => "TODO"
      },
      {
        "id" => "item_002",
        "title" => "Extract query to named scope",
        "description" => "Move Post.all to a published scope on the model",
        "impact" => "medium",
        "effort" => "medium",
        "rationale" => "Improves maintainability",
        "files_likely_affected" => [
          "app/controllers/blog/posts_controller.rb",
          "app/models/blog/post.rb"
        ],
        "prior_decision" => nil,
        "prior_notes" => nil,
        "suggested_default" => "TODO"
      },
      {
        "id" => "item_003",
        "title" => "Previously deferred item",
        "description" => "An item that was deferred in a prior cycle",
        "impact" => "low",
        "effort" => "high",
        "rationale" => "Low priority",
        "files_likely_affected" => ["app/controllers/blog/posts_controller.rb"],
        "prior_decision" => "deferred",
        "prior_notes" => "Will revisit next quarter",
        "suggested_default" => "DEFER"
      }
    ]
  }.freeze

  def seed_workflow_for_audit
    seed_workflow(@ctrl_name,
                  status: "e_auditing",
                  e_analysis: ENHANCE_ANALYSIS,
                  e_ready_items: READY_ITEMS)
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

  def write_decisions_file(subpath, content)
    full_path = enhance_sidecar_path(subpath)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, JSON.generate(content))
  end

  # ── Annotation (not filtering) ─────────────────────────────

  def test_all_ready_items_appear_in_output
    stub_claude_call(AUDIT_FIXTURE)

    @pipeline.run_audit(@ctrl_name)

    sidecar = read_enhance_sidecar("audit.json")
    assert sidecar.key?("annotated_items"), "Expected annotated_items key in audit.json"
    assert_equal 3, sidecar["annotated_items"].length,
                 "All 3 ready items must appear — audit annotates, not filters"
  end

  def test_new_items_get_todo_default
    stub_claude_call(AUDIT_FIXTURE)

    @pipeline.run_audit(@ctrl_name)

    sidecar = read_enhance_sidecar("audit.json")
    item_001 = sidecar["annotated_items"].find { |i| i["id"] == "item_001" }
    assert_equal "TODO", item_001["suggested_default"],
                 "New item should get TODO default"
    assert_nil item_001["prior_decision"],
               "New item should have no prior decision"
  end

  def test_deferred_items_annotated_with_defer_default
    write_decisions_file(File.join("decisions", "deferred.json"), DEFERRED_ITEMS)
    stub_claude_call(AUDIT_FIXTURE)

    @pipeline.run_audit(@ctrl_name)

    sidecar = read_enhance_sidecar("audit.json")
    item_003 = sidecar["annotated_items"].find { |i| i["id"] == "item_003" }
    assert_equal "DEFER", item_003["suggested_default"],
                 "Previously deferred item should get DEFER default"
    assert_equal "deferred", item_003["prior_decision"],
                 "Previously deferred item should show prior decision"
    assert_equal "Will revisit next quarter", item_003["prior_notes"],
                 "Prior notes should be preserved"
  end

  # ── Prior-decision context ─────────────────────────────────

  def test_deferred_items_included_in_prompt
    write_decisions_file(File.join("decisions", "deferred.json"), DEFERRED_ITEMS)
    captured_prompt = nil
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      captured_prompt = prompt
      JSON.generate(AUDIT_FIXTURE)
    end

    @pipeline.run_audit(@ctrl_name)

    refute_nil captured_prompt
    assert_includes captured_prompt, "Previously deferred item",
                    "Deferred items should appear in prompt"
    assert_includes captured_prompt, "Will revisit next quarter",
                    "Deferred item notes should appear in prompt"
  end

  def test_rejected_items_included_in_prompt
    write_decisions_file(File.join("decisions", "rejected.json"), REJECTED_ITEMS)
    captured_prompt = nil
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      captured_prompt = prompt
      JSON.generate(AUDIT_FIXTURE)
    end

    @pipeline.run_audit(@ctrl_name)

    refute_nil captured_prompt
    assert_includes captured_prompt, "A previously rejected item",
                    "Rejected items should appear in prompt"
    assert_includes captured_prompt, "Not applicable to our stack",
                    "Rejected item notes should appear in prompt"
  end

  def test_ready_items_included_in_prompt
    captured_prompt = nil
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      captured_prompt = prompt
      JSON.generate(AUDIT_FIXTURE)
    end

    @pipeline.run_audit(@ctrl_name)

    refute_nil captured_prompt
    assert_includes captured_prompt, "Add eager loading to index action",
                    "Ready items should appear in prompt"
    assert_includes captured_prompt, "Extract query to named scope",
                    "All ready items should appear in prompt"
  end

  def test_empty_decisions_when_no_files_exist
    # No decisions files written — should pass empty arrays and not raise
    captured_prompt = nil
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      captured_prompt = prompt
      JSON.generate(AUDIT_FIXTURE)
    end

    @pipeline.run_audit(@ctrl_name)

    refute_nil captured_prompt
    # Empty arrays passed — prompt should still render without error
    assert_includes captured_prompt, "[]",
                    "Empty arrays should be included in prompt when no prior decisions exist"
  end

  # ── Sidecar write ──────────────────────────────────────────

  def test_audit_json_written_to_enhance_sidecar
    stub_claude_call(AUDIT_FIXTURE)

    @pipeline.run_audit(@ctrl_name)

    assert enhance_sidecar_exists?("audit.json"), "Expected audit.json to be written"
  end

  def test_audit_json_not_written_to_harden_sidecar
    stub_claude_call(AUDIT_FIXTURE)

    @pipeline.run_audit(@ctrl_name)

    harden_path = File.join(File.dirname(@ctrl_path), ".harden", @ctrl_name, "audit.json")
    refute File.exist?(harden_path), "Should NOT write audit.json under .harden/"
  end

  def test_audit_json_is_valid_json
    stub_claude_call(AUDIT_FIXTURE)

    @pipeline.run_audit(@ctrl_name)

    content = File.read(enhance_sidecar_path("audit.json"))
    parsed = JSON.parse(content)
    assert_instance_of Hash, parsed
  end

  def test_happy_path_returns_parsed_response
    stub_claude_call(AUDIT_FIXTURE)

    result = @pipeline.run_audit(@ctrl_name)

    refute_nil result
    assert result.is_a?(Hash), "Expected Hash return value"
    assert result.key?("annotated_items")
    assert_equal 3, result["annotated_items"].length
  end

  def test_does_not_change_workflow_status
    stub_claude_call(AUDIT_FIXTURE)

    @pipeline.run_audit(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "e_auditing", wf[:status],
                 "run_audit must not set workflow status (that is run_extraction_chain's job)"
  end

  def test_sidecar_write_is_idempotent
    stub_claude_call(AUDIT_FIXTURE)

    @pipeline.run_audit(@ctrl_name)
    @pipeline.run_audit(@ctrl_name)

    sidecar = read_enhance_sidecar("audit.json")
    assert_equal 3, sidecar["annotated_items"].length
  end

  # ── Error handling ─────────────────────────────────────────

  def test_claude_failure_raises
    stub_claude_call_failure("Claude service unavailable")

    assert_raises(RuntimeError) { @pipeline.run_audit(@ctrl_name) }
  end

  def test_claude_failure_does_not_write_sidecar
    stub_claude_call_failure("Claude exploded")

    begin
      @pipeline.run_audit(@ctrl_name)
    rescue RuntimeError
      # expected
    end

    refute enhance_sidecar_exists?("audit.json"),
           "Should not write audit.json when claude_call raises"
  end

  def test_invalid_json_raises
    @pipeline.define_singleton_method(:claude_call) do |_prompt|
      "this is not json"
    end

    assert_raises(RuntimeError) { @pipeline.run_audit(@ctrl_name) }
  end

  def test_cancelled_pipeline_raises
    response = JSON.generate(AUDIT_FIXTURE)
    @pipeline.define_singleton_method(:claude_call) do |_prompt|
      @cancelled = true
      response
    end

    assert_raises(RuntimeError) { @pipeline.run_audit(@ctrl_name) }
  end

  # ── Missing workflow guard ─────────────────────────────────

  def test_returns_nil_for_missing_workflow
    result = @pipeline.run_audit("nonexistent_controller")
    assert_nil result
  end
end

# ── Chain sequencing tests ──────────────────────────────────

class ExtractionChainTest < OrchestrationTestCase
  ENHANCE_ANALYSIS = {
    "controller" => "posts_controller",
    "intent" => "Manages CRUD operations for blog posts",
    "architecture_notes" => "Standard scaffold controller",
    "improvement_areas" => [],
    "research_topics" => ["Rails N+1 prevention"]
  }.freeze

  EXTRACT_RESPONSE = {
    "possible_items" => [
      {
        "id" => "item_001",
        "title" => "Add eager loading",
        "description" => "Use includes()",
        "source" => "Research",
        "files_likely_affected" => ["app/controllers/blog/posts_controller.rb"]
      }
    ]
  }.freeze

  SYNTHESIZE_RESPONSE = {
    "ready_items" => [
      {
        "id" => "item_001",
        "title" => "Add eager loading",
        "description" => "Use includes()",
        "impact" => "high",
        "effort" => "low",
        "rationale" => "High impact, low effort",
        "files_likely_affected" => ["app/controllers/blog/posts_controller.rb"]
      }
    ],
    "excluded_items" => []
  }.freeze

  AUDIT_RESPONSE = {
    "annotated_items" => [
      {
        "id" => "item_001",
        "title" => "Add eager loading",
        "description" => "Use includes()",
        "impact" => "high",
        "effort" => "low",
        "rationale" => "High impact, low effort",
        "files_likely_affected" => ["app/controllers/blog/posts_controller.rb"],
        "prior_decision" => nil,
        "prior_notes" => nil,
        "suggested_default" => "TODO"
      }
    ]
  }.freeze

  def setup
    super
    @ctrl_name = "posts_controller"
    @ctrl_path = create_controller(@ctrl_name)
    seed_controller(@ctrl_name)
    seed_workflow(@ctrl_name,
                  status: "e_extracting",
                  e_analysis: ENHANCE_ANALYSIS,
                  research_topics: [
                    { prompt: "Rails N+1 prevention", status: "completed",
                      result: "Use includes() to prevent N+1 queries" }
                  ])
  end

  # ── Chain status transitions ───────────────────────────────

  def test_chain_transitions_through_all_statuses
    statuses = []
    @pipeline.define_singleton_method(:claude_call) do |_prompt|
      # Capture status at each call point
      wf = @state[:workflows]["posts_controller"]
      statuses << wf[:status]
      JSON.generate(
        case statuses.length
        when 1 then EXTRACT_RESPONSE
        when 2 then SYNTHESIZE_RESPONSE
        else AUDIT_RESPONSE
        end
      )
    end

    # Invoke the chain via the private method
    @pipeline.send(:run_extraction_chain, @ctrl_name)

    # Three claude calls: extract (e_extracting), synthesize (e_synthesizing), audit (e_auditing)
    assert_equal "e_extracting",  statuses[0], "First call should be in e_extracting"
    assert_equal "e_synthesizing", statuses[1], "Second call should be in e_synthesizing"
    assert_equal "e_auditing",    statuses[2], "Third call should be in e_auditing"
  end

  def test_chain_ends_in_awaiting_decisions
    stub_claude_call_sequence([EXTRACT_RESPONSE, SYNTHESIZE_RESPONSE, AUDIT_RESPONSE])

    @pipeline.send(:run_extraction_chain, @ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "e_awaiting_decisions", wf[:status],
                 "Chain must end in e_awaiting_decisions"
  end

  def test_chain_stores_possible_items_in_workflow
    stub_claude_call_sequence([EXTRACT_RESPONSE, SYNTHESIZE_RESPONSE, AUDIT_RESPONSE])

    @pipeline.send(:run_extraction_chain, @ctrl_name)

    wf = workflow_state(@ctrl_name)
    refute_nil wf[:e_possible_items], "Chain must store e_possible_items in workflow"
    assert wf[:e_possible_items].key?("possible_items")
  end

  def test_chain_stores_ready_items_in_workflow
    stub_claude_call_sequence([EXTRACT_RESPONSE, SYNTHESIZE_RESPONSE, AUDIT_RESPONSE])

    @pipeline.send(:run_extraction_chain, @ctrl_name)

    wf = workflow_state(@ctrl_name)
    refute_nil wf[:e_ready_items], "Chain must store e_ready_items in workflow"
    assert wf[:e_ready_items].key?("ready_items")
  end

  def test_chain_stores_audit_in_workflow
    stub_claude_call_sequence([EXTRACT_RESPONSE, SYNTHESIZE_RESPONSE, AUDIT_RESPONSE])

    @pipeline.send(:run_extraction_chain, @ctrl_name)

    wf = workflow_state(@ctrl_name)
    refute_nil wf[:e_audit], "Chain must store e_audit in workflow"
    assert wf[:e_audit].key?("annotated_items")
  end

  def test_chain_writes_all_three_sidecars
    stub_claude_call_sequence([EXTRACT_RESPONSE, SYNTHESIZE_RESPONSE, AUDIT_RESPONSE])

    @pipeline.send(:run_extraction_chain, @ctrl_name)

    ctrl_dir = File.dirname(@ctrl_path)
    enhance_base = File.join(ctrl_dir, ".enhance", @ctrl_name)
    assert File.exist?(File.join(enhance_base, "extract.json")),    "extract.json must be written"
    assert File.exist?(File.join(enhance_base, "synthesize.json")), "synthesize.json must be written"
    assert File.exist?(File.join(enhance_base, "audit.json")),      "audit.json must be written"
  end

  def test_chain_is_called_by_check_research_completion_via_safe_thread
    # When all research topics complete, check_research_completion invokes
    # run_extraction_chain via safe_thread (when scheduler is nil).
    chain_called = false
    @pipeline.define_singleton_method(:run_extraction_chain) do |_name|
      chain_called = true
    end

    # Disable scheduler so safe_thread path is used
    @pipeline.instance_variable_set(:@scheduler, nil)

    # Mark the one topic as completed to trigger completion check
    @pipeline.send(:check_research_completion, @ctrl_name,
                   File.join(@tmpdir, "app", "controllers", "blog", "posts_controller.rb"))

    # The safe_thread fires async — join any threads
    sleep 0.1
    @pipeline.instance_variable_get(:@threads).each { |t| t.join(1) rescue nil }

    assert chain_called, "check_research_completion must call run_extraction_chain via safe_thread"
  end

  def test_chain_is_enqueued_via_scheduler_when_available
    # When a scheduler is present, check_research_completion enqueues to it.
    enqueued = []
    fake_scheduler = Object.new
    fake_scheduler.define_singleton_method(:enqueue) do |item|
      enqueued << item
    end
    @pipeline.instance_variable_set(:@scheduler, fake_scheduler)

    @pipeline.send(:check_research_completion, @ctrl_name,
                   File.join(@tmpdir, "app", "controllers", "blog", "posts_controller.rb"))

    assert_equal 1, enqueued.length,
                 "Expected scheduler.enqueue called once on completion"
    assert_equal :e_extracting, enqueued[0].phase
  end
end
