# frozen_string_literal: true

require "minitest/autorun"
require "rack/test"
require "tmpdir"
require "fileutils"
require "json"

# Prevent auto-discovery at startup
ENV["RACK_ENV"] = "test"
ENV["RAILS_ROOT"] ||= Dir.mktmpdir("harden-enhance-routes-test-")

require_relative "../server"

class EnhanceRoutesTest < Minitest::Test
  include Rack::Test::Methods

  CONTROLLER_SOURCE = <<~RUBY
    class Blog::PostsController < ApplicationController
      def index
        @posts = Blog::Post.all
      end
    end
  RUBY

  def app
    Sinatra::Application
  end

  def setup
    clear_cookies
    @original_passcode = HardenAuth.passcode
    HardenAuth.passcode = nil  # disable auth for route testing

    # Create a fresh tmpdir and point $pipeline at it
    @tmpdir = Dir.mktmpdir("harden-enhance-routes-")
    @original_pipeline = $pipeline
    $pipeline = Pipeline.new(rails_root: @tmpdir)

    @ctrl_name = "posts_controller"
    @ctrl_path = setup_controller(@ctrl_name)
    seed_controller(@ctrl_name)

    Thread.report_on_exception = false
  end

  def teardown
    HardenAuth.passcode = @original_passcode
    $pipeline.shutdown(timeout: 2) rescue nil
    $pipeline = @original_pipeline
    FileUtils.rm_rf(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
    Thread.report_on_exception = true
  end

  private

  def setup_controller(name)
    path = File.join(@tmpdir, "app", "controllers", "blog", "#{name}.rb")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, CONTROLLER_SOURCE)
    harden_dir = File.join(File.dirname(path), ".harden", name)
    FileUtils.mkdir_p(harden_dir)
    path
  end

  def seed_controller(name)
    full_path = File.join(@tmpdir, "app", "controllers", "blog", "#{name}.rb")
    relative  = "app/controllers/blog/#{name}.rb"
    entry = {
      name: name,
      path: relative,
      full_path: full_path,
      phases: { analyzed: false, hardened: false, tested: false,
                ci_checked: false, verified: false },
      existing_analysis_at: nil, existing_hardened_at: nil,
      existing_tested_at: nil, existing_ci_at: nil, existing_verified_at: nil,
      stale: nil, overall_risk: nil, finding_counts: nil
    }
    $pipeline.instance_variable_get(:@mutex).synchronize do
      $pipeline.instance_variable_get(:@state)[:controllers] << entry
    end
  end

  def seed_workflow(name, overrides = {})
    mutex = $pipeline.instance_variable_get(:@mutex)
    state = $pipeline.instance_variable_get(:@state)
    entry = mutex.synchronize { state[:controllers].find { |c| c[:name] == name } }
    raise "Controller not seeded: #{name}" unless entry

    workflow = {
      name: entry[:name], path: entry[:path], full_path: entry[:full_path],
      status: "pending", mode: "hardening",
      analysis: nil, decision: nil, hardened: nil,
      test_results: nil, ci_results: nil, verification: nil,
      error: nil, started_at: nil, completed_at: nil, original_source: nil
    }.merge(overrides)

    mutex.synchronize { state[:workflows][name] = workflow }
  end

  def workflow_status(name)
    $pipeline.instance_variable_get(:@mutex).synchronize do
      $pipeline.instance_variable_get(:@state)[:workflows][name]&.[](:status)
    end
  end

  def xhr_post(path, params = {})
    post path, params, { "HTTP_X_REQUESTED_WITH" => "XMLHttpRequest",
                         "CONTENT_TYPE" => "application/json" }
  end

  def xhr_post_json(path, body)
    post path, body.to_json,
         { "HTTP_X_REQUESTED_WITH" => "XMLHttpRequest",
           "CONTENT_TYPE" => "application/json" }
  end

  def stub_enhance_analysis_noreturn
    $pipeline.define_singleton_method(:run_enhance_analysis) { |name| nil }
  end

  def stub_run_batch_execution_noreturn
    $pipeline.define_singleton_method(:run_batch_execution) { |name| nil }
  end

  def stub_run_batch_planning_noreturn
    $pipeline.define_singleton_method(:run_batch_planning) { |name, **kwargs| nil }
  end

  public

  # ── POST /enhance/analyze ────────────────────────────────────

  def test_analyze_returns_400_when_no_controller
    xhr_post_json "/enhance/analyze", {}
    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_includes body["error"], "No controller specified"
  end

  def test_analyze_returns_400_when_controller_empty
    xhr_post_json "/enhance/analyze", { "controller" => "" }
    assert_equal 400, last_response.status
  end

  def test_analyze_returns_409_when_wrong_status
    seed_workflow(@ctrl_name, status: "h_analyzing")
    xhr_post_json "/enhance/analyze", { "controller" => @ctrl_name }
    assert_equal 409, last_response.status
    body = JSON.parse(last_response.body)
    refute_nil body["error"]
  end

  def test_analyze_returns_409_when_pending_status
    seed_workflow(@ctrl_name, status: "pending")
    xhr_post_json "/enhance/analyze", { "controller" => @ctrl_name }
    assert_equal 409, last_response.status
  end

  def test_analyze_accepts_h_complete_status
    seed_workflow(@ctrl_name, status: "h_complete")
    stub_enhance_analysis_noreturn
    xhr_post_json "/enhance/analyze", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "enhancing", body["status"]
    assert_equal @ctrl_name, body["controller"]
  end

  def test_analyze_accepts_e_enhance_complete_status
    seed_workflow(@ctrl_name, status: "e_enhance_complete",
                  e_analysis: {}, research_topics: [], e_decisions: {})
    stub_enhance_analysis_noreturn
    xhr_post_json "/enhance/analyze", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "enhancing", body["status"]
  end

  def test_analyze_transitions_status_to_e_analyzing
    seed_workflow(@ctrl_name, status: "h_complete")
    stub_enhance_analysis_noreturn
    xhr_post_json "/enhance/analyze", { "controller" => @ctrl_name }
    # try_transition sets to e_analyzing before safe_thread
    status = workflow_status(@ctrl_name)
    assert_equal "e_analyzing", status
  end

  def test_analyze_requires_xhr_header_when_auth_enabled
    # CSRF check only runs when authentication is active
    @original_passcode_for_csrf = HardenAuth.passcode
    HardenAuth.passcode = "test-passcode"
    post "/auth", passcode: "test-passcode"
    follow_redirect!

    seed_workflow(@ctrl_name, status: "h_complete")
    post "/enhance/analyze", { "controller" => @ctrl_name }.to_json,
         { "CONTENT_TYPE" => "application/json" }
    assert_equal 403, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "Missing X-Requested-With header", body["error"]
  ensure
    HardenAuth.passcode = @original_passcode_for_csrf
  end

  def test_analyze_dispatches_via_safe_thread_when_no_scheduler
    seed_workflow(@ctrl_name, status: "h_complete")
    dispatched = false
    $pipeline.define_singleton_method(:run_enhance_analysis) { |name| dispatched = true }
    # Disable scheduler
    $pipeline.instance_variable_set(:@scheduler, nil)

    xhr_post_json "/enhance/analyze", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    # Give the thread time to run
    sleep 0.1
    assert dispatched, "run_enhance_analysis should have been called via safe_thread"
  end

  def test_analyze_dispatches_via_scheduler_when_available
    seed_workflow(@ctrl_name, status: "h_complete")
    enqueued_items = []
    fake_scheduler = Object.new
    fake_scheduler.define_singleton_method(:enqueue) { |item| enqueued_items << item; item }
    $pipeline.instance_variable_set(:@scheduler, fake_scheduler)

    xhr_post_json "/enhance/analyze", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    assert_equal 1, enqueued_items.length, "Should enqueue one WorkItem via Scheduler"
    assert_equal :e_analyze, enqueued_items[0].phase
    assert_equal @ctrl_name, enqueued_items[0].workflow
  end

  # ── POST /enhance/research ───────────────────────────────────

  def test_research_returns_400_when_no_controller
    xhr_post_json "/enhance/research", { "topic_index" => 0, "action" => "paste", "result" => "text" }
    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_includes body["error"], "No controller specified"
  end

  def test_research_returns_400_when_no_topic_index
    xhr_post_json "/enhance/research", { "controller" => @ctrl_name, "action" => "paste", "result" => "text" }
    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_includes body["error"], "topic_index"
  end

  def test_research_returns_400_when_invalid_action
    xhr_post_json "/enhance/research", { "controller" => @ctrl_name, "topic_index" => 0, "action" => "invalid" }
    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_includes body["error"], "action"
  end

  def test_research_paste_returns_400_when_no_result
    xhr_post_json "/enhance/research", { "controller" => @ctrl_name, "topic_index" => 0, "action" => "paste" }
    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_includes body["error"], "result required"
  end

  def test_research_paste_calls_submit_research
    seed_workflow(@ctrl_name,
      status: "e_awaiting_research",
      research_topics: [{ prompt: "topic 1", status: "pending", result: nil }])
    called_with = nil
    $pipeline.define_singleton_method(:submit_research) do |name, idx, result|
      called_with = { name: name, idx: idx, result: result }
    end

    xhr_post_json "/enhance/research", {
      "controller" => @ctrl_name, "topic_index" => 0,
      "action" => "paste", "result" => "research findings here"
    }

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "research_submitted", body["status"]
    refute_nil called_with
    assert_equal @ctrl_name, called_with[:name]
    assert_equal 0, called_with[:idx]
    assert_equal "research findings here", called_with[:result]
  end

  def test_research_reject_calls_reject_research_topic
    seed_workflow(@ctrl_name,
      status: "e_awaiting_research",
      research_topics: [{ prompt: "topic 1", status: "pending", result: nil }])
    called_with = nil
    $pipeline.define_singleton_method(:reject_research_topic) do |name, idx|
      called_with = { name: name, idx: idx }
    end

    xhr_post_json "/enhance/research", {
      "controller" => @ctrl_name, "topic_index" => 1,
      "action" => "reject"
    }

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "topic_rejected", body["status"]
    refute_nil called_with
    assert_equal @ctrl_name, called_with[:name]
    assert_equal 1, called_with[:idx]
  end

  # ── POST /enhance/research/api ───────────────────────────────

  def test_research_api_returns_400_when_no_controller
    xhr_post_json "/enhance/research/api", { "topic_index" => 0 }
    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_includes body["error"], "No controller specified"
  end

  def test_research_api_returns_400_when_no_topic_index
    xhr_post_json "/enhance/research/api", { "controller" => @ctrl_name }
    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_includes body["error"], "topic_index"
  end

  def test_research_api_calls_submit_research_api
    called_with = nil
    $pipeline.define_singleton_method(:submit_research_api) do |name, idx|
      called_with = { name: name, idx: idx }
    end

    xhr_post_json "/enhance/research/api", { "controller" => @ctrl_name, "topic_index" => 2 }

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "research_started", body["status"]
    assert_equal @ctrl_name, body["controller"]
    assert_equal 2, body["topic_index"]
    refute_nil called_with
    assert_equal @ctrl_name, called_with[:name]
    assert_equal 2, called_with[:idx]
  end

  # ── POST /enhance/decisions ──────────────────────────────────

  def test_decisions_returns_400_when_no_controller
    xhr_post_json "/enhance/decisions", { "decisions" => {} }
    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_includes body["error"], "No controller specified"
  end

  def test_decisions_returns_400_when_no_decisions
    xhr_post_json "/enhance/decisions", { "controller" => @ctrl_name }
    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_includes body["error"], "decisions required"
  end

  def test_decisions_returns_409_when_wrong_status
    seed_workflow(@ctrl_name, status: "e_extracting", e_audit: { "annotated_items" => [] })
    xhr_post_json "/enhance/decisions", {
      "controller" => @ctrl_name,
      "decisions" => { "item_001" => "TODO" }
    }
    assert_equal 409, last_response.status
  end

  def test_decisions_submits_and_starts_batch_planning
    seed_workflow(@ctrl_name,
      status: "e_awaiting_decisions",
      e_audit: { "annotated_items" => [{ "id" => "item_001", "title" => "Test item" }] })
    batch_planning_called = false
    $pipeline.define_singleton_method(:run_batch_planning) { |name, **kwargs| batch_planning_called = true }

    xhr_post_json "/enhance/decisions", {
      "controller" => @ctrl_name,
      "decisions" => { "item_001" => "TODO" }
    }

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "decisions_received", body["status"]
    assert_equal @ctrl_name, body["controller"]
    # Give the thread time to run
    sleep 0.1
    assert batch_planning_called, "run_batch_planning should be called after decisions"
  end

  def test_decisions_guard_enforced
    # Not in e_awaiting_decisions — submit_enhance_decisions returns [false, err]
    seed_workflow(@ctrl_name, status: "e_auditing", e_audit: { "annotated_items" => [] })
    xhr_post_json "/enhance/decisions", {
      "controller" => @ctrl_name,
      "decisions" => { "item_001" => "TODO" }
    }
    assert_equal 409, last_response.status
  end

  # ── POST /enhance/batches/approve ───────────────────────────

  def test_batches_approve_returns_400_when_no_controller
    xhr_post_json "/enhance/batches/approve", {}
    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_includes body["error"], "No controller specified"
  end

  def test_batches_approve_returns_409_when_wrong_status
    seed_workflow(@ctrl_name, status: "e_awaiting_decisions")
    xhr_post_json "/enhance/batches/approve", { "controller" => @ctrl_name }
    assert_equal 409, last_response.status
  end

  def test_batches_approve_starts_batch_execution
    seed_workflow(@ctrl_name,
      status: "e_awaiting_batch_approval",
      e_analysis: {}, e_batches: { "batches" => [] })
    stub_run_batch_execution_noreturn

    xhr_post_json "/enhance/batches/approve", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "batch_execution_started", body["status"]
    assert_equal @ctrl_name, body["controller"]
  end

  def test_batches_approve_transitions_status_to_e_applying
    seed_workflow(@ctrl_name,
      status: "e_awaiting_batch_approval",
      e_analysis: {}, e_batches: { "batches" => [] })
    stub_run_batch_execution_noreturn

    xhr_post_json "/enhance/batches/approve", { "controller" => @ctrl_name }
    status = workflow_status(@ctrl_name)
    assert_equal "e_applying", status
  end

  def test_batches_approve_uses_scheduler_when_available
    seed_workflow(@ctrl_name,
      status: "e_awaiting_batch_approval",
      e_analysis: {}, e_batches: { "batches" => [] })
    enqueued_items = []
    fake_scheduler = Object.new
    fake_scheduler.define_singleton_method(:enqueue) { |item| enqueued_items << item; item }
    $pipeline.instance_variable_set(:@scheduler, fake_scheduler)

    xhr_post_json "/enhance/batches/approve", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    assert_equal 1, enqueued_items.length
    assert_equal :e_applying, enqueued_items[0].phase
  end

  # ── POST /enhance/batches/replan ─────────────────────────────

  def test_batches_replan_returns_400_when_no_controller
    xhr_post_json "/enhance/batches/replan", { "notes" => "too complex" }
    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_includes body["error"], "No controller specified"
  end

  def test_batches_replan_returns_409_when_wrong_status
    seed_workflow(@ctrl_name, status: "e_awaiting_decisions")
    xhr_post_json "/enhance/batches/replan", { "controller" => @ctrl_name, "notes" => "notes" }
    assert_equal 409, last_response.status
  end

  def test_batches_replan_calls_replan_batches_with_notes
    seed_workflow(@ctrl_name,
      status: "e_awaiting_batch_approval",
      e_analysis: {}, e_decisions: {}, e_audit: { "annotated_items" => [] },
      e_batches: { "batches" => [] })

    called_with = nil
    $pipeline.define_singleton_method(:run_batch_planning) do |name, operator_notes: nil|
      called_with = { name: name, notes: operator_notes }
    end

    xhr_post_json "/enhance/batches/replan", {
      "controller" => @ctrl_name,
      "notes" => "please group differently"
    }

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "replanning", body["status"]
    assert_equal @ctrl_name, body["controller"]
    # Give the thread (if any) time to run
    sleep 0.05
    refute_nil called_with
    assert_equal "please group differently", called_with[:notes]
  end

  def test_batches_replan_without_notes
    seed_workflow(@ctrl_name,
      status: "e_awaiting_batch_approval",
      e_analysis: {}, e_decisions: {}, e_audit: { "annotated_items" => [] },
      e_batches: { "batches" => [] })

    called_with = nil
    $pipeline.define_singleton_method(:run_batch_planning) do |name, operator_notes: nil|
      called_with = { name: name, notes: operator_notes }
    end

    xhr_post_json "/enhance/batches/replan", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    sleep 0.05
    refute_nil called_with
    assert_nil called_with[:notes]
  end

  # ── POST /enhance/retry ──────────────────────────────────────

  def test_retry_returns_400_when_no_controller
    xhr_post_json "/enhance/retry", {}
    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_includes body["error"], "No controller specified"
  end

  def test_retry_returns_409_when_not_in_error
    seed_workflow(@ctrl_name, status: "e_analyzing")
    xhr_post_json "/enhance/retry", { "controller" => @ctrl_name }
    assert_equal 409, last_response.status
  end

  def test_retry_defaults_to_analysis_when_no_last_active_status
    seed_workflow(@ctrl_name, status: "error", error: "Something failed")
    dispatched = false
    $pipeline.define_singleton_method(:run_enhance_analysis) { |name| dispatched = true }

    xhr_post_json "/enhance/retry", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "retrying_enhance", body["status"]
    assert_equal @ctrl_name, body["controller"]
    sleep 0.1
    assert dispatched, "run_enhance_analysis should be dispatched when no last_active_status"
  end

  def test_retry_defaults_to_e_analyzing_status_when_no_last_active_status
    seed_workflow(@ctrl_name, status: "error", error: "Something failed")
    $pipeline.define_singleton_method(:run_enhance_analysis) { |name| nil }

    xhr_post_json "/enhance/retry", { "controller" => @ctrl_name }
    assert_equal "e_analyzing", workflow_status(@ctrl_name)
  end

  def test_retry_dispatches_extraction_chain_when_last_status_was_e_extracting
    seed_workflow(@ctrl_name, status: "error", error: "Extract failed",
                  last_active_status: "e_extracting")
    dispatched = false
    $pipeline.define_singleton_method(:retry_extraction_chain) { |name| dispatched = true }

    xhr_post_json "/enhance/retry", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    assert_equal "e_extracting", workflow_status(@ctrl_name)
    sleep 0.1
    assert dispatched, "retry_extraction_chain should be dispatched"
  end

  def test_retry_dispatches_extraction_chain_when_last_status_was_e_synthesizing
    seed_workflow(@ctrl_name, status: "error", error: "Synthesis failed",
                  last_active_status: "e_synthesizing")
    dispatched = false
    $pipeline.define_singleton_method(:retry_extraction_chain) { |name| dispatched = true }

    xhr_post_json "/enhance/retry", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    assert_equal "e_extracting", workflow_status(@ctrl_name)
    sleep 0.1
    assert dispatched, "retry_extraction_chain should be dispatched for e_synthesizing error"
  end

  def test_retry_dispatches_extraction_chain_when_last_status_was_e_auditing
    seed_workflow(@ctrl_name, status: "error", error: "Audit failed",
                  last_active_status: "e_auditing")
    dispatched = false
    $pipeline.define_singleton_method(:retry_extraction_chain) { |name| dispatched = true }

    xhr_post_json "/enhance/retry", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    assert_equal "e_extracting", workflow_status(@ctrl_name)
    sleep 0.1
    assert dispatched, "retry_extraction_chain should be dispatched for e_auditing error"
  end

  def test_retry_dispatches_batch_planning_when_last_status_was_e_planning_batches
    seed_workflow(@ctrl_name, status: "error", error: "Planning failed",
                  last_active_status: "e_planning_batches",
                  e_analysis: {}, e_decisions: {}, e_audit: { "annotated_items" => [] })
    dispatched = false
    $pipeline.define_singleton_method(:run_batch_planning) { |name, **kwargs| dispatched = true }

    xhr_post_json "/enhance/retry", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    assert_equal "e_planning_batches", workflow_status(@ctrl_name)
    sleep 0.1
    assert dispatched, "run_batch_planning should be dispatched for e_planning_batches error"
  end

  def test_retry_dispatches_batch_execution_when_last_status_was_e_applying
    seed_workflow(@ctrl_name, status: "error", error: "Apply failed",
                  last_active_status: "e_applying",
                  e_batches: { "batches" => [] }, e_analysis: {})
    dispatched = false
    $pipeline.define_singleton_method(:run_batch_execution) { |name| dispatched = true }

    xhr_post_json "/enhance/retry", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    assert_equal "e_applying", workflow_status(@ctrl_name)
    sleep 0.1
    assert dispatched, "run_batch_execution should be dispatched for e_applying error"
  end

  def test_retry_dispatches_batch_execution_when_last_status_was_e_testing
    seed_workflow(@ctrl_name, status: "error", error: "Testing crashed",
                  last_active_status: "e_testing",
                  e_batches: { "batches" => [] }, e_analysis: {})
    dispatched = false
    $pipeline.define_singleton_method(:run_batch_execution) { |name| dispatched = true }

    xhr_post_json "/enhance/retry", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    assert_equal "e_applying", workflow_status(@ctrl_name)
    sleep 0.1
    assert dispatched, "run_batch_execution should be dispatched for e_testing error"
  end

  def test_retry_dispatches_batch_execution_when_last_status_was_e_verifying
    seed_workflow(@ctrl_name, status: "error", error: "Verify crashed",
                  last_active_status: "e_verifying",
                  e_batches: { "batches" => [] }, e_analysis: {})
    dispatched = false
    $pipeline.define_singleton_method(:run_batch_execution) { |name| dispatched = true }

    xhr_post_json "/enhance/retry", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    assert_equal "e_applying", workflow_status(@ctrl_name)
    sleep 0.1
    assert dispatched, "run_batch_execution should be dispatched for e_verifying error"
  end

  def test_retry_dispatches_analysis_when_last_status_was_e_analyzing
    seed_workflow(@ctrl_name, status: "error", error: "Analysis failed",
                  last_active_status: "e_analyzing")
    dispatched = false
    $pipeline.define_singleton_method(:run_enhance_analysis) { |name| dispatched = true }

    xhr_post_json "/enhance/retry", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    assert_equal "e_analyzing", workflow_status(@ctrl_name)
    sleep 0.1
    assert dispatched, "run_enhance_analysis should be dispatched for e_analyzing error"
  end

  # ── POST /enhance/retry-tests ────────────────────────────────

  def test_retry_tests_returns_400_when_no_controller
    xhr_post_json "/enhance/retry-tests", {}
    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_includes body["error"], "No controller specified"
  end

  def test_retry_tests_returns_409_when_not_e_tests_failed
    seed_workflow(@ctrl_name, status: "e_ci_failed")
    xhr_post_json "/enhance/retry-tests", { "controller" => @ctrl_name }
    assert_equal 409, last_response.status
  end

  def test_retry_tests_transitions_from_e_tests_failed_and_starts_execution
    seed_workflow(@ctrl_name,
      status: "e_tests_failed",
      e_batches: { "batches" => [] },
      e_analysis: {})
    stub_run_batch_execution_noreturn

    xhr_post_json "/enhance/retry-tests", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "retrying_tests", body["status"]
    assert_equal @ctrl_name, body["controller"]
  end

  def test_retry_tests_transitions_status_to_e_awaiting_batch_approval
    seed_workflow(@ctrl_name,
      status: "e_tests_failed",
      e_batches: { "batches" => [] },
      e_analysis: {})
    stub_run_batch_execution_noreturn

    xhr_post_json "/enhance/retry-tests", { "controller" => @ctrl_name }
    assert_equal "e_awaiting_batch_approval", workflow_status(@ctrl_name)
  end

  def test_retry_tests_uses_scheduler_when_available
    seed_workflow(@ctrl_name,
      status: "e_tests_failed",
      e_batches: { "batches" => [] },
      e_analysis: {})

    enqueued_items = []
    fake_scheduler = Object.new
    fake_scheduler.define_singleton_method(:enqueue) { |item| enqueued_items << item; item }
    $pipeline.instance_variable_set(:@scheduler, fake_scheduler)

    xhr_post_json "/enhance/retry-tests", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    assert_equal 1, enqueued_items.length
    assert_equal :e_applying, enqueued_items[0].phase
  end

  # ── POST /enhance/retry-ci ───────────────────────────────────

  def test_retry_ci_returns_400_when_no_controller
    xhr_post_json "/enhance/retry-ci", {}
    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_includes body["error"], "No controller specified"
  end

  def test_retry_ci_returns_409_when_not_e_ci_failed
    seed_workflow(@ctrl_name, status: "e_tests_failed")
    xhr_post_json "/enhance/retry-ci", { "controller" => @ctrl_name }
    assert_equal 409, last_response.status
  end

  def test_retry_ci_transitions_from_e_ci_failed_and_starts_execution
    seed_workflow(@ctrl_name,
      status: "e_ci_failed",
      e_batches: { "batches" => [] },
      e_analysis: {})
    stub_run_batch_execution_noreturn

    xhr_post_json "/enhance/retry-ci", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "retrying_ci", body["status"]
    assert_equal @ctrl_name, body["controller"]
  end

  def test_retry_ci_transitions_status_to_e_awaiting_batch_approval
    seed_workflow(@ctrl_name,
      status: "e_ci_failed",
      e_batches: { "batches" => [] },
      e_analysis: {})
    stub_run_batch_execution_noreturn

    xhr_post_json "/enhance/retry-ci", { "controller" => @ctrl_name }
    assert_equal "e_awaiting_batch_approval", workflow_status(@ctrl_name)
  end

  def test_retry_ci_uses_scheduler_when_available
    seed_workflow(@ctrl_name,
      status: "e_ci_failed",
      e_batches: { "batches" => [] },
      e_analysis: {})

    enqueued_items = []
    fake_scheduler = Object.new
    fake_scheduler.define_singleton_method(:enqueue) { |item| enqueued_items << item; item }
    $pipeline.instance_variable_set(:@scheduler, fake_scheduler)

    xhr_post_json "/enhance/retry-ci", { "controller" => @ctrl_name }
    assert_equal 200, last_response.status
    assert_equal 1, enqueued_items.length
    assert_equal :e_applying, enqueued_items[0].phase
  end

  # ── GET /enhance/locks ───────────────────────────────────────

  def test_locks_returns_200_json
    get "/enhance/locks"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type
  end

  def test_locks_returns_lock_state_structure
    get "/enhance/locks"
    body = JSON.parse(last_response.body)
    assert body.key?("active_grants"), "Should include active_grants key"
    assert body.key?("queue_depth"),   "Should include queue_depth key"
    assert body.key?("active_items"),  "Should include active_items key"
  end

  def test_locks_returns_empty_grants_when_no_locks
    get "/enhance/locks"
    body = JSON.parse(last_response.body)
    assert_equal [], body["active_grants"]
    assert_equal 0,  body["queue_depth"]
    assert_equal [],  body["active_items"]
  end
end
