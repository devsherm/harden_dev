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
      screen: nil,
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
      analysis_file = sidecar_path(path, "analysis.json")
      has_existing = File.exist?(analysis_file)

      @state[:controllers] << {
        name: basename,
        path: relative,
        full_path: path,
        existing_analysis_at: has_existing ? File.mtime(analysis_file).iso8601 : nil
      }
    end

    @state[:phase] = "awaiting_selection"
  end

  # ── Selection ─────────────────────────────────────────────

  def select_controller(name)
    entry = @state[:controllers].find { |c| c[:name] == name }
    raise "Controller not found: #{name}" unless entry

    @state[:screen] = build_screen(entry)
    run_analysis
  end

  def load_existing_analysis(name)
    entry = @state[:controllers].find { |c| c[:name] == name }
    raise "Controller not found: #{name}" unless entry

    analysis_file = sidecar_path(entry[:full_path], "analysis.json")
    raise "No existing analysis for #{name}" unless File.exist?(analysis_file)

    @state[:screen] = build_screen(entry)

    raw = File.read(analysis_file)
    parsed = parse_json_response(raw)
    @state[:screen][:analysis] = parsed
    @state[:screen][:status] = "analyzed"
    @state[:phase] = "awaiting_decisions"
  end

  # ── Phase 1: Analysis ───────────────────────────────────────

  def run_analysis
    @state[:phase] = "analyzing"
    @state[:started_at] = Time.now.iso8601
    screen = @state[:screen]

    begin
      screen[:status] = "analyzing"
      source = File.read(screen[:full_path])
      prompt = Prompts.analyze(screen[:name], source)

      result = claude_call(prompt)
      parsed = parse_json_response(result)

      ensure_harden_dir(screen[:full_path])
      write_sidecar(screen[:full_path], "analysis.json", result)

      screen[:analysis] = parsed
      screen[:status] = "analyzed"
    rescue => e
      screen[:error] = e.message
      screen[:status] = "error"
      add_error("Analysis failed for #{screen[:name]}: #{e.message}")
    end

    @state[:phase] = "awaiting_decisions"
  end

  # ── Phase 2: Accept Decision ────────────────────────────────

  def submit_decision(decision)
    @state[:screen][:decision] = decision
    run_hardening
  end

  # ── Phase 3: Hardening ──────────────────────────────────────

  def run_hardening
    @state[:phase] = "hardening"
    screen = @state[:screen]

    if screen[:decision] && screen[:decision]["action"] == "skip"
      screen[:status] = "skipped"
      @state[:phase] = "complete"
      @state[:completed_at] = Time.now.iso8601
      return
    end

    begin
      screen[:status] = "hardening"
      source = File.read(screen[:full_path])
      analysis_json = screen[:analysis].to_json

      prompt = Prompts.harden(screen[:name], source, analysis_json, screen[:decision])
      result = claude_call(prompt)
      parsed = parse_json_response(result)

      write_sidecar(screen[:full_path], "hardened.json", result)

      if parsed["hardened_source"]
        write_sidecar(screen[:full_path], "hardened_preview.rb", parsed["hardened_source"])
      end

      screen[:hardened] = parsed
      screen[:status] = "hardened"
    rescue => e
      screen[:error] = e.message
      screen[:status] = "error"
      add_error("Hardening failed for #{screen[:name]}: #{e.message}")
    end

    run_verification
  end

  # ── Phase 4: Verification ───────────────────────────────────

  def run_verification
    @state[:phase] = "verifying"
    screen = @state[:screen]

    return unless screen[:status] == "hardened"

    begin
      screen[:status] = "verifying"
      original_source = File.read(screen[:full_path])
      hardened_source = screen.dig(:hardened, "hardened_source") || ""
      analysis_json = screen[:analysis].to_json

      prompt = Prompts.verify(screen[:name], original_source, hardened_source, analysis_json)
      result = claude_call(prompt)
      parsed = parse_json_response(result)

      write_sidecar(screen[:full_path], "verification.json", result)

      screen[:verification] = parsed
      screen[:status] = "verified"
    rescue => e
      screen[:error] = e.message
      screen[:status] = "error"
      add_error("Verification failed for #{screen[:name]}: #{e.message}")
    end

    @state[:phase] = "complete"
    @state[:completed_at] = Time.now.iso8601
  end

  # ── Ad-hoc Queries ─────────────────────────────────────────

  def ask_question(question)
    screen = @state[:screen]
    return { error: "No active screen" } unless screen

    source = File.read(screen[:full_path])
    analysis_json = (screen[:analysis] || {}).to_json
    prompt = Prompts.ask(screen[:name], source, analysis_json, question)

    claude_call(prompt)
  end

  def explain_finding(finding_id)
    screen = @state[:screen]
    return { error: "No active screen" } unless screen

    finding = screen.dig(:analysis, "findings")&.find { |f| f["id"] == finding_id }
    return { error: "Finding not found" } unless finding

    source = File.read(screen[:full_path])
    prompt = Prompts.explain(screen[:name], source, finding.to_json)

    claude_call(prompt)
  end

  def retry_analysis
    screen = @state[:screen]
    return { error: "No active screen" } unless screen

    Thread.new do
      begin
        screen[:error] = nil
        screen[:status] = "analyzing"
        source = File.read(screen[:full_path])
        prompt = Prompts.analyze(screen[:name], source)

        result = claude_call(prompt)
        parsed = parse_json_response(result)

        write_sidecar(screen[:full_path], "analysis.json", result)
        screen[:analysis] = parsed
        screen[:status] = "analyzed"
      rescue => e
        screen[:error] = e.message
        screen[:status] = "error"
      end
    end

    { status: "retrying" }
  end

  # ── Helpers ────────────────────────────────────────────────

  def screen
    @state[:screen]
  end

  def to_json
    @state.to_json
  end

  private

  def build_screen(entry)
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
  rescue JSON::ParserError => e
    { "parse_error" => e.message, "raw_response" => raw[0..1000] }
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
