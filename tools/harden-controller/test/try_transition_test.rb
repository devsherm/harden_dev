# frozen_string_literal: true

require_relative "test_helper"

class TryTransitionTest < PipelineTestCase
  def setup
    super
    FileUtils.mkdir_p(File.join(@tmpdir, "app", "controllers", "blog"))
    seed_controller("posts_controller")
  end

  # ── Helpers ──────────────────────────────────────────────

  def seed_controller(name)
    entry = {
      name: name,
      path: "app/controllers/blog/#{name}.rb",
      full_path: File.join(@tmpdir, "app", "controllers", "blog", "#{name}.rb"),
      phases: { analyzed: false, hardened: false, tested: false,
                ci_checked: false, verified: false },
      existing_analysis_at: nil, existing_hardened_at: nil,
      existing_tested_at: nil, existing_ci_at: nil, existing_verified_at: nil,
      stale: nil, overall_risk: nil, finding_counts: nil
    }
    @pipeline.instance_variable_get(:@mutex).synchronize do
      @pipeline.instance_variable_get(:@state)[:controllers] << entry
    end
  end

  def seed_workflow(name, overrides = {})
    state = @pipeline.instance_variable_get(:@state)
    entry = state[:controllers].find { |c| c[:name] == name }
    workflow = {
      name: entry[:name], path: entry[:path], full_path: entry[:full_path],
      status: "pending", analysis: nil, decision: nil, hardened: nil,
      test_results: nil, ci_results: nil, verification: nil,
      error: nil, started_at: nil, completed_at: nil, original_source: nil
    }.merge(overrides)
    @pipeline.instance_variable_get(:@mutex).synchronize do
      state[:workflows][name] = workflow
    end
  end

  # ── :not_active guard tests ─────────────────────────────

  def test_not_active_guard_no_existing_workflow
    ok, err = @pipeline.try_transition("posts_controller", guard: :not_active, to: "analyzing")

    assert ok, "Expected success but got error: #{err}"
    assert_nil err
    wf = @pipeline.instance_variable_get(:@state)[:workflows]["posts_controller"]
    assert_equal "analyzing", wf[:status]
    assert wf[:started_at], "Should set started_at"
  end

  def test_not_active_guard_with_active_workflow_fails
    seed_workflow("posts_controller", status: "analyzing")

    ok, err = @pipeline.try_transition("posts_controller", guard: :not_active, to: "analyzing")

    refute ok
    assert_match(/already analyzing/, err)
  end

  def test_not_active_guard_with_completed_workflow_succeeds
    seed_workflow("posts_controller", status: "complete")

    ok, err = @pipeline.try_transition("posts_controller", guard: :not_active, to: "analyzing")

    assert ok, "Expected success for completed workflow but got: #{err}"
    assert_nil err
    wf = @pipeline.instance_variable_get(:@state)[:workflows]["posts_controller"]
    assert_equal "analyzing", wf[:status]
  end

  def test_not_active_guard_with_error_workflow_succeeds
    seed_workflow("posts_controller", status: "error")

    ok, err = @pipeline.try_transition("posts_controller", guard: :not_active, to: "analyzing")

    assert ok, "Expected success for errored workflow but got: #{err}"
  end

  def test_not_active_guard_unknown_controller_fails
    ok, err = @pipeline.try_transition("nonexistent_controller", guard: :not_active, to: "analyzing")

    refute ok
    assert_match(/Controller not found/, err)
  end

  # ── Named guard tests ──────────────────────────────────

  def test_named_guard_matching_transitions
    seed_workflow("posts_controller", status: "awaiting_decisions")

    ok, err = @pipeline.try_transition("posts_controller", guard: "awaiting_decisions", to: "hardening")

    assert ok, "Expected success but got: #{err}"
    assert_nil err
    wf = @pipeline.instance_variable_get(:@state)[:workflows]["posts_controller"]
    assert_equal "hardening", wf[:status]
    assert_nil wf[:error], "Error should be cleared on transition"
  end

  def test_named_guard_not_matching_fails
    seed_workflow("posts_controller", status: "analyzing")

    ok, err = @pipeline.try_transition("posts_controller", guard: "awaiting_decisions", to: "hardening")

    refute ok
    assert_match(/expected awaiting_decisions/, err)
  end

  def test_named_guard_missing_workflow_fails
    # No workflow seeded
    ok, err = @pipeline.try_transition("posts_controller", guard: "awaiting_decisions", to: "hardening")

    refute ok
    assert_match(/No workflow/, err)
  end

  # ── Concurrency safety test ────────────────────────────

  def test_concurrent_transitions_no_duplicates
    results = []
    mutex = Mutex.new

    threads = 10.times.map do
      Thread.new do
        ok, err = @pipeline.try_transition("posts_controller", guard: :not_active, to: "analyzing")
        mutex.synchronize { results << [ok, err] }
      end
    end
    threads.each(&:join)

    successes = results.count { |ok, _| ok }
    assert_equal 1, successes, "Exactly one concurrent transition should succeed, got #{successes}"

    failures = results.count { |ok, _| !ok }
    assert_equal 9, failures
  end
end
