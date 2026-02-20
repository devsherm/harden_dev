require "json"
require "time"
require "open3"
require "fileutils"
require "shellwords"
require "securerandom"
require_relative "prompts"

class Pipeline
  ACTIVE_STATUSES = %w[analyzing hardening testing fixing_tests ci_checking fixing_ci verifying].freeze
  CLAUDE_TIMEOUT = 120
  COMMAND_TIMEOUT = 60
  MAX_QUERIES = 50
  MAX_CLAUDE_CONCURRENCY = 12

  # Synchronized accessors — never expose @state directly.
  # Use workflow_status / workflow_data for route guards.

  def phase
    @mutex.synchronize { @state[:phase] }
  end

  def workflow_status(name)
    @mutex.synchronize { @state[:workflows][name]&.[](:status) }
  end

  def workflow_exists?(name)
    @mutex.synchronize { @state[:workflows].key?(name) }
  end

  # Atomically verify guard condition and transition workflow status.
  # For :not_active guard, creates the workflow if it doesn't exist.
  # Returns [true, nil] on success, [false, error_string] on failure.
  def try_transition(name, guard:, to:)
    @mutex.synchronize do
      wf = @state[:workflows][name]
      status = wf&.[](:status)

      case guard
      when :not_active
        if status && ACTIVE_STATUSES.include?(status)
          return [false, "#{name} is already #{status}"]
        end
        entry = @state[:controllers].find { |c| c[:name] == name }
        return [false, "Controller not found: #{name}"] unless entry
        @state[:workflows][name] = build_workflow(entry.dup).merge(status: to, error: nil, started_at: Time.now.iso8601)
      else
        return [false, "No workflow for #{name}"] unless wf
        return [false, "#{name} is #{status}, expected #{guard}"] unless status == guard.to_s
        wf[:status] = to
        wf[:error] = nil
      end

      [true, nil]
    end
  end

  def initialize(rails_root: ".")
    @rails_root = rails_root
    @mutex = Mutex.new
    @threads = []
    @cancelled = false
    @state = {
      phase: "idle",       # global: "idle" | "discovering" | "ready"
      controllers: [],     # discovery list (unchanged)
      workflows: {},       # keyed by controller name
      errors: []
    }
    @prompt_store = {}  # keyed by controller name → phase symbol
    @queries = []  # [{id:, controller:, type:, question:, finding_id:, status:, result:, error:, created_at:}]
    @cached_json = nil
    @last_serialized_at = 0
    @claude_semaphore = Mutex.new
    @claude_slots = ConditionVariable.new
    @claude_active = 0
  end

  # ── Thread Management ────────────────────────────────────────

  def safe_thread(workflow_name: nil, &block)
    t = Thread.new do
      raise "Pipeline is shutting down" if cancelled?
      block.call
    rescue => e
      if workflow_name
        @mutex.synchronize do
          wf = @state[:workflows][workflow_name]
          if wf && wf[:status] != "error"
            wf[:error] = sanitize_error(e.message)
            wf[:status] = "error"
            add_error("Thread failed for #{workflow_name}: #{e.message}")
          end
        end
      end
      $stderr.puts "[safe_thread] #{workflow_name || 'unnamed'} died: #{e.class}: #{e.message}"
      $stderr.puts e.backtrace.first(5).join("\n")
    end
    @mutex.synchronize do
      @threads.reject! { |t| !t.alive? }
      @threads << t
    end
    t
  end

  def cancel!
    @cancelled = true  # Atomic in CRuby (GVL), safe without mutex
  end

  def cancelled?
    @cancelled  # Atomic in CRuby (GVL), safe without mutex — matches cancel!
  end

  def shutdown(timeout: 5)
    threads = @mutex.synchronize do
      @cancelled = true
      @threads.dup
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    threads.each do |t|
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      t.join([remaining, 0].max)
    end
    threads.each { |t| t.kill if t.alive? }
  end

  # ── Discovery ──────────────────────────────────────────────

  def discover_controllers
    @mutex.synchronize { @state[:phase] = "discovering" }

    controllers_dir = File.join(@rails_root, "app", "controllers")
    unless Dir.exist?(controllers_dir)
      @mutex.synchronize do
        add_error("Controllers directory not found: #{controllers_dir}")
        @state[:phase] = "ready"
      end
      return
    end

    discovered = []

    Dir.glob(File.join(controllers_dir, "**", "*_controller.rb")).each do |path|
      basename = File.basename(path, ".rb")
      next if basename == "application_controller"

      relative = path.sub("#{@rails_root}/", "")
      controller_mtime = File.mtime(path)

      analysis_file = sidecar_path(path, "analysis.json")
      hardened_file = sidecar_path(path, "hardened.json")
      test_results_file = sidecar_path(path, "test_results.json")
      ci_results_file = sidecar_path(path, "ci_results.json")
      verified_file = sidecar_path(path, "verification.json")

      has_analysis = File.exist?(analysis_file)
      has_hardened = File.exist?(hardened_file)
      has_tested = File.exist?(test_results_file)
      has_ci = File.exist?(ci_results_file)
      has_verified = File.exist?(verified_file)

      overall_risk = nil
      finding_counts = nil
      if has_analysis
        begin
          data = JSON.parse(File.read(analysis_file))
          overall_risk = data["overall_risk"]
          findings = data["findings"] || []
          finding_counts = { high: 0, medium: 0, low: 0 }
          findings.each { |f| sev = f["severity"]&.downcase; finding_counts[sev.to_sym] += 1 if finding_counts.key?(sev&.to_sym) }
        rescue JSON::ParserError
          # Sidecar is corrupt — treat as no analysis data
        end
      end

      discovered << {
        name: basename,
        path: relative,
        full_path: path,
        phases: { analyzed: has_analysis, hardened: has_hardened, tested: has_tested, ci_checked: has_ci, verified: has_verified },
        existing_analysis_at: has_analysis ? File.mtime(analysis_file).iso8601 : nil,
        existing_hardened_at: has_hardened ? File.mtime(hardened_file).iso8601 : nil,
        existing_tested_at: has_tested ? File.mtime(test_results_file).iso8601 : nil,
        existing_ci_at: has_ci ? File.mtime(ci_results_file).iso8601 : nil,
        existing_verified_at: has_verified ? File.mtime(verified_file).iso8601 : nil,
        stale: has_analysis ? controller_mtime > File.mtime(analysis_file) : nil,
        overall_risk: overall_risk,
        finding_counts: finding_counts
      }
    end

    # Sort: needs-attention first, then by risk (high > medium > low > nil), then alphabetical
    risk_order = { "high" => 0, "medium" => 1, "low" => 2 }
    discovered.sort_by! do |c|
      needs_attention = (c[:stale] == true || c[:stale].nil?) ? 0 : 1
      risk = risk_order.fetch(c[:overall_risk], 3)
      [ needs_attention, risk, c[:name] ]
    end

    @mutex.synchronize do
      @state[:controllers] = discovered
      @state[:phase] = "ready"
    end
  rescue => e
    $stderr.puts "[discover_controllers] Failed: #{e.class}: #{e.message}"
    $stderr.puts e.backtrace.first(5).join("\n") if e.backtrace
    @mutex.synchronize do
      add_error("Controller discovery failed: #{e.message}")
      @state[:phase] = "ready"
    end
  end

  # ── Selection / Analysis ─────────────────────────────────────

  def select_controller(name)
    entry = find_controller(name)
    @mutex.synchronize do
      @state[:workflows][name] = build_workflow(entry)
    end
    run_analysis(name)
  end

  def load_existing_analysis(name)
    entry = find_controller(name)

    analysis_file = sidecar_path(entry[:full_path], "analysis.json")
    raise "No existing analysis for #{name}" unless File.exist?(analysis_file)

    raw = File.read(analysis_file)
    parsed = parse_json_response(raw)

    @mutex.synchronize do
      workflow = @state[:workflows][name] ||= build_workflow(entry)
      workflow[:analysis] = parsed
      workflow[:status] = "awaiting_decisions"
    end
  end

  # ── Phase 1: Analysis ──────────────────────────────────────

  def run_analysis(name)
    source_path = ctrl_name = nil
    @mutex.synchronize do
      workflow = @state[:workflows][name]
      workflow[:status] = "analyzing"
      workflow[:started_at] = Time.now.iso8601
      workflow[:error] = nil
      source_path = workflow[:full_path]
      ctrl_name = workflow[:name]
    end

    begin
      source = File.read(source_path)
      prompt = Prompts.analyze(ctrl_name, source)

      result = claude_call(prompt)
      raise "Pipeline cancelled" if cancelled?
      parsed = parse_json_response(result)

      ensure_harden_dir(source_path)
      write_sidecar(source_path, "analysis.json", JSON.pretty_generate(parsed))

      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:analysis] = parsed
        wf[:status] = "awaiting_decisions"
        @prompt_store[name] ||= {}
        @prompt_store[name][:analyze] = prompt
      end
    rescue => e
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:error] = sanitize_error(e.message)
        wf[:status] = "error"
        add_error("Analysis failed for #{name}: #{e.message}")
      end
    end
  end

  # ── Phase 2: Accept Decision ───────────────────────────────

  def submit_decision(name, decision)
    @mutex.synchronize do
      workflow = @state[:workflows][name]
      raise "No workflow for #{name}" unless workflow
      workflow[:decision] = decision
    end
    run_hardening(name)
  end

  # ── Phase 3: Hardening ────────────────────────────────────

  def run_hardening(name)
    source_path = ctrl_name = analysis_json = decision = nil
    @mutex.synchronize do
      workflow = @state[:workflows][name]

      if workflow[:decision] && workflow[:decision]["action"] == "skip"
        workflow[:status] = "skipped"
        workflow[:completed_at] = Time.now.iso8601
        return
      end

      workflow[:status] = "hardening"
      source_path = workflow[:full_path]
      ctrl_name = workflow[:name]
      analysis_json = workflow[:analysis].to_json
      decision = workflow[:decision]
    end

    begin
      source = File.read(source_path)

      prompt = Prompts.harden(ctrl_name, source, analysis_json, decision)
      result = claude_call(prompt)
      raise "Pipeline cancelled" if cancelled?
      parsed = parse_json_response(result)

      write_sidecar(source_path, "hardened.json", JSON.pretty_generate(parsed))

      write_path = hardened_source_content = nil
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:original_source] = source
        wf[:hardened] = parsed
        wf[:status] = "hardened"
        write_path = wf[:full_path]
        hardened_source_content = parsed["hardened_source"]
        @prompt_store[name] ||= {}
        @prompt_store[name][:harden] = prompt
      end

      safe_write(write_path, hardened_source_content) if hardened_source_content
    rescue => e
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:error] = sanitize_error(e.message)
        wf[:status] = "error"
        add_error("Hardening failed for #{name}: #{e.message}")
      end
      return
    end

    run_testing(name)
  end

  # ── Phase 3.5: Testing ─────────────────────────────────────

  MAX_FIX_ATTEMPTS = 2
  MAX_CI_FIX_ATTEMPTS = 2

  def run_testing(name)
    source_path = ctrl_name = nil
    @mutex.synchronize do
      workflow = @state[:workflows][name]
      return unless workflow[:status] == "hardened"
      workflow[:status] = "testing"
      source_path = workflow[:full_path]
      ctrl_name = workflow[:name]
    end

    test_file = derive_test_path(source_path)
    test_cmd = if test_file && File.exist?(test_file)
      ["bin/rails", "test", test_file]
    else
      ["bin/rails", "test"]
    end

    attempts = []
    passed = false

    begin
      output, passed_run = spawn_with_timeout(*test_cmd, timeout: COMMAND_TIMEOUT, chdir: @rails_root)
      raise "Pipeline cancelled" if cancelled?
      attempts << { attempt: 1, command: test_cmd.join(" "), passed: passed_run, output: output }

      if passed_run
        passed = true
      else
        # Attempt Claude-assisted fixes
        MAX_FIX_ATTEMPTS.times do |i|
          analysis_json = nil
          @mutex.synchronize do
            wf = @state[:workflows][name]
            wf[:status] = "fixing_tests"
            analysis_json = wf[:analysis].to_json
          end

          hardened_source = File.read(source_path)
          prompt = Prompts.fix_tests(ctrl_name, hardened_source, output, analysis_json)

          fix_result = claude_call(prompt)
          raise "Pipeline cancelled" if cancelled?
          parsed = parse_json_response(fix_result)

          @mutex.synchronize do
            @prompt_store[name] ||= {}
            @prompt_store[name][:fix_tests] = prompt
          end

          if parsed["hardened_source"]
            safe_write(source_path, parsed["hardened_source"])
          end

          # Re-run tests
          @mutex.synchronize do
            wf = @state[:workflows][name]
            wf[:status] = "testing"
          end

          output, passed_run = spawn_with_timeout(*test_cmd, timeout: COMMAND_TIMEOUT, chdir: @rails_root)
          raise "Pipeline cancelled" if cancelled?
          attempts << {
            attempt: i + 2,
            command: test_cmd.join(" "),
            passed: passed_run,
            output: output,
            fixes_applied: parsed["fixes_applied"],
            hardening_reverted: parsed["hardening_reverted"]
          }

          if passed_run
            passed = true
            break
          end
        end
      end

      # Write test results sidecar
      test_results = { controller: name, passed: passed, attempts: attempts }
      write_sidecar(source_path, "test_results.json", JSON.pretty_generate(test_results))

      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:test_results] = test_results
        if passed
          wf[:status] = "tested"
        else
          wf[:status] = "tests_failed"
          add_error("Tests still failing for #{name} after #{attempts.length} attempt(s)")
          return
        end
      end
    rescue => e
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:error] = sanitize_error(e.message)
        wf[:status] = "error"
        add_error("Testing failed for #{name}: #{e.message}")
      end
      return
    end

    run_ci_checks(name)
  end

  def retry_tests(name)
    @mutex.synchronize do
      workflow = @state[:workflows][name]
      raise "No workflow for #{name}" unless workflow
      raise "#{name} is not in tests_failed state" unless workflow[:status] == "tests_failed"
      workflow[:status] = "hardened"
      workflow[:error] = nil
    end
    run_testing(name)
  end

  # ── Phase 3.75: CI Checking ──────────────────────────────

  CI_CHECKS = [
    { name: "rubocop", cmd: ->(path) { ["bin/rubocop", path] } },
    { name: "brakeman", cmd: ->(_) { %w[bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error] } },
    { name: "bundler-audit", cmd: ->(_) { %w[bin/bundler-audit] } },
    { name: "importmap-audit", cmd: ->(_) { %w[bin/importmap audit] } }
  ].freeze

  def run_ci_checks(name)
    source_path = ctrl_name = controller_relative = nil
    @mutex.synchronize do
      workflow = @state[:workflows][name]
      return unless workflow[:status] == "tested"
      workflow[:status] = "ci_checking"
      source_path = workflow[:full_path]
      ctrl_name = workflow[:name]
      controller_relative = workflow[:path]
    end

    begin
      fix_attempts = []
      checks = run_all_ci_checks(controller_relative)
      raise "Pipeline cancelled" if cancelled?
      passed = checks.all? { |c| c[:passed] }

      unless passed
        MAX_CI_FIX_ATTEMPTS.times do |i|
          analysis_json = nil
          @mutex.synchronize do
            wf = @state[:workflows][name]
            wf[:status] = "fixing_ci"
            analysis_json = wf[:analysis].to_json
          end

          failed_output = checks.reject { |c| c[:passed] }.map { |c|
            "== #{c[:name]} (#{c[:command]}) ==\n#{c[:output]}"
          }.join("\n\n")

          hardened_source = File.read(source_path)
          prompt = Prompts.fix_ci(ctrl_name, hardened_source, failed_output, analysis_json)

          fix_result = claude_call(prompt)
          raise "Pipeline cancelled" if cancelled?
          parsed = parse_json_response(fix_result)

          @mutex.synchronize do
            @prompt_store[name] ||= {}
            @prompt_store[name][:fix_ci] = prompt
          end

          if parsed["hardened_source"]
            safe_write(source_path, parsed["hardened_source"])
          end

          fix_attempts << {
            attempt: i + 1,
            fixes_applied: parsed["fixes_applied"],
            unfixable_issues: parsed["unfixable_issues"]
          }

          @mutex.synchronize do
            wf = @state[:workflows][name]
            wf[:status] = "ci_checking"
          end

          checks = run_all_ci_checks(controller_relative)
          raise "Pipeline cancelled" if cancelled?
          passed = checks.all? { |c| c[:passed] }
          break if passed
        end
      end

      ci_results = {
        controller: name,
        passed: passed,
        checks: checks,
        fix_attempts: fix_attempts
      }
      write_sidecar(source_path, "ci_results.json", JSON.pretty_generate(ci_results))

      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:ci_results] = ci_results
        if passed
          wf[:status] = "ci_passed"
        else
          wf[:status] = "ci_failed"
          add_error("CI checks still failing for #{name} after #{fix_attempts.length} fix attempt(s)")
          return
        end
      end
    rescue => e
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:error] = sanitize_error(e.message)
        wf[:status] = "error"
        add_error("CI checking failed for #{name}: #{e.message}")
      end
      return
    end

    run_verification(name)
  end

  def retry_ci(name)
    @mutex.synchronize do
      workflow = @state[:workflows][name]
      raise "No workflow for #{name}" unless workflow
      raise "#{name} is not in ci_failed state" unless workflow[:status] == "ci_failed"
      workflow[:status] = "tested"
      workflow[:error] = nil
    end
    run_ci_checks(name)
  end

  # ── Phase 4: Verification ─────────────────────────────────

  def run_verification(name)
    source_path = ctrl_name = original_source = hardened_source = analysis_json = nil
    @mutex.synchronize do
      workflow = @state[:workflows][name]
      return unless workflow[:status] == "ci_passed"
      workflow[:status] = "verifying"
      source_path = workflow[:full_path]
      ctrl_name = workflow[:name]
      original_source = workflow[:original_source]
      hardened_source = workflow.dig(:hardened, "hardened_source") || ""
      analysis_json = workflow[:analysis].to_json
    end

    begin
      prompt = Prompts.verify(ctrl_name, original_source, hardened_source, analysis_json)
      result = claude_call(prompt)
      raise "Pipeline cancelled" if cancelled?
      parsed = parse_json_response(result)

      write_sidecar(source_path, "verification.json", JSON.pretty_generate(parsed))

      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:verification] = parsed
        wf[:status] = "complete"
        wf[:completed_at] = Time.now.iso8601
        @prompt_store[name] ||= {}
        @prompt_store[name][:verify] = prompt
      end
    rescue => e
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:error] = sanitize_error(e.message)
        wf[:status] = "error"
        add_error("Verification failed for #{name}: #{e.message}")
      end
    end
  end

  # ── Ad-hoc Queries ──────────────────────────────────────────

  def ask_question(name, question)
    query_id = "ask_#{SecureRandom.hex(8)}"
    @mutex.synchronize do
      workflow = @state[:workflows][name]
      return { error: "No workflow for #{name}" } unless workflow
      @queries << { id: query_id, controller: name, type: "ask", question: question,
                    finding_id: nil, status: "pending", result: nil, error: nil,
                    created_at: Time.now.iso8601 }
      prune_queries
    end

    safe_thread do
      begin
        source_path = ctrl_name = analysis_json = nil
        @mutex.synchronize do
          wf = @state[:workflows][name]
          source_path = wf[:full_path]
          ctrl_name = wf[:name]
          analysis_json = (wf[:analysis] || {}).to_json
        end

        source = File.read(source_path)
        prompt = Prompts.ask(ctrl_name, source, analysis_json, question)
        answer = claude_call(prompt)

        @mutex.synchronize do
          q = @queries.find { |entry| entry[:id] == query_id }
          q[:status] = "complete"
          q[:result] = answer
        end
      rescue => e
        @mutex.synchronize do
          q = @queries.find { |entry| entry[:id] == query_id }
          q[:status] = "error"
          q[:error] = e.message
        end
      end
    end

    { query_id: query_id }
  end

  def explain_finding(name, finding_id)
    query_id = "explain_#{SecureRandom.hex(8)}"
    @mutex.synchronize do
      workflow = @state[:workflows][name]
      return { error: "No workflow for #{name}" } unless workflow

      finding = workflow.dig(:analysis, "findings")&.find { |f| f["id"] == finding_id }
      return { error: "Finding not found" } unless finding

      @queries << { id: query_id, controller: name, type: "explain", question: nil,
                    finding_id: finding_id, status: "pending", result: nil, error: nil,
                    created_at: Time.now.iso8601 }
      prune_queries
    end

    safe_thread do
      begin
        source_path = ctrl_name = finding_json = nil
        @mutex.synchronize do
          wf = @state[:workflows][name]
          finding = wf.dig(:analysis, "findings")&.find { |f| f["id"] == finding_id }
          source_path = wf[:full_path]
          ctrl_name = wf[:name]
          finding_json = finding.to_json
        end

        source = File.read(source_path)
        prompt = Prompts.explain(ctrl_name, source, finding_json)
        explanation = claude_call(prompt)

        @mutex.synchronize do
          q = @queries.find { |entry| entry[:id] == query_id }
          q[:status] = "complete"
          q[:result] = explanation
        end
      rescue => e
        @mutex.synchronize do
          q = @queries.find { |entry| entry[:id] == query_id }
          q[:status] = "error"
          q[:error] = e.message
        end
      end
    end

    { query_id: query_id }
  end

  def retry_analysis(name)
    @mutex.synchronize do
      workflow = @state[:workflows][name]
      return { error: "No workflow for #{name}" } unless workflow
      return { error: "#{name} is not in error state" } unless workflow[:status] == "error"
      workflow[:error] = nil
    end

    safe_thread(workflow_name: name) { run_analysis(name) }

    { status: "retrying" }
  end

  def reset!
    shutdown(timeout: 5)
    # Force-kill any stragglers — shutdown already attempted join + kill,
    # but verify before clearing state.
    @mutex.synchronize do
      @threads.each { |t| t.kill if t.alive? }
      @threads.clear
      @cancelled = false
      @state[:phase] = "idle"
      @state[:controllers] = []
      @state[:workflows] = {}
      @state[:errors] = []
      @prompt_store.clear
      @queries.clear
      @claude_active = 0
    end
    # Second drain: catch threads that snuck in between shutdown and the
    # mutex block above (race window where safe_thread could still append).
    stragglers = @mutex.synchronize { @threads.dup }
    stragglers.each { |t| t.kill if t.alive? }
    stragglers.each { |t| t.join(2) }
  end

  # ── Helpers ─────────────────────────────────────────────────

  def to_json(*args)
    @mutex.synchronize do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @cached_json.nil? || (now - @last_serialized_at) > 0.1
        @cached_json = @state.merge(queries: @queries).to_json(*args)
        @last_serialized_at = now
      end
      @cached_json
    end
  end

  def get_prompt(controller_name, phase)
    @mutex.synchronize { @prompt_store.dig(controller_name, phase) }
  end

  def sanitize_error(msg)
    msg.gsub(@rails_root, "<project>")
       .gsub(File.realpath(@rails_root), "<project>")
  rescue StandardError
    msg
  end

  private

  def find_controller(name)
    entry = @mutex.synchronize { @state[:controllers].find { |c| c[:name] == name } }
    raise "Controller not found: #{name}" unless entry
    entry.dup
  end

  def build_workflow(entry)
    {
      name: entry[:name],
      path: entry[:path],
      full_path: entry[:full_path],
      status: "pending",
      analysis: nil,
      decision: nil,
      hardened: nil,
      test_results: nil,
      ci_results: nil,
      verification: nil,
      error: nil,
      started_at: nil,
      completed_at: nil,
      original_source: nil
    }
  end

  def claude_call(prompt)
    acquire_claude_slot
    begin
      output, success = spawn_with_timeout("claude", "-p", prompt, timeout: CLAUDE_TIMEOUT)
      raise "claude -p failed: #{output[0..500]}" unless success
      output.strip
    ensure
      release_claude_slot
    end
  end

  def acquire_claude_slot
    @claude_semaphore.synchronize do
      while @claude_active >= MAX_CLAUDE_CONCURRENCY
        @claude_slots.wait(@claude_semaphore, 5)
        raise "Pipeline cancelled" if cancelled?
      end
      @claude_active += 1
    end
  end

  def release_claude_slot
    @claude_semaphore.synchronize do
      @claude_active -= 1
      @claude_slots.signal
    end
  end

  def spawn_with_timeout(*cmd, timeout:, chdir: nil)
    rd, wr = IO.pipe
    opts = { [:out, :err] => wr }
    opts[:chdir] = chdir if chdir
    pid = Process.spawn(*cmd, **opts, pgroup: true)
    wr.close
    reaped = false

    output = +""
    reader = Thread.new { output << rd.read }

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = Process.wait2(pid, Process::WNOHANG)
      if result
        reaped = true
        _, status = result
        reader.join(5)
        return [output, status.success?]
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline || cancelled?
        Process.kill("-TERM", pid) rescue Errno::ESRCH
        sleep 0.5
        Process.kill("-KILL", pid) rescue Errno::ESRCH
        Process.wait2(pid) rescue nil
        reaped = true
        reason = cancelled? ? "Pipeline cancelled" : "Command timed out after #{timeout}s: #{cmd.join(' ')}"
        raise reason
      end
      sleep 0.1
    end
  ensure
    unless reaped
      Process.kill("-KILL", pid) rescue Errno::ESRCH
      Process.wait2(pid) rescue nil
    end
    wr&.close unless wr&.closed?
    rd&.close unless rd&.closed?
    reader&.join(2)
  end

  def parse_json_response(raw)
    cleaned = raw.gsub(/\A```json\s*/, "").gsub(/\s*```\z/, "").strip
    result = begin
      JSON.parse(cleaned)
    rescue JSON::ParserError
      start = raw.index("{")
      finish = raw.rindex("}")
      if start && finish && finish > start
        JSON.parse(raw[start..finish])
      else
        raise "Failed to parse JSON from claude response: #{raw[0..200]}"
      end
    end
    raise "Expected JSON object but got #{result.class}: #{raw[0..200]}" unless result.is_a?(Hash)
    result
  end

  def add_error(msg)
    @state[:errors] << { message: sanitize_error(msg), at: Time.now.iso8601 }
  end

  # Drop oldest completed queries when over the cap (caller holds @mutex)
  def prune_queries
    return if @queries.length <= MAX_QUERIES
    removable = @queries.select { |q| %w[complete error].include?(q[:status]) }
    remove_count = @queries.length - MAX_QUERIES
    removable.first(remove_count).each { |q| @queries.delete(q) }
    # If still over cap (too many pending), drop oldest pending
    @queries.shift while @queries.length > MAX_QUERIES
  end

  def safe_write(path, content)
    real = File.realpath(File.dirname(path))
    allowed = File.realpath(File.join(@rails_root, "app", "controllers"))
    raise "Path #{path} escapes controllers directory" unless real.start_with?(allowed)
    File.write(path, content)
  end

  def run_all_ci_checks(controller_relative)
    ci_threads = CI_CHECKS.map do |check|
      cmd = check[:cmd].call(controller_relative)
      t = Thread.new do
        output, passed = spawn_with_timeout(*cmd, timeout: COMMAND_TIMEOUT, chdir: @rails_root)
        { name: check[:name], command: cmd.join(" "), passed: passed, output: output }
      end
      @mutex.synchronize do
        @threads.reject! { |th| !th.alive? }
        @threads << t
      end
      t
    end
    results = ci_threads.map { |t| t.value rescue $! }
    first_error = results.find { |r| r.is_a?(Exception) }
    raise first_error if first_error
    results
  end

  def derive_test_path(controller_path)
    # app/controllers/blog/posts_controller.rb → test/controllers/blog/posts_controller_test.rb
    relative = controller_path.sub("#{@rails_root}/", "")
    test_relative = relative
      .sub(%r{\Aapp/controllers/}, "test/controllers/")
      .sub(/\.rb\z/, "_test.rb")
    path = File.join(@rails_root, test_relative)
    File.exist?(path) ? path : nil
  end

  def ensure_harden_dir(controller_path)
    dir = File.join(File.dirname(controller_path), ".harden", File.basename(controller_path, ".rb"))
    FileUtils.mkdir_p(dir)
  end

  def sidecar_path(controller_path, filename)
    File.join(File.dirname(controller_path), ".harden", File.basename(controller_path, ".rb"), filename)
  end

  def write_sidecar(controller_path, filename, content)
    path = sidecar_path(controller_path, filename)
    File.write(path, content.end_with?("\n") ? content : "#{content}\n")
  end
end
