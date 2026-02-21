# frozen_string_literal: true

require_relative "orchestration_test_helper"

class BatchExecutionTest < OrchestrationTestCase
  def setup
    super
    @ctrl_name = "posts_controller"
    @ctrl_path = create_controller(@ctrl_name)
    seed_controller(@ctrl_name)
  end

  # ── Fixtures ───────────────────────────────────────────────

  ENHANCE_ANALYSIS = {
    "controller" => "posts_controller",
    "intent" => "Manages CRUD operations for blog posts",
    "architecture_notes" => "Standard scaffold controller",
    "improvement_areas" => [],
    "research_topics" => []
  }.freeze

  APPLY_RESPONSE = {
    "status" => "applied",
    "batch_id" => "batch_001",
    "files_modified" => [
      { "path" => "app/controllers/blog/posts_controller.rb", "action" => "modified" }
    ],
    "changes_applied" => [
      { "item_id" => "item_001", "action_taken" => "Added eager loading" }
    ]
  }.freeze

  APPLY_RESPONSE_B2 = {
    "status" => "applied",
    "batch_id" => "batch_002",
    "files_modified" => [
      { "path" => "app/controllers/blog/posts_controller.rb", "action" => "modified" }
    ],
    "changes_applied" => [
      { "item_id" => "item_002", "action_taken" => "Extracted query scope" }
    ]
  }.freeze

  FIX_TESTS_RESPONSE = {
    "status" => "fixed",
    "files_modified" => [],
    "fixes_applied" => [],
    "hardening_reverted" => []
  }.freeze

  FIX_CI_RESPONSE = {
    "status" => "fixed",
    "files_modified" => [],
    "fixes_applied" => [],
    "unfixable_issues" => []
  }.freeze

  VERIFY_RESPONSE = {
    "status" => "verified",
    "items_verified" => [],
    "new_issues" => [],
    "syntax_valid" => true,
    "recommendation" => "accept",
    "notes" => ""
  }.freeze

  ONE_BATCH_PLAN = {
    "batches" => [
      {
        "id" => "batch_001",
        "title" => "Add eager loading",
        "items" => ["item_001"],
        "write_targets" => ["app/controllers/blog/posts_controller.rb"],
        "estimated_effort" => "low",
        "rationale" => "High impact, low effort"
      }
    ]
  }.freeze

  TWO_BATCH_PLAN = {
    "batches" => [
      {
        "id" => "batch_001",
        "title" => "Add eager loading",
        "items" => ["item_001"],
        "write_targets" => ["app/controllers/blog/posts_controller.rb"],
        "estimated_effort" => "low",
        "rationale" => "High impact, low effort"
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
        "rationale" => "Medium effort"
      }
    ]
  }.freeze

  def seed_workflow_for_batch_execution(batches_plan = ONE_BATCH_PLAN)
    seed_workflow(@ctrl_name,
                  status: "e_awaiting_batch_approval",
                  e_analysis: ENHANCE_ANALYSIS,
                  e_batches: batches_plan,
                  original_source: CONTROLLER_SOURCE)
  end

  def stub_all_shared_phases_success
    # stub apply: writes HARDENED_SOURCE, returns e_batch_applied
    ctrl_path = @ctrl_path
    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      File.write(ctrl_path, BatchExecutionTest::HARDENED_SOURCE)
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:applied_status] if wf
      end
    end

    # stub test: passes immediately → e_batch_tested
    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:tested_status] if wf
      end
    end

    # stub ci: passes immediately → e_batch_ci_passed
    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:ci_passed_status] if wf
      end
    end

    # stub verify: passes → e_batch_complete
    @pipeline.define_singleton_method(:shared_verify) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:verified_status] if wf
      end
    end
  end

  def enhance_batch_sidecar_dir(batch_id)
    File.join(File.dirname(@ctrl_path), ".enhance", @ctrl_name, "batches", batch_id)
  end

  def enhance_batch_sidecar_exists?(batch_id, filename)
    File.exist?(File.join(enhance_batch_sidecar_dir(batch_id), filename))
  end

  # ── Happy path: single batch, full chain ──────────────────

  def test_single_batch_advances_to_enhance_complete
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)
    stub_all_shared_phases_success

    @pipeline.run_batch_execution(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "e_enhance_complete", wf[:status],
                 "Single batch should advance to e_enhance_complete"
  end

  def test_current_batch_id_tracked_during_execution
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)
    batch_ids_seen = []
    ctrl_name = @ctrl_name
    pipeline = @pipeline

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      wf_snap = @state[:workflows][name]
      batch_ids_seen << wf_snap[:current_batch_id] if wf_snap
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:applied_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:tested_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:ci_passed_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_verify) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:verified_status] if wf
      end
    end

    @pipeline.run_batch_execution(@ctrl_name)

    assert_includes batch_ids_seen, "batch_001",
                    "current_batch_id should be set to batch_001 during execution"
  end

  # ── Two batches: sequential chain ─────────────────────────

  def test_two_batches_run_sequentially
    seed_workflow_for_batch_execution(TWO_BATCH_PLAN)
    apply_calls = []

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      wf_snap = @state[:workflows][name]
      apply_calls << (wf_snap ? wf_snap[:current_batch_id] : nil)
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:applied_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:tested_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:ci_passed_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_verify) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:verified_status] if wf
      end
    end

    @pipeline.run_batch_execution(@ctrl_name)

    assert_equal 2, apply_calls.length,
                 "Both batches should be applied"
    assert_equal "batch_001", apply_calls[0],
                 "batch_001 should execute first"
    assert_equal "batch_002", apply_calls[1],
                 "batch_002 should execute second"
  end

  def test_two_batches_advance_to_enhance_complete
    seed_workflow_for_batch_execution(TWO_BATCH_PLAN)
    stub_all_shared_phases_success

    @pipeline.run_batch_execution(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "e_enhance_complete", wf[:status],
                 "Two batches completing should advance to e_enhance_complete"
  end

  def test_current_batch_id_updated_for_each_batch
    seed_workflow_for_batch_execution(TWO_BATCH_PLAN)
    apply_batch_ids = []

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        apply_batch_ids << (wf ? wf[:current_batch_id] : nil)
        wf[:status] = kwargs[:applied_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:tested_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:ci_passed_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_verify) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:verified_status] if wf
      end
    end

    @pipeline.run_batch_execution(@ctrl_name)

    assert_equal ["batch_001", "batch_002"], apply_batch_ids,
                 "current_batch_id must be updated to each batch before apply is called"
  end

  # ── e_tests_failed: test loop exhaustion ─────────────────

  def test_tests_failed_status_on_exhaustion
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:applied_status] if wf
      end
    end

    # Tests fail exhausted → sets e_tests_failed
    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:tests_failed_status] if wf
      end
    end

    ci_called = false
    @pipeline.define_singleton_method(:shared_ci_check) do |*args, **kwargs|
      ci_called = true
    end

    verify_called = false
    @pipeline.define_singleton_method(:shared_verify) do |*args, **kwargs|
      verify_called = true
    end

    @pipeline.run_batch_execution(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "e_tests_failed", wf[:status],
                 "Status must be e_tests_failed when test loop exhausted"
    refute ci_called, "CI check should not run after test failure"
    refute verify_called, "Verify should not run after test failure"
  end

  def test_tests_failed_stops_batch_chain
    seed_workflow_for_batch_execution(TWO_BATCH_PLAN)
    apply_calls = 0

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      apply_calls += 1
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:applied_status] if wf
      end
    end

    # First test run fails
    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:tests_failed_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_ci_check) do |*args, **kwargs|; end
    @pipeline.define_singleton_method(:shared_verify) do |*args, **kwargs|; end

    @pipeline.run_batch_execution(@ctrl_name)

    assert_equal 1, apply_calls,
                 "Only batch_001 apply should run; batch_002 should not start after test failure"
  end

  # ── e_ci_failed: CI loop exhaustion ──────────────────────

  def test_ci_failed_status_on_exhaustion
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:applied_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:tested_status] if wf
      end
    end

    # CI fails exhausted → sets e_ci_failed
    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:ci_failed_status] if wf
      end
    end

    verify_called = false
    @pipeline.define_singleton_method(:shared_verify) do |*args, **kwargs|
      verify_called = true
    end

    @pipeline.run_batch_execution(@ctrl_name)

    wf = workflow_state(@ctrl_name)
    assert_equal "e_ci_failed", wf[:status],
                 "Status must be e_ci_failed when CI loop exhausted"
    refute verify_called, "Verify should not run after CI failure"
  end

  def test_ci_failed_stops_batch_chain
    seed_workflow_for_batch_execution(TWO_BATCH_PLAN)
    apply_calls = 0

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      apply_calls += 1
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:applied_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:tested_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:ci_failed_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_verify) do |*args, **kwargs|; end

    @pipeline.run_batch_execution(@ctrl_name)

    assert_equal 1, apply_calls,
                 "Only batch_001 apply should run; batch_002 should not start after CI failure"
  end

  # ── Shared phase delegation: kwargs ──────────────────────

  def test_shared_apply_called_with_enhance_kwargs
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)
    captured_kwargs = nil

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      captured_kwargs = kwargs
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:applied_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:tested_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:ci_passed_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_verify) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:verified_status] if wf
      end
    end

    @pipeline.run_batch_execution(@ctrl_name)

    refute_nil captured_kwargs, "shared_apply must be called"
    assert_equal "e_applying",     captured_kwargs[:applying_status]
    assert_equal "e_batch_applied", captured_kwargs[:applied_status]
    assert_equal :e_analysis,      captured_kwargs[:analysis_key]
    refute_nil captured_kwargs[:sidecar_output_dir],
               "sidecar_output_dir must be set for batch-specific output"
    assert_includes captured_kwargs[:sidecar_output_dir], "batch_001"
    assert_includes captured_kwargs[:sidecar_output_dir], "batches"
  end

  def test_shared_test_called_with_enhance_kwargs
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)
    captured_kwargs = nil

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:applied_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      captured_kwargs = kwargs
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:tested_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:ci_passed_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_verify) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:verified_status] if wf
      end
    end

    @pipeline.run_batch_execution(@ctrl_name)

    refute_nil captured_kwargs, "shared_test must be called"
    assert_equal "e_batch_applied", captured_kwargs[:guard_status]
    assert_equal "e_testing",       captured_kwargs[:testing_status]
    assert_equal "e_fixing_tests",  captured_kwargs[:fixing_status]
    assert_equal "e_batch_tested",  captured_kwargs[:tested_status]
    assert_equal "e_tests_failed",  captured_kwargs[:tests_failed_status]
    assert_equal :e_analysis,       captured_kwargs[:analysis_key]
  end

  def test_shared_ci_check_called_with_enhance_kwargs
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)
    captured_kwargs = nil

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:applied_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:tested_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      captured_kwargs = kwargs
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:ci_passed_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_verify) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:verified_status] if wf
      end
    end

    @pipeline.run_batch_execution(@ctrl_name)

    refute_nil captured_kwargs, "shared_ci_check must be called"
    assert_equal "e_batch_tested",    captured_kwargs[:guard_status]
    assert_equal "e_ci_checking",     captured_kwargs[:ci_checking_status]
    assert_equal "e_fixing_ci",       captured_kwargs[:fixing_status]
    assert_equal "e_batch_ci_passed", captured_kwargs[:ci_passed_status]
    assert_equal "e_ci_failed",       captured_kwargs[:ci_failed_status]
    assert_equal :e_analysis,         captured_kwargs[:analysis_key]
  end

  def test_shared_verify_called_with_enhance_kwargs
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)
    captured_kwargs = nil

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:applied_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:tested_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:ci_passed_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_verify) do |name, **kwargs|
      captured_kwargs = kwargs
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:verified_status] if wf
      end
    end

    @pipeline.run_batch_execution(@ctrl_name)

    refute_nil captured_kwargs, "shared_verify must be called"
    assert_equal "e_batch_ci_passed", captured_kwargs[:guard_status]
    assert_equal "e_verifying",       captured_kwargs[:verifying_status]
    assert_equal "e_batch_complete",  captured_kwargs[:verified_status]
    assert_equal :e_analysis,         captured_kwargs[:analysis_key]
  end

  # ── Apply prompt lambda delegates to Prompts.e_apply ──────

  def test_apply_prompt_fn_invokes_e_apply
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)
    captured_prompt_fn = nil

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      captured_prompt_fn = kwargs[:apply_prompt_fn]
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:applied_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:tested_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:ci_passed_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_verify) do |name, **kwargs|
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:verified_status] if wf
      end
    end

    @pipeline.run_batch_execution(@ctrl_name)

    refute_nil captured_prompt_fn, "apply_prompt_fn must be passed to shared_apply"
    # Call the lambda to verify it returns a string prompt
    prompt_result = captured_prompt_fn.call("posts_controller", "source code", "{}", nil, staging_dir: "/tmp/staging")
    assert_instance_of String, prompt_result
    assert prompt_result.length > 0, "e_apply prompt must be non-empty"
  end

  # ── Empty batches: no-op ───────────────────────────────────

  def test_empty_batches_returns_without_status_change
    seed_workflow(@ctrl_name,
                  status: "e_awaiting_batch_approval",
                  e_analysis: ENHANCE_ANALYSIS,
                  e_batches: { "batches" => [] },
                  original_source: CONTROLLER_SOURCE)

    shared_apply_called = false
    @pipeline.define_singleton_method(:shared_apply) { |*args, **kwargs| shared_apply_called = true }

    @pipeline.run_batch_execution(@ctrl_name)

    refute shared_apply_called, "shared_apply should not be called with empty batches"
    wf = workflow_state(@ctrl_name)
    # Status should remain as-is (not changed to e_enhance_complete)
    assert_equal "e_awaiting_batch_approval", wf[:status]
  end

  # ── Missing workflow: no crash ─────────────────────────────

  def test_missing_workflow_returns_without_crash
    # Should return nil without raising
    result = nil
    begin
      result = @pipeline.run_batch_execution("nonexistent_controller")
    rescue => e
      flunk "run_batch_execution raised #{e.class}: #{e.message}"
    end
    # No assertion needed — just confirming no exception
    assert_nil result
  end

  # ── Grant lifecycle: acquired, renewed, released ──────────

  def test_grant_acquired_before_apply
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)

    lock_manager = @pipeline.instance_variable_get(:@lock_manager)
    acquire_calls = []
    original_acquire = lock_manager.method(:acquire)

    lock_manager.define_singleton_method(:acquire) do |holder:, write_paths:, timeout: 30, interval: 0.5|
      acquire_calls << { holder: holder, write_paths: write_paths }
      original_acquire.call(holder: holder, write_paths: write_paths, timeout: timeout, interval: interval)
    end

    stub_all_shared_phases_success

    @pipeline.run_batch_execution(@ctrl_name)

    assert_equal 1, acquire_calls.length, "LockManager#acquire should be called once (one batch)"
    assert_includes acquire_calls[0][:holder], "batch_001",
                    "Grant holder should identify the batch"
  end

  def test_grant_passed_to_shared_apply
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)
    captured_grant_id = nil

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      captured_grant_id = kwargs[:grant_id]
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:applied_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:tested_status] }
    end

    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:ci_passed_status] }
    end

    @pipeline.define_singleton_method(:shared_verify) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:verified_status] }
    end

    @pipeline.run_batch_execution(@ctrl_name)

    refute_nil captured_grant_id, "grant_id must be passed to shared_apply"
    # Verify it looks like a UUID
    assert_match(/\A[0-9a-f-]{36}\z/, captured_grant_id)
  end

  def test_grant_passed_to_shared_test
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)
    captured_grant_id = nil

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:applied_status] }
    end

    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      captured_grant_id = kwargs[:grant_id]
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:tested_status] }
    end

    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:ci_passed_status] }
    end

    @pipeline.define_singleton_method(:shared_verify) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:verified_status] }
    end

    @pipeline.run_batch_execution(@ctrl_name)

    refute_nil captured_grant_id, "grant_id must be passed to shared_test"
    assert_match(/\A[0-9a-f-]{36}\z/, captured_grant_id)
  end

  def test_grant_passed_to_shared_ci_check
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)
    captured_grant_id = nil

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:applied_status] }
    end

    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:tested_status] }
    end

    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      captured_grant_id = kwargs[:grant_id]
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:ci_passed_status] }
    end

    @pipeline.define_singleton_method(:shared_verify) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:verified_status] }
    end

    @pipeline.run_batch_execution(@ctrl_name)

    refute_nil captured_grant_id, "grant_id must be passed to shared_ci_check"
    assert_match(/\A[0-9a-f-]{36}\z/, captured_grant_id)
  end

  def test_grant_released_after_batch_completes
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)
    stub_all_shared_phases_success

    lock_manager = @pipeline.instance_variable_get(:@lock_manager)
    released_ids = []
    original_release = lock_manager.method(:release)

    lock_manager.define_singleton_method(:release) do |grant_id|
      released_ids << grant_id
      original_release.call(grant_id)
    end

    @pipeline.run_batch_execution(@ctrl_name)

    assert_equal 1, released_ids.length,
                 "Grant should be released exactly once after single batch completion"
    assert_empty lock_manager.active_grants,
                 "No grants should remain active after batch execution"
  end

  def test_grant_released_on_tests_failed
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)

    lock_manager = @pipeline.instance_variable_get(:@lock_manager)
    released_ids = []
    original_release = lock_manager.method(:release)

    lock_manager.define_singleton_method(:release) do |grant_id|
      released_ids << grant_id
      original_release.call(grant_id)
    end

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:applied_status] }
    end

    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:tests_failed_status] }
    end

    @pipeline.define_singleton_method(:shared_ci_check) { |*args, **kwargs| }
    @pipeline.define_singleton_method(:shared_verify)   { |*args, **kwargs| }

    @pipeline.run_batch_execution(@ctrl_name)

    assert_equal 1, released_ids.length,
                 "Grant must be released via ensure even on e_tests_failed"
    assert_empty lock_manager.active_grants,
                 "No grants should remain active after test failure"
  end

  def test_grant_released_on_ci_failed
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)

    lock_manager = @pipeline.instance_variable_get(:@lock_manager)
    released_ids = []
    original_release = lock_manager.method(:release)

    lock_manager.define_singleton_method(:release) do |grant_id|
      released_ids << grant_id
      original_release.call(grant_id)
    end

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:applied_status] }
    end

    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:tested_status] }
    end

    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:ci_failed_status] }
    end

    @pipeline.define_singleton_method(:shared_verify) { |*args, **kwargs| }

    @pipeline.run_batch_execution(@ctrl_name)

    assert_equal 1, released_ids.length,
                 "Grant must be released via ensure even on e_ci_failed"
    assert_empty lock_manager.active_grants,
                 "No grants should remain active after CI failure"
  end

  def test_grant_renewed_after_each_phase
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)

    lock_manager = @pipeline.instance_variable_get(:@lock_manager)
    renew_calls = []
    original_renew = lock_manager.method(:renew)

    lock_manager.define_singleton_method(:renew) do |grant_id|
      renew_calls << grant_id
      original_renew.call(grant_id)
    end

    stub_all_shared_phases_success

    @pipeline.run_batch_execution(@ctrl_name)

    # Should renew after apply, test, ci_check, and verify — 4 renewals per batch
    assert renew_calls.length >= 4,
           "Grant should be renewed after each phase (at least 4 renewals for one batch)"
    assert renew_calls.all? { |id| id.match?(/\A[0-9a-f-]{36}\z/) },
           "All renewal calls should use a valid grant ID"
    # All renewals should be for the same grant
    assert_equal 1, renew_calls.uniq.length, "All renewals should be for the same grant"
  end

  def test_separate_grants_acquired_for_each_batch
    seed_workflow_for_batch_execution(TWO_BATCH_PLAN)

    lock_manager = @pipeline.instance_variable_get(:@lock_manager)
    acquired_grants = []
    original_acquire = lock_manager.method(:acquire)

    lock_manager.define_singleton_method(:acquire) do |holder:, write_paths:, timeout: 30, interval: 0.5|
      grant = original_acquire.call(holder: holder, write_paths: write_paths, timeout: timeout, interval: interval)
      acquired_grants << grant
      grant
    end

    stub_all_shared_phases_success

    @pipeline.run_batch_execution(@ctrl_name)

    assert_equal 2, acquired_grants.length, "A separate grant should be acquired for each batch"
    ids = acquired_grants.map(&:id)
    assert_equal 2, ids.uniq.length, "Each batch should get a distinct grant ID"
  end

  def test_two_batches_all_grants_released
    seed_workflow_for_batch_execution(TWO_BATCH_PLAN)
    stub_all_shared_phases_success

    lock_manager = @pipeline.instance_variable_get(:@lock_manager)

    @pipeline.run_batch_execution(@ctrl_name)

    assert_empty lock_manager.active_grants,
                 "All grants must be released after two-batch execution"
  end

  def test_retry_reacquires_lock_on_tests_failed
    # Run once → tests fail → grant released.
    # Simulate a retry by calling run_batch_execution again — it should re-acquire the lock.
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)

    lock_manager = @pipeline.instance_variable_get(:@lock_manager)
    acquire_calls = []
    original_acquire = lock_manager.method(:acquire)

    lock_manager.define_singleton_method(:acquire) do |holder:, write_paths:, timeout: 30, interval: 0.5|
      grant = original_acquire.call(holder: holder, write_paths: write_paths, timeout: timeout, interval: interval)
      acquire_calls << grant
      grant
    end

    # First run: tests fail
    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:applied_status] }
    end

    fail_test = true
    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      if fail_test
        @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:tests_failed_status] }
      else
        @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:tested_status] }
      end
    end

    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:ci_passed_status] }
    end

    @pipeline.define_singleton_method(:shared_verify) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:verified_status] }
    end

    @pipeline.run_batch_execution(@ctrl_name)
    assert_equal 1, acquire_calls.length, "First run: one grant acquired"
    assert_empty lock_manager.active_grants, "First run: grant released after e_tests_failed"

    # Re-seed workflow to e_awaiting_batch_approval for retry
    seed_workflow(@ctrl_name,
                  status: "e_awaiting_batch_approval",
                  e_analysis: ENHANCE_ANALYSIS,
                  e_batches: ONE_BATCH_PLAN,
                  original_source: CONTROLLER_SOURCE)

    # Second run: succeed
    fail_test = false
    @pipeline.run_batch_execution(@ctrl_name)

    assert_equal 2, acquire_calls.length, "Retry: a second grant must be acquired"
    assert_empty lock_manager.active_grants, "Retry: grant released after success"
  end

  # ── Batch sidecar directory structure ─────────────────────

  def test_batch_sidecar_dir_uses_batch_id
    seed_workflow_for_batch_execution(ONE_BATCH_PLAN)
    captured_sidecar_dir = nil

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      captured_sidecar_dir = kwargs[:sidecar_output_dir]
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:applied_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:tested_status] }
    end

    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:ci_passed_status] }
    end

    @pipeline.define_singleton_method(:shared_verify) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:verified_status] }
    end

    @pipeline.run_batch_execution(@ctrl_name)

    refute_nil captured_sidecar_dir
    assert_match %r{/batches/batch_001\z}, captured_sidecar_dir,
                 "sidecar_output_dir should end with /batches/<batch_id>"
    assert_match %r{/\.enhance/}, captured_sidecar_dir,
                 "sidecar_output_dir should be under the .enhance directory"
    assert Dir.exist?(captured_sidecar_dir),
           "Batch sidecar directory should be created"
  end

  def test_two_batches_use_separate_sidecar_dirs
    seed_workflow_for_batch_execution(TWO_BATCH_PLAN)
    sidecar_dirs = []

    @pipeline.define_singleton_method(:shared_apply) do |name, **kwargs|
      sidecar_dirs << kwargs[:sidecar_output_dir]
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = kwargs[:applied_status] if wf
      end
    end

    @pipeline.define_singleton_method(:shared_test) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:tested_status] }
    end

    @pipeline.define_singleton_method(:shared_ci_check) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:ci_passed_status] }
    end

    @pipeline.define_singleton_method(:shared_verify) do |name, **kwargs|
      @mutex.synchronize { @state[:workflows][name]&.[]= :status, kwargs[:verified_status] }
    end

    @pipeline.run_batch_execution(@ctrl_name)

    assert_equal 2, sidecar_dirs.length, "Expected 2 apply calls (one per batch)"
    refute_equal sidecar_dirs[0], sidecar_dirs[1],
                 "Each batch must use a different sidecar directory"
    assert_match %r{/batches/batch_001\z}, sidecar_dirs[0]
    assert_match %r{/batches/batch_002\z}, sidecar_dirs[1]
  end
end
