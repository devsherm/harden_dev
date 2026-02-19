require "json"
require "fileutils"
require_relative "prompts"

class Pipeline
  ACTIVE_PHASES = %w[analyzing hardening testing fixing_tests verifying].freeze

  attr_reader :state

  def initialize(rails_root: ".")
    @rails_root = rails_root
    @mutex = Mutex.new
    @state = {
      phase: "idle",       # global: "idle" | "discovering" | "ready"
      controllers: [],     # discovery list (unchanged)
      workflows: {},       # keyed by controller name
      errors: []
    }
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
      verified_file = sidecar_path(path, "verification.json")

      has_analysis = File.exist?(analysis_file)
      has_hardened = File.exist?(hardened_file)
      has_tested = File.exist?(test_results_file)
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
        phases: { analyzed: has_analysis, hardened: has_hardened, tested: has_tested, verified: has_verified },
        existing_analysis_at: has_analysis ? File.mtime(analysis_file).iso8601 : nil,
        existing_hardened_at: has_hardened ? File.mtime(hardened_file).iso8601 : nil,
        existing_tested_at: has_tested ? File.mtime(test_results_file).iso8601 : nil,
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
      workflow[:status] = "analyzed"
      workflow[:phase] = "awaiting_decisions"
    end
  end

  # ── Phase 1: Analysis ──────────────────────────────────────

  def run_analysis(name)
    workflow = nil
    @mutex.synchronize do
      workflow = @state[:workflows][name]
      workflow[:phase] = "analyzing"
      workflow[:status] = "analyzing"
      workflow[:started_at] = Time.now.iso8601
      workflow[:error] = nil
    end

    begin
      source = File.read(workflow[:full_path])
      prompt = Prompts.analyze(workflow[:name], source)

      result = claude_call(prompt)
      parsed = parse_json_response(result)

      ensure_harden_dir(workflow[:full_path])
      write_sidecar(workflow[:full_path], "analysis.json", JSON.pretty_generate(parsed))

      @mutex.synchronize do
        workflow[:analysis] = parsed
        workflow[:status] = "analyzed"
        workflow[:phase] = "awaiting_decisions"
        workflow[:prompts][:analyze] = prompt
      end
    rescue => e
      @mutex.synchronize do
        workflow[:error] = e.message
        workflow[:status] = "error"
        workflow[:phase] = "errored"
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
    workflow = nil
    @mutex.synchronize do
      workflow = @state[:workflows][name]

      if workflow[:decision] && workflow[:decision]["action"] == "skip"
        workflow[:status] = "skipped"
        workflow[:phase] = "skipped"
        workflow[:completed_at] = Time.now.iso8601
        return
      end

      workflow[:phase] = "hardening"
      workflow[:status] = "hardening"
    end

    begin
      source = File.read(workflow[:full_path])
      analysis_json = workflow[:analysis].to_json

      prompt = Prompts.harden(workflow[:name], source, analysis_json, workflow[:decision])
      result = claude_call(prompt)
      parsed = parse_json_response(result)

      write_sidecar(workflow[:full_path], "hardened.json", JSON.pretty_generate(parsed))

      @mutex.synchronize do
        workflow[:original_source] = source
        if parsed["hardened_source"]
          File.write(workflow[:full_path], parsed["hardened_source"])
        end
        workflow[:hardened] = parsed
        workflow[:status] = "hardened"
        workflow[:prompts][:harden] = prompt
      end
    rescue => e
      @mutex.synchronize do
        workflow[:error] = e.message
        workflow[:status] = "error"
        workflow[:phase] = "errored"
        add_error("Hardening failed for #{name}: #{e.message}")
      end
      return
    end

    run_testing(name)
  end

  # ── Phase 3.5: Testing ─────────────────────────────────────

  MAX_FIX_ATTEMPTS = 2

  def run_testing(name)
    workflow = nil
    @mutex.synchronize do
      workflow = @state[:workflows][name]
      return unless workflow[:status] == "hardened"
      workflow[:phase] = "testing"
      workflow[:status] = "testing"
    end

    test_file = derive_test_path(workflow[:full_path])
    test_cmd = if test_file && File.exist?(test_file)
      "bin/rails test #{test_file}"
    else
      "bin/rails test"
    end

    attempts = []
    passed = false

    begin
      require "open3"
      output, status = Open3.capture2e(test_cmd, chdir: @rails_root)
      attempts << { attempt: 1, command: test_cmd, passed: status.success?, output: output }

      if status.success?
        passed = true
      else
        # Attempt Claude-assisted fixes
        MAX_FIX_ATTEMPTS.times do |i|
          @mutex.synchronize do
            workflow[:phase] = "fixing_tests"
            workflow[:status] = "fixing_tests"
          end

          hardened_source = File.read(workflow[:full_path])
          analysis_json = workflow[:analysis].to_json
          prompt = Prompts.fix_tests(workflow[:name], hardened_source, output, analysis_json)

          fix_result = claude_call(prompt)
          parsed = parse_json_response(fix_result)

          @mutex.synchronize do
            workflow[:prompts][:fix_tests] = prompt
          end

          if parsed["hardened_source"]
            File.write(workflow[:full_path], parsed["hardened_source"])
          end

          # Re-run tests
          @mutex.synchronize do
            workflow[:phase] = "testing"
            workflow[:status] = "testing"
          end

          output, status = Open3.capture2e(test_cmd, chdir: @rails_root)
          attempts << {
            attempt: i + 2,
            command: test_cmd,
            passed: status.success?,
            output: output,
            fixes_applied: parsed["fixes_applied"],
            hardening_reverted: parsed["hardening_reverted"]
          }

          if status.success?
            passed = true
            break
          end
        end
      end

      # Write test results sidecar
      test_results = { controller: name, passed: passed, attempts: attempts }
      write_sidecar(workflow[:full_path], "test_results.json", JSON.pretty_generate(test_results))

      @mutex.synchronize do
        workflow[:test_results] = test_results
        if passed
          workflow[:status] = "tested"
          workflow[:phase] = "tested"
        else
          workflow[:status] = "tests_failed"
          workflow[:phase] = "tests_failed"
          add_error("Tests still failing for #{name} after #{attempts.length} attempt(s)")
          return
        end
      end
    rescue => e
      @mutex.synchronize do
        workflow[:error] = e.message
        workflow[:status] = "error"
        workflow[:phase] = "errored"
        add_error("Testing failed for #{name}: #{e.message}")
      end
      return
    end

    run_verification(name)
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

  # ── Phase 4: Verification ─────────────────────────────────

  def run_verification(name)
    workflow = nil
    @mutex.synchronize do
      workflow = @state[:workflows][name]
      return unless workflow[:status] == "tested"
      workflow[:phase] = "verifying"
      workflow[:status] = "verifying"
    end

    begin
      original_source = workflow[:original_source]
      hardened_source = workflow.dig(:hardened, "hardened_source") || ""
      analysis_json = workflow[:analysis].to_json

      prompt = Prompts.verify(workflow[:name], original_source, hardened_source, analysis_json)
      result = claude_call(prompt)
      parsed = parse_json_response(result)

      write_sidecar(workflow[:full_path], "verification.json", JSON.pretty_generate(parsed))

      @mutex.synchronize do
        workflow[:verification] = parsed
        workflow[:status] = "verified"
        workflow[:phase] = "complete"
        workflow[:completed_at] = Time.now.iso8601
        workflow[:prompts][:verify] = prompt
      end
    rescue => e
      @mutex.synchronize do
        workflow[:error] = e.message
        workflow[:status] = "error"
        workflow[:phase] = "errored"
        add_error("Verification failed for #{name}: #{e.message}")
      end
    end
  end

  # ── Ad-hoc Queries ──────────────────────────────────────────

  def ask_question(name, question)
    workflow = @mutex.synchronize { @state[:workflows][name] }
    return { error: "No workflow for #{name}" } unless workflow

    source = File.read(workflow[:full_path])
    analysis_json = (workflow[:analysis] || {}).to_json
    prompt = Prompts.ask(workflow[:name], source, analysis_json, question)

    claude_call(prompt)
  end

  def explain_finding(name, finding_id)
    workflow = @mutex.synchronize { @state[:workflows][name] }
    return { error: "No workflow for #{name}" } unless workflow

    finding = workflow.dig(:analysis, "findings")&.find { |f| f["id"] == finding_id }
    return { error: "Finding not found" } unless finding

    source = File.read(workflow[:full_path])
    prompt = Prompts.explain(workflow[:name], source, finding.to_json)

    claude_call(prompt)
  end

  def retry_analysis(name)
    workflow = @mutex.synchronize { @state[:workflows][name] }
    return { error: "No workflow for #{name}" } unless workflow

    Thread.new { run_analysis(name) }

    { status: "retrying" }
  end

  # ── Helpers ─────────────────────────────────────────────────

  def to_json
    @mutex.synchronize { @state.to_json }
  end

  private

  def find_controller(name)
    entry = @state[:controllers].find { |c| c[:name] == name }
    raise "Controller not found: #{name}" unless entry
    entry
  end

  def build_workflow(entry)
    {
      name: entry[:name],
      path: entry[:path],
      full_path: entry[:full_path],
      phase: "pending",
      status: "pending",
      analysis: nil,
      decision: nil,
      hardened: nil,
      test_results: nil,
      verification: nil,
      error: nil,
      started_at: nil,
      completed_at: nil,
      original_source: nil,
      prompts: { analyze: nil, harden: nil, fix_tests: nil, verify: nil }
    }
  end

  def claude_call(prompt)
    require "open3"
    result, status = Open3.capture2e("claude", "-p", prompt)

    unless status.success?
      raise "claude -p failed (exit #{status.exitstatus}): #{result[0..500]}"
    end

    result.strip
  end

  def parse_json_response(raw)
    cleaned = raw.gsub(/\A```json\s*/, "").gsub(/\s*```\z/, "").strip
    JSON.parse(cleaned)
  rescue JSON::ParserError
    start = raw.index("{")
    finish = raw.rindex("}")
    if start && finish && finish > start
      JSON.parse(raw[start..finish])
    else
      { "parse_error" => "No JSON object found in response", "raw_response" => raw[0..1000] }
    end
  end

  def add_error(msg)
    @state[:errors] << { message: msg, at: Time.now.iso8601 }
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
