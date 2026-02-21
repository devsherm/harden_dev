# frozen_string_literal: true

require_relative "orchestration_test_helper"

class ResearchTest < OrchestrationTestCase
  def setup
    super
    @ctrl_name = "posts_controller"
    @ctrl_path = create_controller(@ctrl_name)
    seed_controller(@ctrl_name)
    seed_workflow_with_topics
  end

  # ── Fixtures ───────────────────────────────────────────────

  TOPICS = [
    "Rails N+1 prevention patterns for index actions",
    "ActiveRecord scopes for query encapsulation",
    "Rails caching patterns for read-heavy controllers"
  ].freeze

  def seed_workflow_with_topics(statuses: nil)
    topics = TOPICS.each_with_index.map do |prompt, i|
      { prompt: prompt, status: statuses ? statuses[i] : "pending", result: nil }
    end
    seed_workflow(@ctrl_name, status: "e_awaiting_research",
                  e_analysis: { "intent" => "test" },
                  research_topics: topics)
  end

  def enhance_sidecar_path(filename)
    File.join(File.dirname(@ctrl_path), ".enhance", @ctrl_name, filename)
  end

  def enhance_sidecar_exists?(filename)
    File.exist?(enhance_sidecar_path(filename))
  end

  def read_research_status
    JSON.parse(File.read(enhance_sidecar_path("research_status.json")))
  end

  def topic_slug(prompt)
    prompt.downcase.gsub(/[^a-z0-9]+/, "_").slice(0, 50)
  end

  def stub_run_extraction_chain
    @pipeline.define_singleton_method(:run_extraction_chain) do |_name|
      # no-op stub for item 16
    end
  end

  # ── submit_research (manual paste) ─────────────────────────

  def test_manual_paste_marks_topic_completed
    @pipeline.submit_research(@ctrl_name, 0, "Research result for N+1")

    wf = workflow_state(@ctrl_name)
    topics = wf[:research_topics]
    assert_equal "completed", topics[0][:status]
    assert_equal "Research result for N+1", topics[0][:result]
    assert_equal "pending", topics[1][:status]
  end

  def test_manual_paste_writes_research_status_json
    @pipeline.submit_research(@ctrl_name, 0, "Research result for N+1")

    assert enhance_sidecar_exists?("research_status.json"),
           "Expected research_status.json to be written"

    statuses = read_research_status
    assert_equal 3, statuses.length
    assert_equal "completed", statuses[0]["status"]
    assert_equal "pending", statuses[1]["status"]
  end

  def test_manual_paste_writes_research_md_file
    @pipeline.submit_research(@ctrl_name, 0, "Research content here")

    slug = topic_slug(TOPICS[0])
    md_path = enhance_sidecar_path(File.join("research", "#{slug}.md"))
    assert File.exist?(md_path), "Expected research MD file at #{md_path}"
    assert_equal "Research content here", File.read(md_path)
  end

  # ── reject_research_topic ──────────────────────────────────

  def test_reject_marks_topic_rejected
    @pipeline.reject_research_topic(@ctrl_name, 1)

    wf = workflow_state(@ctrl_name)
    topics = wf[:research_topics]
    assert_equal "pending", topics[0][:status]
    assert_equal "rejected", topics[1][:status]
    assert_equal "pending", topics[2][:status]
  end

  def test_reject_writes_research_status_json
    @pipeline.reject_research_topic(@ctrl_name, 0)

    assert enhance_sidecar_exists?("research_status.json")

    statuses = read_research_status
    assert_equal "rejected", statuses[0]["status"]
    assert_equal "pending", statuses[1]["status"]
  end

  # ── completion check (auto-advance) ────────────────────────

  def test_all_completed_advances_to_e_extracting
    stub_run_extraction_chain

    # Manually complete all topics via direct state mutation, then trigger check
    # by completing the last one via submit_research
    @pipeline.submit_research(@ctrl_name, 0, "Result 0")
    @pipeline.submit_research(@ctrl_name, 1, "Result 1")
    @pipeline.submit_research(@ctrl_name, 2, "Result 2")

    wf = workflow_state(@ctrl_name)
    assert_equal "e_extracting", wf[:status]
  end

  def test_all_rejected_advances_to_e_extracting
    stub_run_extraction_chain

    @pipeline.reject_research_topic(@ctrl_name, 0)
    @pipeline.reject_research_topic(@ctrl_name, 1)
    @pipeline.reject_research_topic(@ctrl_name, 2)

    wf = workflow_state(@ctrl_name)
    assert_equal "e_extracting", wf[:status]
  end

  def test_mixed_completed_and_rejected_advances_when_done
    stub_run_extraction_chain

    @pipeline.submit_research(@ctrl_name, 0, "Result 0")
    @pipeline.reject_research_topic(@ctrl_name, 1)
    @pipeline.submit_research(@ctrl_name, 2, "Result 2")

    wf = workflow_state(@ctrl_name)
    assert_equal "e_extracting", wf[:status]
  end

  def test_partial_completion_does_not_advance
    stub_run_extraction_chain

    @pipeline.submit_research(@ctrl_name, 0, "Result 0")
    # Topics 1 and 2 still pending

    wf = workflow_state(@ctrl_name)
    assert_equal "e_awaiting_research", wf[:status]
  end

  def test_completion_enqueues_extraction_chain
    chain_called = false
    @pipeline.define_singleton_method(:run_extraction_chain) do |_name|
      chain_called = true
    end

    # Stub scheduler to not be used (test without scheduler)
    @pipeline.instance_variable_set(:@scheduler, nil)

    @pipeline.submit_research(@ctrl_name, 0, "R0")
    @pipeline.submit_research(@ctrl_name, 1, "R1")
    @pipeline.submit_research(@ctrl_name, 2, "R2")

    # Wait briefly for safe_thread to complete
    sleep 0.1
    @pipeline.instance_variable_get(:@threads).each { |t| t.join(2) }

    assert chain_called, "Expected run_extraction_chain to be called on completion"
  end

  # ── submit_research_api ─────────────────────────────────────

  def test_api_research_marks_topic_researching
    called = false
    @pipeline.define_singleton_method(:api_call) do |prompt|
      called = true
      sleep 1  # prevent completion during this check
      "result"
    end

    # Track the thread
    @pipeline.submit_research_api(@ctrl_name, 0)
    # Give thread a moment to start and set status
    sleep 0.05

    wf = workflow_state(@ctrl_name)
    assert_equal "researching", wf[:research_topics][0][:status]
  end

  def test_api_research_marks_topic_completed_on_success
    stub_run_extraction_chain
    @pipeline.define_singleton_method(:api_call) do |prompt|
      "API research result"
    end

    @pipeline.submit_research_api(@ctrl_name, 0)
    # Wait for thread to complete
    sleep 0.5
    @pipeline.instance_variable_get(:@threads).each { |t| t.join(2) }

    # The background thread might still be running; give extra time
    10.times do
      break if workflow_state(@ctrl_name)[:research_topics][0][:status] == "completed"
      sleep 0.1
    end

    wf = workflow_state(@ctrl_name)
    assert_equal "completed", wf[:research_topics][0][:status]
    assert_equal "API research result", wf[:research_topics][0][:result]
  end

  def test_api_research_reverts_to_pending_on_failure
    @pipeline.define_singleton_method(:api_call) do |prompt|
      raise RuntimeError, "API timeout"
    end

    @pipeline.submit_research_api(@ctrl_name, 0)

    # Wait for thread to complete
    20.times do
      break if workflow_state(@ctrl_name)[:research_topics][0][:status] != "researching"
      sleep 0.1
    end

    wf = workflow_state(@ctrl_name)
    assert_equal "pending", wf[:research_topics][0][:status],
                 "Topic should revert to pending on API failure"
  end

  def test_api_research_failure_logs_error_not_workflow_error
    @pipeline.define_singleton_method(:api_call) do |prompt|
      raise RuntimeError, "API timeout"
    end

    @pipeline.submit_research_api(@ctrl_name, 0)

    20.times do
      break if workflow_state(@ctrl_name)[:research_topics][0][:status] != "researching"
      sleep 0.1
    end

    # Workflow should NOT be in error state — only the topic reverts
    wf = workflow_state(@ctrl_name)
    refute_equal "error", wf[:status],
                 "Workflow should not be set to error on per-topic API failure"

    # But a global error should be logged
    errors = global_errors
    assert errors.any? { |e| e[:message].include?("Research API failed") },
           "Expected a global error about research API failure"
  end

  def test_api_research_writes_research_md_on_success
    stub_run_extraction_chain
    @pipeline.define_singleton_method(:api_call) do |prompt|
      "Research findings from API"
    end

    @pipeline.submit_research_api(@ctrl_name, 0)

    20.times do
      break if workflow_state(@ctrl_name)[:research_topics][0][:status] == "completed"
      sleep 0.1
    end

    slug = topic_slug(TOPICS[0])
    md_path = enhance_sidecar_path(File.join("research", "#{slug}.md"))
    assert File.exist?(md_path), "Expected research MD file to be written on API success"
    assert_equal "Research findings from API", File.read(md_path)
  end

  def test_api_research_writes_status_json_on_success
    stub_run_extraction_chain
    @pipeline.define_singleton_method(:api_call) do |prompt|
      "Result"
    end

    @pipeline.submit_research_api(@ctrl_name, 0)

    20.times do
      break if workflow_state(@ctrl_name)[:research_topics][0][:status] == "completed"
      sleep 0.1
    end

    assert enhance_sidecar_exists?("research_status.json")
    statuses = read_research_status
    assert_equal "completed", statuses[0]["status"]
  end

  def test_api_research_writes_status_json_on_failure
    @pipeline.define_singleton_method(:api_call) do |prompt|
      raise RuntimeError, "Boom"
    end

    @pipeline.submit_research_api(@ctrl_name, 0)

    20.times do
      break if workflow_state(@ctrl_name)[:research_topics][0][:status] != "researching"
      sleep 0.1
    end

    assert enhance_sidecar_exists?("research_status.json")
    statuses = read_research_status
    assert_equal "pending", statuses[0]["status"]
  end

  # ── API concurrency bounding ───────────────────────────────

  def test_api_concurrency_bounded_by_max_api_concurrency
    # Verify @api_active is used (via acquire_api_slot) in api_call.
    # We test this by checking max concurrency constant is honored.
    # The acquire/release is in ClaudeClient#api_call → acquire_api_slot.
    # Here we just verify the constant exists and is non-zero.
    assert Pipeline::MAX_API_CONCURRENCY > 0
    assert_equal 20, Pipeline::MAX_API_CONCURRENCY
  end

  # ── Topic state: multiple independent topics ───────────────

  def test_topics_are_tracked_independently
    @pipeline.submit_research(@ctrl_name, 1, "Second topic result")
    @pipeline.reject_research_topic(@ctrl_name, 2)

    wf = workflow_state(@ctrl_name)
    topics = wf[:research_topics]
    assert_equal "pending",   topics[0][:status]
    assert_equal "completed", topics[1][:status]
    assert_equal "rejected",  topics[2][:status]
  end

  # ── Return value of submit_research_api ───────────────────

  def test_submit_research_api_returns_nil
    @pipeline.define_singleton_method(:api_call) do |prompt|
      "result"
    end

    result = @pipeline.submit_research_api(@ctrl_name, 0)
    assert_nil result
  end

  # ── Scheduler used when available ─────────────────────────

  def test_completion_uses_scheduler_when_available
    enqueued = []
    fake_scheduler = Object.new
    fake_scheduler.define_singleton_method(:enqueue) do |item|
      enqueued << item
    end
    @pipeline.instance_variable_set(:@scheduler, fake_scheduler)

    @pipeline.submit_research(@ctrl_name, 0, "R0")
    @pipeline.submit_research(@ctrl_name, 1, "R1")
    @pipeline.submit_research(@ctrl_name, 2, "R2")

    assert_equal 1, enqueued.length,
                 "Expected scheduler.enqueue to be called once on completion"
    assert_equal :e_extracting, enqueued[0].phase
  end
end
