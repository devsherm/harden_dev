# frozen_string_literal: true

require_relative "test_helper"

class OrchestrationTestCase < PipelineTestCase
  CONTROLLER_SOURCE = <<~RUBY
    class Blog::PostsController < ApplicationController
      def index
        @posts = Blog::Post.all
      end
    end
  RUBY

  HARDENED_SOURCE = <<~RUBY
    class Blog::PostsController < ApplicationController
      before_action :authenticate_user!

      def index
        @posts = Blog::Post.all
      end
    end
  RUBY

  def setup
    super
    @claude_calls = []
    @spawn_calls = []
    FileUtils.mkdir_p(File.join(@tmpdir, "app", "controllers", "blog"))
    @original_report_on_exception = Thread.report_on_exception
    Thread.report_on_exception = false
  end

  def teardown
    Thread.report_on_exception = @original_report_on_exception
    super
  end

  # ── Filesystem scaffolding ────────────────────────────────

  def create_controller(name, source = CONTROLLER_SOURCE)
    path = controller_path(name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
    harden_dir = File.join(File.dirname(path), ".harden", name)
    FileUtils.mkdir_p(harden_dir)
    path
  end

  def create_test_file(name)
    test_path = File.join(@tmpdir, "test", "controllers", "blog", "#{name}_test.rb")
    FileUtils.mkdir_p(File.dirname(test_path))
    File.write(test_path, "# test stub for #{name}")
    test_path
  end

  def controller_path(name)
    File.join(@tmpdir, "app", "controllers", "blog", "#{name}.rb")
  end

  def read_sidecar(ctrl_path, filename)
    sidecar = File.join(File.dirname(ctrl_path), ".harden",
                        File.basename(ctrl_path, ".rb"), filename)
    JSON.parse(File.read(sidecar))
  end

  def sidecar_exists?(ctrl_path, filename)
    sidecar = File.join(File.dirname(ctrl_path), ".harden",
                        File.basename(ctrl_path, ".rb"), filename)
    File.exist?(sidecar)
  end

  # ── Workflow seeding ──────────────────────────────────────

  def seed_controller(name)
    full_path = controller_path(name)
    relative = "app/controllers/blog/#{name}.rb"
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
    @pipeline.instance_variable_get(:@mutex).synchronize do
      @pipeline.instance_variable_get(:@state)[:controllers] << entry
    end
  end

  def seed_workflow(name, overrides = {})
    mutex = @pipeline.instance_variable_get(:@mutex)
    state = @pipeline.instance_variable_get(:@state)
    entry = mutex.synchronize { state[:controllers].find { |c| c[:name] == name } }
    raise "Controller not seeded: #{name}" unless entry

    workflow = {
      name: entry[:name], path: entry[:path], full_path: entry[:full_path],
      status: "pending", analysis: nil, decision: nil, hardened: nil,
      test_results: nil, ci_results: nil, verification: nil,
      error: nil, started_at: nil, completed_at: nil, original_source: nil
    }.merge(overrides)

    mutex.synchronize { state[:workflows][name] = workflow }
  end

  def workflow_state(name)
    @pipeline.instance_variable_get(:@mutex).synchronize do
      wf = @pipeline.instance_variable_get(:@state)[:workflows][name]
      wf ? Marshal.load(Marshal.dump(wf)) : nil
    end
  end

  def global_errors
    @pipeline.instance_variable_get(:@mutex).synchronize do
      @pipeline.instance_variable_get(:@state)[:errors].dup
    end
  end

  # ── Fixture factories ─────────────────────────────────────

  def analysis_fixture
    {
      "controller" => "posts_controller",
      "status" => "analyzed",
      "findings" => [
        { "id" => "finding_001", "severity" => "high", "category" => "authorization",
          "scope" => "controller", "action" => "destroy",
          "summary" => "Missing authorization check",
          "detail" => "No auth check on destroy action",
          "suggested_fix" => "Add before_action :authenticate_user!" },
        { "id" => "finding_002", "severity" => "medium", "category" => "params",
          "scope" => "controller", "action" => "create",
          "summary" => "Weak strong parameters",
          "detail" => "Permits too many attributes",
          "suggested_fix" => "Restrict permitted params" }
      ],
      "overall_risk" => "high",
      "notes" => "Controller needs hardening"
    }
  end

  def hardened_fixture
    {
      "controller" => "posts_controller",
      "status" => "hardened",
      "summary" => "Added authorization checks",
      "files_modified" => [
        { "path" => "app/controllers/blog/posts_controller.rb", "action" => "modified" }
      ],
      "changes_applied" => [
        { "finding_id" => "finding_001", "action_taken" => "Added authorization",
          "lines_affected" => "1-3" }
      ],
      "warnings" => []
    }
  end

  def decision_fixture(action: "approve")
    { "action" => action }
  end

  def fix_tests_fixture
    {
      "controller" => "posts_controller",
      "status" => "fixed",
      "files_modified" => [
        { "path" => "app/controllers/blog/posts_controller.rb", "action" => "modified" }
      ],
      "fixes_applied" => [
        { "description" => "Fixed test issue", "hardening_preserved" => true, "notes" => "" }
      ],
      "hardening_reverted" => []
    }
  end

  def fix_ci_fixture
    {
      "controller" => "posts_controller",
      "status" => "fixed",
      "files_modified" => [
        { "path" => "app/controllers/blog/posts_controller.rb", "action" => "modified" }
      ],
      "fixes_applied" => [
        { "description" => "Fixed CI issue", "check" => "rubocop",
          "hardening_preserved" => true, "notes" => "" }
      ],
      "unfixable_issues" => []
    }
  end

  def verification_fixture
    {
      "controller" => "posts_controller",
      "status" => "verified",
      "findings_addressed" => [
        { "finding_id" => "finding_001", "addressed" => true, "notes" => "" }
      ],
      "new_issues" => [],
      "syntax_valid" => true,
      "recommendation" => "accept",
      "notes" => ""
    }
  end

  # ── Stubbing helpers ──────────────────────────────────────

  def stub_claude_call(response_hash)
    calls = @claude_calls
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      calls << { prompt: prompt }
      JSON.generate(response_hash)
    end
  end

  def stub_claude_call_sequence(responses)
    calls = @claude_calls
    idx = 0
    mutex = Mutex.new
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      i = mutex.synchronize { idx.tap { idx += 1 } }
      calls << { prompt: prompt }
      JSON.generate(responses[i] || responses.last)
    end
  end

  def stub_claude_call_failure(msg)
    @pipeline.define_singleton_method(:claude_call) do |prompt|
      raise RuntimeError, msg
    end
  end

  # Stub copy_from_staging to write HARDENED_SOURCE to the controller path.
  # This simulates what the real copy_from_staging does when the agent wrote
  # the file to the staging directory.
  def stub_copy_from_staging(ctrl_path, source = HARDENED_SOURCE)
    path = ctrl_path
    content = source
    @pipeline.define_singleton_method(:copy_from_staging) do |staging_dir|
      File.write(path, content)
    end
  end

  # Stub copy_from_staging with a sequence of source contents (one per call).
  def stub_copy_from_staging_sequence(ctrl_path, sources)
    path = ctrl_path
    idx = 0
    mutex = Mutex.new
    @pipeline.define_singleton_method(:copy_from_staging) do |staging_dir|
      i = mutex.synchronize { idx.tap { idx += 1 } }
      File.write(path, sources[i] || sources.last)
    end
  end

  def stub_spawn(output:, success:)
    calls = @spawn_calls
    @pipeline.define_singleton_method(:spawn_with_timeout) do |*cmd, timeout:, chdir: nil|
      calls << { cmd: cmd, timeout: timeout, chdir: chdir }
      [output, success]
    end
  end

  def stub_spawn_sequence(results)
    calls = @spawn_calls
    idx = 0
    mutex = Mutex.new
    @pipeline.define_singleton_method(:spawn_with_timeout) do |*cmd, timeout:, chdir: nil|
      calls << { cmd: cmd, timeout: timeout, chdir: chdir }
      i = mutex.synchronize { idx.tap { idx += 1 } }
      results[i] || results.last
    end
  end

  def stub_ci_checks_pass
    @pipeline.define_singleton_method(:run_all_ci_checks) do |controller_relative|
      Pipeline::CI_CHECKS.map do |c|
        { name: c[:name], command: c[:cmd].call(controller_relative).join(" "),
          passed: true, output: "OK" }
      end
    end
  end

  def stub_ci_checks_sequence(results_sequence)
    idx = 0
    mutex = Mutex.new
    @pipeline.define_singleton_method(:run_all_ci_checks) do |controller_relative|
      i = mutex.synchronize { idx.tap { idx += 1 } }
      results_sequence[i] || results_sequence.last
    end
  end

  def capture_chained_call(method_name)
    recorder = Object.new
    recorder.instance_variable_set(:@called, false)
    recorder.instance_variable_set(:@call_args, nil)
    recorder.define_singleton_method(:called?) { @called }
    recorder.define_singleton_method(:args) { @call_args }
    rec = recorder
    @pipeline.define_singleton_method(method_name) do |*args|
      rec.instance_variable_set(:@called, true)
      rec.instance_variable_set(:@call_args, args)
    end
    recorder
  end

  # ── CI check result helpers ──────────────────────────────

  def passing_ci_results
    Pipeline::CI_CHECKS.map do |c|
      { name: c[:name], command: "cmd", passed: true, output: "OK" }
    end
  end

  def failing_ci_results(fail_names = ["rubocop"])
    Pipeline::CI_CHECKS.map do |c|
      passed = !fail_names.include?(c[:name])
      { name: c[:name], command: "cmd", passed: passed,
        output: passed ? "OK" : "FAIL" }
    end
  end
end
