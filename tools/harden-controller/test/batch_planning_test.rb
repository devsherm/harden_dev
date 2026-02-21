# frozen_string_literal: true

require_relative "orchestration_test_helper"

class BatchPlanningTest < OrchestrationTestCase
  def setup
    super
    @ctrl_name = "posts_controller"
    @ctrl_path = create_controller(@ctrl_name)
    seed_controller(@ctrl_name)
    seed_workflow_for_batch_planning
  end

  # ── Fixtures ───────────────────────────────────────────────

  ENHANCE_ANALYSIS = {
    "controller" => "posts_controller",
    "intent" => "Manages CRUD operations for blog posts",
    "architecture_notes" => "Standard scaffold controller",
    "improvement_areas" => [],
    "research_topics" => []
  }.freeze

  AUDIT_FIXTURE = {
    "annotated_items" => [
      {
        "id" => "item_001",
        "title" => "Add eager loading to index action",
        "description" => "Use includes(:comments) to prevent N+1 queries",
        "impact" => "high",
        "effort" => "low",
        "suggested_default" => "TODO",
        "prior_decision" => nil,
        "prior_notes" => nil
      },
      {
        "id" => "item_002",
        "title" => "Extract query to named scope",
        "description" => "Move Post.all to a published scope on the model",
        "impact" => "medium",
        "effort" => "medium",
        "suggested_default" => "TODO",
        "prior_decision" => nil,
        "prior_notes" => nil
      },
      {
        "id" => "item_003",
        "title" => "Low priority item",
        "description" => "A low priority enhancement",
        "impact" => "low",
        "effort" => "high",
        "suggested_default" => "DEFER",
        "prior_decision" => nil,
        "prior_notes" => nil
      }
    ]
  }.freeze

  DECISIONS_FIXTURE = {
    "item_001" => "TODO",
    "item_002" => "TODO",
    "item_003" => "DEFER"
  }.freeze

  BATCH_PLAN_RESPONSE = {
    "batches" => [
      {
        "id" => "batch_001",
        "title" => "Add eager loading",
        "items" => ["item_001"],
        "write_targets" => ["app/controllers/blog/posts_controller.rb"],
        "estimated_effort" => "low",
        "rationale" => "Low effort, high impact — do this first"
      },
      {
        "id" => "batch_002",
        "title" => "Extract query scope",
        "items" => ["item_002"],
        "write_targets" => [
          "app/controllers/blog/posts_controller.rb",
          "app/models/blog/post.rb"
        ],
        "estimated_effort" => "medium",
        "rationale" => "Medium effort — needs model change"
      }
    ]
  }.freeze

  def seed_workflow_for_batch_planning
    seed_workflow(@ctrl_name,
                  status: "e_planning_batches",
                  e_analysis: ENHANCE_ANALYSIS,
                  e_audit: AUDIT_FIXTURE,
                  e_decisions: DECISIONS_FIXTURE)
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

  # ── Happy path ────────────────────────────────────────────

  def test_happy_path_returns_parsed_response
    stub_claude_call(BATCH_PLAN_RESPONSE)

    result = @pipeline.run_batch_planning(@ctrl_name)

    refute_nil result
    assert result.is_a?(Hash), "Expected Hash return value"
    assert result.key?("batches"), "Expected batches key in response"
    assert_equal 2, result["batches"].length
  end

  # ── Workflow status transitions ────────────────────────────

  def test_status_transitions_to_awaiting_batch_approval
    stub_claude_call(BATCH_PLAN_RESPONSE)

    @pipeline.run_batch_planning(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "e_awaiting_batch_approval", wf[:status],
                 "Status must transition to e_awaiting_batch_approval after batch planning"
  end

  # ── Batch storage in workflow ─────────────────────────────

  def test_batches_stored_in_workflow
    stub_claude_call(BATCH_PLAN_RESPONSE)

    @pipeline.run_batch_planning(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    refute_nil wf[:e_batches], "Expected e_batches stored in workflow"
    assert wf[:e_batches].key?("batches"), "e_batches must have batches key"
  end

  def test_batch_ids_stored_correctly
    stub_claude_call(BATCH_PLAN_RESPONSE)

    @pipeline.run_batch_planning(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    batch_ids = wf[:e_batches]["batches"].map { |b| b["id"] }
    assert_includes batch_ids, "batch_001"
    assert_includes batch_ids, "batch_002"
  end

  # ── Sidecar write ─────────────────────────────────────────

  def test_batches_json_written_to_enhance_sidecar
    stub_claude_call(BATCH_PLAN_RESPONSE)

    @pipeline.run_batch_planning(@ctrl_name)

    assert enhance_sidecar_exists?("batches.json"),
           "Expected batches.json to be written in enhance sidecar"
  end

  def test_batches_json_not_written_to_harden_sidecar
    stub_claude_call(BATCH_PLAN_RESPONSE)

    @pipeline.run_batch_planning(@ctrl_name)

    harden_path = File.join(File.dirname(@ctrl_path), ".harden", @ctrl_name, "batches.json")
    refute File.exist?(harden_path), "Should NOT write batches.json under .harden/"
  end

  def test_batches_json_is_valid_json
    stub_claude_call(BATCH_PLAN_RESPONSE)

    @pipeline.run_batch_planning(@ctrl_name)

    content = File.read(enhance_sidecar_path("batches.json"))
    parsed = JSON.parse(content)
    assert_instance_of Hash, parsed
    assert parsed.key?("batches")
  end

  def test_batches_json_content_matches_response
    stub_claude_call(BATCH_PLAN_RESPONSE)

    @pipeline.run_batch_planning(@ctrl_name)

    sidecar = read_enhance_sidecar("batches.json")
    assert_equal 2, sidecar["batches"].length
    assert_equal "batch_001", sidecar["batches"][0]["id"]
    assert_equal "batch_002", sidecar["batches"][1]["id"]
  end

  # ── Write targets ─────────────────────────────────────────

  def test_write_targets_preserved_in_sidecar
    stub_claude_call(BATCH_PLAN_RESPONSE)

    @pipeline.run_batch_planning(@ctrl_name)

    sidecar = read_enhance_sidecar("batches.json")
    batch_001 = sidecar["batches"].find { |b| b["id"] == "batch_001" }
    assert_equal ["app/controllers/blog/posts_controller.rb"],
                 batch_001["write_targets"]

    batch_002 = sidecar["batches"].find { |b| b["id"] == "batch_002" }
    assert_includes batch_002["write_targets"],
                    "app/controllers/blog/posts_controller.rb"
    assert_includes batch_002["write_targets"], "app/models/blog/post.rb"
  end

  # ── TODO items filter ─────────────────────────────────────

  def test_only_todo_items_passed_to_prompt
    captured_prompt = nil
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      captured_prompt = prompt
      JSON.generate(BATCH_PLAN_RESPONSE)
    end

    @pipeline.run_batch_planning(@ctrl_name)

    refute_nil captured_prompt
    # TODO items should be in prompt
    assert_includes captured_prompt, "item_001",
                    "item_001 (TODO) should appear in batch_plan prompt"
    assert_includes captured_prompt, "item_002",
                    "item_002 (TODO) should appear in batch_plan prompt"
    # DEFER/REJECT items must NOT be in prompt as approved TODO items
    refute_includes captured_prompt, "item_003",
                    "item_003 (DEFER) should not appear in batch_plan prompt"
  end

  def test_analysis_and_source_passed_to_prompt
    captured_prompt = nil
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      captured_prompt = prompt
      JSON.generate(BATCH_PLAN_RESPONSE)
    end

    @pipeline.run_batch_planning(@ctrl_name)

    refute_nil captured_prompt
    assert_includes captured_prompt, "Manages CRUD operations for blog posts",
                    "Analysis intent should appear in prompt"
    assert_includes captured_prompt, "Blog::PostsController",
                    "Controller source should appear in prompt"
  end

  # ── Operator notes ────────────────────────────────────────

  def test_operator_notes_included_in_prompt
    captured_prompt = nil
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      captured_prompt = prompt
      JSON.generate(BATCH_PLAN_RESPONSE)
    end

    @pipeline.run_batch_planning(@ctrl_name, operator_notes: "Prefer small batches")

    refute_nil captured_prompt
    assert_includes captured_prompt, "Prefer small batches",
                    "Operator notes should appear in prompt"
  end

  def test_no_operator_notes_omitted_from_prompt
    captured_prompt = nil
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      captured_prompt = prompt
      JSON.generate(BATCH_PLAN_RESPONSE)
    end

    @pipeline.run_batch_planning(@ctrl_name)

    refute_nil captured_prompt
    refute_includes captured_prompt, "Operator Notes",
                    "Operator Notes section should not appear when no notes given"
  end

  # ── Returns nil for missing workflow ──────────────────────

  def test_returns_nil_for_missing_workflow
    stub_claude_call(BATCH_PLAN_RESPONSE)

    result = @pipeline.run_batch_planning("nonexistent_controller")
    assert_nil result
  end

  # ── Error handling ────────────────────────────────────────

  def test_claude_failure_raises
    stub_claude_call_failure("Claude service unavailable")

    assert_raises(RuntimeError) { @pipeline.run_batch_planning(@ctrl_name) }
  end

  def test_claude_failure_does_not_write_sidecar
    stub_claude_call_failure("Claude exploded")

    begin
      @pipeline.run_batch_planning(@ctrl_name)
    rescue RuntimeError
      # expected
    end

    refute enhance_sidecar_exists?("batches.json"),
           "Should not write batches.json when claude_call raises"
  end

  def test_invalid_json_raises
    @pipeline.define_singleton_method(:claude_call) do |_prompt|
      "this is not json"
    end

    assert_raises(RuntimeError) { @pipeline.run_batch_planning(@ctrl_name) }
  end

  def test_cancelled_pipeline_raises
    response = JSON.generate(BATCH_PLAN_RESPONSE)
    @pipeline.define_singleton_method(:claude_call) do |_prompt|
      @cancelled = true
      response
    end

    assert_raises(RuntimeError) { @pipeline.run_batch_planning(@ctrl_name) }
  end
end

# ── Batch re-planning tests ──────────────────────────────────────────────────

class BatchReplanningTest < OrchestrationTestCase
  ENHANCE_ANALYSIS = {
    "controller" => "posts_controller",
    "intent" => "Manages CRUD operations for blog posts",
    "architecture_notes" => "Standard scaffold controller",
    "improvement_areas" => [],
    "research_topics" => []
  }.freeze

  AUDIT_FIXTURE = {
    "annotated_items" => [
      {
        "id" => "item_001",
        "title" => "Add eager loading",
        "description" => "Use includes()",
        "impact" => "high",
        "effort" => "low",
        "suggested_default" => "TODO",
        "prior_decision" => nil,
        "prior_notes" => nil
      }
    ]
  }.freeze

  DECISIONS_FIXTURE = { "item_001" => "TODO" }.freeze

  INITIAL_BATCH_PLAN = {
    "batches" => [
      {
        "id" => "batch_001",
        "title" => "Add eager loading",
        "items" => ["item_001"],
        "write_targets" => ["app/controllers/blog/posts_controller.rb"],
        "estimated_effort" => "low",
        "rationale" => "Initial plan"
      }
    ]
  }.freeze

  REPLANNED_BATCH_PLAN = {
    "batches" => [
      {
        "id" => "batch_a",
        "title" => "Add eager loading (revised)",
        "items" => ["item_001"],
        "write_targets" => ["app/controllers/blog/posts_controller.rb"],
        "estimated_effort" => "low",
        "rationale" => "Revised plan per operator notes"
      }
    ]
  }.freeze

  def setup
    super
    @ctrl_name = "posts_controller"
    @ctrl_path = create_controller(@ctrl_name)
    seed_controller(@ctrl_name)
    seed_workflow(@ctrl_name,
                  status: "e_awaiting_batch_approval",
                  e_analysis: ENHANCE_ANALYSIS,
                  e_audit: AUDIT_FIXTURE,
                  e_decisions: DECISIONS_FIXTURE,
                  e_batches: INITIAL_BATCH_PLAN)
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

  # ── Happy path ────────────────────────────────────────────

  def test_replan_returns_success
    stub_claude_call(REPLANNED_BATCH_PLAN)

    ok, err = @pipeline.replan_batches(@ctrl_name)

    assert ok, "Expected success, got error: #{err}"
    assert_nil err
  end

  def test_replan_cycles_through_planning_batches_status
    statuses = []
    @pipeline.define_singleton_method(:claude_call) do |_prompt|
      wf_snap = @state[:workflows]["posts_controller"]
      statuses << (wf_snap ? wf_snap[:status] : nil)
      JSON.generate(REPLANNED_BATCH_PLAN)
    end

    @pipeline.replan_batches(@ctrl_name)

    # During claude_call, status should be e_planning_batches
    assert_equal "e_planning_batches", statuses[0],
                 "During replan claude call, status must be e_planning_batches"
  end

  def test_replan_ends_in_awaiting_batch_approval
    stub_claude_call(REPLANNED_BATCH_PLAN)

    @pipeline.replan_batches(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "e_awaiting_batch_approval", wf[:status],
                 "After replan, status must return to e_awaiting_batch_approval"
  end

  def test_replan_updates_batches_in_workflow
    stub_claude_call(REPLANNED_BATCH_PLAN)

    @pipeline.replan_batches(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    refute_nil wf[:e_batches]
    batch_ids = wf[:e_batches]["batches"].map { |b| b["id"] }
    assert_includes batch_ids, "batch_a",
                    "Replanned batches should replace old batches"
  end

  def test_replan_updates_sidecar
    stub_claude_call(REPLANNED_BATCH_PLAN)

    @pipeline.replan_batches(@ctrl_name)

    assert enhance_sidecar_exists?("batches.json"),
           "batches.json must be written after replan"
    sidecar = read_enhance_sidecar("batches.json")
    batch_ids = sidecar["batches"].map { |b| b["id"] }
    assert_includes batch_ids, "batch_a",
                    "batches.json should contain replanned batches"
  end

  # ── Operator notes in replan ──────────────────────────────

  def test_replan_with_operator_notes
    captured_prompt = nil
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      captured_prompt = prompt
      JSON.generate(REPLANNED_BATCH_PLAN)
    end

    @pipeline.replan_batches(@ctrl_name, operator_notes: "Keep batches small")

    refute_nil captured_prompt
    assert_includes captured_prompt, "Keep batches small",
                    "Operator notes should appear in replan prompt"
  end

  # ── Re-planning is unbounded ──────────────────────────────

  def test_replan_can_be_called_multiple_times
    stub_claude_call(REPLANNED_BATCH_PLAN)

    ok1, _err1 = @pipeline.replan_batches(@ctrl_name)
    ok2, _err2 = @pipeline.replan_batches(@ctrl_name)
    ok3, _err3 = @pipeline.replan_batches(@ctrl_name)

    assert ok1, "First replan should succeed"
    assert ok2, "Second replan should succeed"
    assert ok3, "Third replan should succeed"

    wf = workflow_state(@ctrl_name)
    assert_equal "e_awaiting_batch_approval", wf[:status],
                 "Should return to e_awaiting_batch_approval after each replan"
  end

  # ── Guard check ───────────────────────────────────────────

  def test_replan_guard_rejects_wrong_status
    seed_workflow(@ctrl_name,
                  status: "e_planning_batches",
                  e_analysis: ENHANCE_ANALYSIS,
                  e_audit: AUDIT_FIXTURE,
                  e_decisions: DECISIONS_FIXTURE)

    ok, err = @pipeline.replan_batches(@ctrl_name)

    refute ok, "Should fail when status is not e_awaiting_batch_approval"
    assert_includes err, "e_awaiting_batch_approval"
  end

  def test_replan_guard_rejects_missing_workflow
    ok, err = @pipeline.replan_batches("nonexistent_controller")

    refute ok, "Should fail when workflow does not exist"
    assert_includes err, "nonexistent_controller"
  end

  def test_replan_guard_rejects_other_statuses
    other_statuses = %w[e_planning_batches e_analyzing e_awaiting_research
                        e_extracting e_awaiting_decisions e_applying]
    other_statuses.each do |status|
      seed_workflow(@ctrl_name,
                    status: status,
                    e_analysis: ENHANCE_ANALYSIS,
                    e_audit: AUDIT_FIXTURE,
                    e_decisions: DECISIONS_FIXTURE)
      ok, err = @pipeline.replan_batches(@ctrl_name)
      refute ok, "Should reject status #{status}: #{err}"
    end
  end

  # ── Error handling ────────────────────────────────────────

  def test_replan_failure_sets_error_status
    stub_claude_call_failure("Claude unavailable")

    ok, err = @pipeline.replan_batches(@ctrl_name)

    refute ok, "Should return failure on claude error"
    refute_nil err

    wf = workflow_state(@ctrl_name)
    assert_equal "error", wf[:status],
                 "Workflow must be set to error on replan failure"
    refute_nil wf[:error],
               "Workflow error field must be set on replan failure"
  end

  def test_replan_failure_does_not_write_sidecar
    stub_claude_call_failure("Claude exploded")

    @pipeline.replan_batches(@ctrl_name)

    # batches.json should not be written since claude_call raised
    refute enhance_sidecar_exists?("batches.json"),
           "Should not write batches.json when replan claude_call raises"
  end
end
