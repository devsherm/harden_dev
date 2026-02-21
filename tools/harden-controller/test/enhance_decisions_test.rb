# frozen_string_literal: true

require_relative "orchestration_test_helper"

class EnhanceDecisionsTest < OrchestrationTestCase
  def setup
    super
    @ctrl_name = "posts_controller"
    @ctrl_path = create_controller(@ctrl_name)
    seed_controller(@ctrl_name)
    seed_workflow_for_decisions
  end

  # ── Fixtures ───────────────────────────────────────────────

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
      },
      {
        "id" => "item_004",
        "title" => "Inapplicable item",
        "description" => "Not relevant to our stack",
        "impact" => "low",
        "effort" => "high",
        "suggested_default" => "REJECT",
        "prior_decision" => nil,
        "prior_notes" => nil
      }
    ]
  }.freeze

  DECISIONS_TODO_DEFER_REJECT = {
    "item_001" => "TODO",
    "item_002" => "TODO",
    "item_003" => "DEFER",
    "item_004" => "REJECT"
  }.freeze

  def seed_workflow_for_decisions
    seed_workflow(@ctrl_name,
                  status: "e_awaiting_decisions",
                  e_analysis: {},
                  e_audit: AUDIT_FIXTURE)
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

  # ── Decision submission ──────────────────────────────────

  def test_happy_path_returns_success
    ok, err = @pipeline.submit_enhance_decisions(@ctrl_name, DECISIONS_TODO_DEFER_REJECT)

    assert ok, "Expected success, got error: #{err}"
    assert_nil err
  end

  def test_decisions_stored_in_workflow
    @pipeline.submit_enhance_decisions(@ctrl_name, DECISIONS_TODO_DEFER_REJECT)

    wf = workflow_state(@ctrl_name)
    refute_nil wf[:e_decisions], "Expected e_decisions stored in workflow"
    assert_equal "TODO", wf[:e_decisions]["item_001"]
    assert_equal "TODO", wf[:e_decisions]["item_002"]
    assert_equal "DEFER", wf[:e_decisions]["item_003"]
    assert_equal "REJECT", wf[:e_decisions]["item_004"]
  end

  def test_workflow_advances_to_planning_batches
    @pipeline.submit_enhance_decisions(@ctrl_name, DECISIONS_TODO_DEFER_REJECT)

    wf = workflow_state(@ctrl_name)
    assert_equal "e_planning_batches", wf[:status],
                 "Workflow must advance to e_planning_batches after decisions"
  end

  # ── decisions.json sidecar ────────────────────────────────

  def test_decisions_json_written_to_enhance_sidecar
    @pipeline.submit_enhance_decisions(@ctrl_name, DECISIONS_TODO_DEFER_REJECT)

    assert enhance_sidecar_exists?("decisions.json"),
           "Expected decisions.json to be written in enhance sidecar"
  end

  def test_decisions_json_content_matches_input
    @pipeline.submit_enhance_decisions(@ctrl_name, DECISIONS_TODO_DEFER_REJECT)

    content = read_enhance_sidecar("decisions.json")
    assert_equal "TODO", content["item_001"]
    assert_equal "TODO", content["item_002"]
    assert_equal "DEFER", content["item_003"]
    assert_equal "REJECT", content["item_004"]
  end

  # ── deferred.json persistence ─────────────────────────────

  def test_deferred_json_written_for_defer_items
    @pipeline.submit_enhance_decisions(@ctrl_name, DECISIONS_TODO_DEFER_REJECT)

    assert enhance_sidecar_exists?(File.join("decisions", "deferred.json")),
           "Expected deferred.json to be written"
  end

  def test_deferred_json_contains_defer_items_only
    @pipeline.submit_enhance_decisions(@ctrl_name, DECISIONS_TODO_DEFER_REJECT)

    deferred = read_enhance_sidecar(File.join("decisions", "deferred.json"))
    assert_equal 1, deferred.length, "Expected exactly 1 deferred item"
    assert_equal "item_003", deferred[0]["id"]
    assert_equal "DEFER", deferred[0]["decision"]
    assert_equal "Low priority item", deferred[0]["title"]
    assert_equal "A low priority enhancement", deferred[0]["description"]
  end

  def test_deferred_json_not_written_when_no_defer_items
    decisions = { "item_001" => "TODO", "item_002" => "TODO" }
    @pipeline.submit_enhance_decisions(@ctrl_name, decisions)

    refute enhance_sidecar_exists?(File.join("decisions", "deferred.json")),
           "Should not write deferred.json when no items are deferred"
  end

  def test_deferred_json_merges_with_existing_entries
    # Pre-write an existing deferred.json with a different item
    existing_deferred = [
      {
        "id" => "item_old",
        "title" => "Old deferred item",
        "description" => "From a previous cycle",
        "decision" => "DEFER",
        "notes" => nil,
        "timestamp" => "2026-01-01T00:00:00Z"
      }
    ]
    deferred_path = enhance_sidecar_path(File.join("decisions", "deferred.json"))
    FileUtils.mkdir_p(File.dirname(deferred_path))
    File.write(deferred_path, JSON.generate(existing_deferred))

    @pipeline.submit_enhance_decisions(@ctrl_name, DECISIONS_TODO_DEFER_REJECT)

    deferred = read_enhance_sidecar(File.join("decisions", "deferred.json"))
    ids = deferred.map { |e| e["id"] }
    assert_includes ids, "item_old", "Existing deferred item should be preserved"
    assert_includes ids, "item_003", "New deferred item should be added"
    assert_equal 2, deferred.length
  end

  def test_deferred_json_replaces_existing_entry_with_same_id
    # Pre-write a deferred.json with item_003 already present
    existing_deferred = [
      {
        "id" => "item_003",
        "title" => "Low priority item (old)",
        "description" => "Old description",
        "decision" => "DEFER",
        "notes" => "old notes",
        "timestamp" => "2026-01-01T00:00:00Z"
      }
    ]
    deferred_path = enhance_sidecar_path(File.join("decisions", "deferred.json"))
    FileUtils.mkdir_p(File.dirname(deferred_path))
    File.write(deferred_path, JSON.generate(existing_deferred))

    @pipeline.submit_enhance_decisions(@ctrl_name, DECISIONS_TODO_DEFER_REJECT)

    deferred = read_enhance_sidecar(File.join("decisions", "deferred.json"))
    assert_equal 1, deferred.length, "Should not duplicate entries with same id"
    item = deferred.find { |e| e["id"] == "item_003" }
    assert_equal "Low priority item", item["title"],
                 "New entry should replace old entry with same id"
  end

  # ── rejected.json persistence ─────────────────────────────

  def test_rejected_json_written_for_reject_items
    @pipeline.submit_enhance_decisions(@ctrl_name, DECISIONS_TODO_DEFER_REJECT)

    assert enhance_sidecar_exists?(File.join("decisions", "rejected.json")),
           "Expected rejected.json to be written"
  end

  def test_rejected_json_contains_reject_items_only
    @pipeline.submit_enhance_decisions(@ctrl_name, DECISIONS_TODO_DEFER_REJECT)

    rejected = read_enhance_sidecar(File.join("decisions", "rejected.json"))
    assert_equal 1, rejected.length, "Expected exactly 1 rejected item"
    assert_equal "item_004", rejected[0]["id"]
    assert_equal "REJECT", rejected[0]["decision"]
    assert_equal "Inapplicable item", rejected[0]["title"]
    assert_equal "Not relevant to our stack", rejected[0]["description"]
  end

  def test_rejected_json_not_written_when_no_reject_items
    decisions = { "item_001" => "TODO", "item_003" => "DEFER" }
    @pipeline.submit_enhance_decisions(@ctrl_name, decisions)

    refute enhance_sidecar_exists?(File.join("decisions", "rejected.json")),
           "Should not write rejected.json when no items are rejected"
  end

  def test_rejected_json_merges_with_existing_entries
    existing_rejected = [
      {
        "id" => "item_old_reject",
        "title" => "Old rejected item",
        "description" => "From a previous cycle",
        "decision" => "REJECT",
        "notes" => nil,
        "timestamp" => "2026-01-01T00:00:00Z"
      }
    ]
    rejected_path = enhance_sidecar_path(File.join("decisions", "rejected.json"))
    FileUtils.mkdir_p(File.dirname(rejected_path))
    File.write(rejected_path, JSON.generate(existing_rejected))

    @pipeline.submit_enhance_decisions(@ctrl_name, DECISIONS_TODO_DEFER_REJECT)

    rejected = read_enhance_sidecar(File.join("decisions", "rejected.json"))
    ids = rejected.map { |e| e["id"] }
    assert_includes ids, "item_old_reject", "Existing rejected item should be preserved"
    assert_includes ids, "item_004", "New rejected item should be added"
    assert_equal 2, rejected.length
  end

  # ── Guard check ───────────────────────────────────────────

  def test_guard_rejects_wrong_status
    seed_workflow(@ctrl_name, status: "e_analyzing")

    ok, err = @pipeline.submit_enhance_decisions(@ctrl_name, DECISIONS_TODO_DEFER_REJECT)

    refute ok, "Should fail when status is not e_awaiting_decisions"
    assert_includes err, "e_awaiting_decisions"
  end

  def test_guard_rejects_missing_workflow
    ok, err = @pipeline.submit_enhance_decisions("nonexistent_controller", DECISIONS_TODO_DEFER_REJECT)

    refute ok, "Should fail when workflow does not exist"
    assert_includes err, "nonexistent_controller"
  end

  def test_guard_rejects_other_statuses
    other_statuses = %w[h_complete e_analyzing e_awaiting_research e_extracting
                        e_synthesizing e_auditing e_planning_batches e_enhance_complete]
    other_statuses.each do |status|
      seed_workflow(@ctrl_name, status: status)
      ok, err = @pipeline.submit_enhance_decisions(@ctrl_name, {})
      refute ok, "Should reject status #{status}: #{err}"
    end
  end

  # ── All TODO decisions (no DEFER/REJECT) ─────────────────

  def test_all_todo_decisions_no_persist_files
    decisions = {
      "item_001" => "TODO",
      "item_002" => "TODO"
    }
    @pipeline.submit_enhance_decisions(@ctrl_name, decisions)

    refute enhance_sidecar_exists?(File.join("decisions", "deferred.json")),
           "Should not write deferred.json with all-TODO decisions"
    refute enhance_sidecar_exists?(File.join("decisions", "rejected.json")),
           "Should not write rejected.json with all-TODO decisions"
  end

  def test_all_todo_decisions_still_advances_status
    decisions = { "item_001" => "TODO", "item_002" => "TODO" }
    ok, _err = @pipeline.submit_enhance_decisions(@ctrl_name, decisions)

    assert ok
    wf = workflow_state(@ctrl_name)
    assert_equal "e_planning_batches", wf[:status]
  end

  # ── Timestamp written ──────────────────────────────────────

  def test_deferred_entry_has_timestamp
    @pipeline.submit_enhance_decisions(@ctrl_name, DECISIONS_TODO_DEFER_REJECT)

    deferred = read_enhance_sidecar(File.join("decisions", "deferred.json"))
    item = deferred.find { |e| e["id"] == "item_003" }
    refute_nil item["timestamp"], "Deferred entry must have a timestamp"
    # Should be a parseable ISO 8601 timestamp
    assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, item["timestamp"])
  end

  def test_rejected_entry_has_timestamp
    @pipeline.submit_enhance_decisions(@ctrl_name, DECISIONS_TODO_DEFER_REJECT)

    rejected = read_enhance_sidecar(File.join("decisions", "rejected.json"))
    item = rejected.find { |e| e["id"] == "item_004" }
    refute_nil item["timestamp"], "Rejected entry must have a timestamp"
    assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, item["timestamp"])
  end
end
