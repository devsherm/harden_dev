require "json"
require "fileutils"
require_relative "prompts"

class Pipeline
  PHASES = %w[idle discovering awaiting_selection analyzing awaiting_decisions hardening verifying complete errored].freeze

  attr_reader :state

  def initialize(rails_root: ".")
    @rails_root = rails_root
    @state = {
      phase: "idle",
      controllers: [],
      controller: nil,
      errors: [],
      started_at: nil,
      completed_at: nil
    }
  end

  # ── Discovery ──────────────────────────────────────────────

  def discover_controllers
    @state[:phase] = "discovering"

    controllers_dir = File.join(@rails_root, "app", "controllers")
    unless Dir.exist?(controllers_dir)
      add_error("Controllers directory not found: #{controllers_dir}")
      @state[:phase] = "errored"
      return
    end

    Dir.glob(File.join(controllers_dir, "**", "*_controller.rb")).each do |path|
      basename = File.basename(path, ".rb")
      next if basename == "application_controller"

      relative = path.sub("#{@rails_root}/", "")
      controller_mtime = File.mtime(path)

      analysis_file = sidecar_path(path, "analysis.json")
      hardened_file = sidecar_path(path, "hardened.json")
      verified_file = sidecar_path(path, "verification.json")

      has_analysis = File.exist?(analysis_file)
      has_hardened = File.exist?(hardened_file)
      has_verified = File.exist?(verified_file)

      # Parse analysis.json for risk level and finding counts
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

      @state[:controllers] << {
        name: basename,
        path: relative,
        full_path: path,
        phases: { analyzed: has_analysis, hardened: has_hardened, verified: has_verified },
        existing_analysis_at: has_analysis ? File.mtime(analysis_file).iso8601 : nil,
        existing_hardened_at: has_hardened ? File.mtime(hardened_file).iso8601 : nil,
        existing_verified_at: has_verified ? File.mtime(verified_file).iso8601 : nil,
        stale: has_analysis ? controller_mtime > File.mtime(analysis_file) : nil,
        overall_risk: overall_risk,
        finding_counts: finding_counts
      }
    end

    # Sort: needs-attention first, then by risk (high > medium > low > nil), then alphabetical
    risk_order = { "high" => 0, "medium" => 1, "low" => 2 }
    @state[:controllers].sort_by! do |c|
      needs_attention = (c[:stale] == true || c[:stale].nil?) ? 0 : 1
      risk = risk_order.fetch(c[:overall_risk], 3)
      [needs_attention, risk, c[:name]]
    end

    @state[:phase] = "awaiting_selection"
  end

  # ── Selection ─────────────────────────────────────────────

  def select_controller(name)
    entry = @state[:controllers].find { |c| c[:name] == name }
    raise "Controller not found: #{name}" unless entry

    @state[:controller] = build_controller(entry)
    run_analysis
  end

  def load_existing_analysis(name)
    entry = @state[:controllers].find { |c| c[:name] == name }
    raise "Controller not found: #{name}" unless entry

    analysis_file = sidecar_path(entry[:full_path], "analysis.json")
    raise "No existing analysis for #{name}" unless File.exist?(analysis_file)

    @state[:controller] = build_controller(entry)

    raw = File.read(analysis_file)
    parsed = parse_json_response(raw)
    @state[:controller][:analysis] = parsed
    @state[:controller][:status] = "analyzed"
    @state[:phase] = "awaiting_decisions"
  end

  # ── Phase 1: Analysis ───────────────────────────────────────

  def run_analysis
    @state[:phase] = "analyzing"
    @state[:started_at] = Time.now.iso8601
    controller = @state[:controller]

    begin
      controller[:status] = "analyzing"
      source = File.read(controller[:full_path])
      prompt = Prompts.analyze(controller[:name], source)

      result = claude_call(prompt)
      parsed = parse_json_response(result)

      ensure_harden_dir(controller[:full_path])
      write_sidecar(controller[:full_path], "analysis.json", result)

      controller[:analysis] = parsed
      controller[:status] = "analyzed"
    rescue => e
      controller[:error] = e.message
      controller[:status] = "error"
      add_error("Analysis failed for #{controller[:name]}: #{e.message}")
    end

    @state[:phase] = "awaiting_decisions"
  end

  # ── Phase 2: Accept Decision ────────────────────────────────

  def submit_decision(decision)
    @state[:controller][:decision] = decision
    run_hardening
  end

  # ── Phase 3: Hardening ──────────────────────────────────────

  def run_hardening
    @state[:phase] = "hardening"
    controller = @state[:controller]

    if controller[:decision] && controller[:decision]["action"] == "skip"
      controller[:status] = "skipped"
      @state[:phase] = "complete"
      @state[:completed_at] = Time.now.iso8601
      return
    end

    begin
      controller[:status] = "hardening"
      source = File.read(controller[:full_path])
      controller[:original_source] = source
      analysis_json = controller[:analysis].to_json

      prompt = Prompts.harden(controller[:name], source, analysis_json, controller[:decision])
      result = claude_call(prompt)
      parsed = parse_json_response(result)

      write_sidecar(controller[:full_path], "hardened.json", result)

      if parsed["hardened_source"]
        File.write(controller[:full_path], parsed["hardened_source"])
      end

      controller[:hardened] = parsed
      controller[:status] = "hardened"
    rescue => e
      controller[:error] = e.message
      controller[:status] = "error"
      add_error("Hardening failed for #{controller[:name]}: #{e.message}")
    end

    run_verification
  end

  # ── Phase 4: Verification ───────────────────────────────────

  def run_verification
    @state[:phase] = "verifying"
    controller = @state[:controller]

    return unless controller[:status] == "hardened"

    begin
      controller[:status] = "verifying"
      original_source = controller[:original_source]
      hardened_source = controller.dig(:hardened, "hardened_source") || ""
      analysis_json = controller[:analysis].to_json

      prompt = Prompts.verify(controller[:name], original_source, hardened_source, analysis_json)
      result = claude_call(prompt)
      parsed = parse_json_response(result)

      write_sidecar(controller[:full_path], "verification.json", result)

      controller[:verification] = parsed
      controller[:status] = "verified"
    rescue => e
      controller[:error] = e.message
      controller[:status] = "error"
      add_error("Verification failed for #{controller[:name]}: #{e.message}")
    end

    @state[:phase] = "complete"
    @state[:completed_at] = Time.now.iso8601
  end

  # ── Ad-hoc Queries ─────────────────────────────────────────

  def ask_question(question)
    controller = @state[:controller]
    return { error: "No active controller" } unless controller

    source = File.read(controller[:full_path])
    analysis_json = (controller[:analysis] || {}).to_json
    prompt = Prompts.ask(controller[:name], source, analysis_json, question)

    claude_call(prompt)
  end

  def explain_finding(finding_id)
    controller = @state[:controller]
    return { error: "No active controller" } unless controller

    finding = controller.dig(:analysis, "findings")&.find { |f| f["id"] == finding_id }
    return { error: "Finding not found" } unless finding

    source = File.read(controller[:full_path])
    prompt = Prompts.explain(controller[:name], source, finding.to_json)

    claude_call(prompt)
  end

  def retry_analysis
    controller = @state[:controller]
    return { error: "No active controller" } unless controller

    Thread.new do
      begin
        controller[:error] = nil
        controller[:status] = "analyzing"
        source = File.read(controller[:full_path])
        prompt = Prompts.analyze(controller[:name], source)

        result = claude_call(prompt)
        parsed = parse_json_response(result)

        write_sidecar(controller[:full_path], "analysis.json", result)
        controller[:analysis] = parsed
        controller[:status] = "analyzed"
      rescue => e
        controller[:error] = e.message
        controller[:status] = "error"
      end
    end

    { status: "retrying" }
  end

  # ── Helpers ────────────────────────────────────────────────

  def controller
    @state[:controller]
  end

  def to_json
    @state.to_json
  end

  private

  def build_controller(entry)
    {
      name: entry[:name],
      path: entry[:path],
      full_path: entry[:full_path],
      status: "pending",
      analysis: nil,
      decision: nil,
      hardened: nil,
      verification: nil,
      error: nil
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
    # Claude sometimes emits preamble text before the JSON object —
    # extract the outermost { ... } and retry.
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

  def ensure_harden_dir(controller_path)
    dir = File.join(File.dirname(controller_path), ".harden", File.basename(controller_path, ".rb"))
    FileUtils.mkdir_p(dir)
  end

  def sidecar_path(controller_path, filename)
    File.join(File.dirname(controller_path), ".harden", File.basename(controller_path, ".rb"), filename)
  end

  def write_sidecar(controller_path, filename, content)
    path = sidecar_path(controller_path, filename)
    File.write(path, content)
  end
end
