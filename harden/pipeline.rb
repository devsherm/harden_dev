require "json"
require "fileutils"
require_relative "prompts"

class Pipeline
  PHASES = %w[idle discovering analyzing awaiting_decisions hardening verifying complete errored].freeze

  attr_reader :state

  def initialize(rails_root: ".")
    @rails_root = rails_root
    @mutex = Mutex.new
    @state = {
      phase: "idle",
      screens: {},
      errors: [],
      started_at: nil,
      completed_at: nil
    }
  end

  # ── Discovery ──────────────────────────────────────────────

  def discover_controllers
    update_phase("discovering")

    controllers_dir = File.join(@rails_root, "app", "controllers")
    unless Dir.exist?(controllers_dir)
      add_error("Controllers directory not found: #{controllers_dir}")
      update_phase("errored")
      return
    end

    Dir.glob(File.join(controllers_dir, "**", "*_controller.rb")).each do |path|
      # Skip ApplicationController and concerns
      basename = File.basename(path, ".rb")
      next if basename == "application_controller"

      relative = path.sub("#{@rails_root}/", "")
      @mutex.synchronize do
        @state[:screens][basename] = {
          name: basename,
          path: relative,
          full_path: path,
          status: "pending",
          analysis: nil,
          decision: nil,
          hardened: nil,
          verification: nil,
          error: nil
        }
      end
    end
  end

  # ── Phase 1: Parallel Analysis ─────────────────────────────

  def run_analysis
    update_phase("analyzing")
    @state[:started_at] = Time.now.iso8601

    threads = screens.map do |name, screen|
      Thread.new do
        begin
          update_screen(name, status: "analyzing")
          source = File.read(screen[:full_path])
          prompt = Prompts.analyze(name, source)

          result = claude_call(prompt)
          parsed = parse_json_response(result)

          ensure_harden_dir(screen[:full_path])
          write_sidecar(screen[:full_path], "analysis.json", result)

          update_screen(name, status: "analyzed", analysis: parsed)
        rescue => e
          update_screen(name, status: "error", error: e.message)
          add_error("Analysis failed for #{name}: #{e.message}")
        end
      end
    end

    threads.each(&:join)
    update_phase("awaiting_decisions")
  end

  # ── Phase 2: Accept Decisions ──────────────────────────────

  def submit_decisions(decisions)
    decisions.each do |name, decision|
      update_screen(name, decision: decision)
    end
    run_hardening
  end

  # ── Phase 3: Parallel Hardening ────────────────────────────

  def run_hardening
    update_phase("hardening")

    actionable = screens.select { |_, s| s[:decision] && s[:decision]["action"] != "skip" }

    threads = actionable.map do |name, screen|
      Thread.new do
        begin
          update_screen(name, status: "hardening")
          source = File.read(screen[:full_path])
          analysis_json = screen[:analysis].to_json

          prompt = Prompts.harden(name, source, analysis_json, screen[:decision])
          result = claude_call(prompt)
          parsed = parse_json_response(result)

          write_sidecar(screen[:full_path], "hardened.json", result)

          # Write the hardened source to a preview file (not the actual controller yet)
          if parsed["hardened_source"]
            write_sidecar(screen[:full_path], "hardened_preview.rb", parsed["hardened_source"])
          end

          update_screen(name, status: "hardened", hardened: parsed)
        rescue => e
          update_screen(name, status: "error", error: e.message)
          add_error("Hardening failed for #{name}: #{e.message}")
        end
      end
    end

    # Mark skipped screens
    screens.each do |name, screen|
      if screen[:decision] && screen[:decision]["action"] == "skip"
        update_screen(name, status: "skipped")
      end
    end

    threads.each(&:join)
    run_verification
  end

  # ── Phase 4: Parallel Verification ─────────────────────────

  def run_verification
    update_phase("verifying")

    hardened = screens.select { |_, s| s[:status] == "hardened" }

    threads = hardened.map do |name, screen|
      Thread.new do
        begin
          update_screen(name, status: "verifying")
          original_source = File.read(screen[:full_path])
          hardened_source = screen.dig(:hardened, "hardened_source") || ""
          analysis_json = screen[:analysis].to_json

          prompt = Prompts.verify(name, original_source, hardened_source, analysis_json)
          result = claude_call(prompt)
          parsed = parse_json_response(result)

          write_sidecar(screen[:full_path], "verification.json", result)

          update_screen(name, status: "verified", verification: parsed)
        rescue => e
          update_screen(name, status: "error", error: e.message)
          add_error("Verification failed for #{name}: #{e.message}")
        end
      end
    end

    threads.each(&:join)
    update_phase("complete")
    @state[:completed_at] = Time.now.iso8601
  end

  # ── Ad-hoc Queries ─────────────────────────────────────────

  def ask_about_screen(screen_name, question)
    screen = screens[screen_name]
    return { error: "Screen not found" } unless screen

    source = File.read(screen[:full_path])
    analysis_json = (screen[:analysis] || {}).to_json
    prompt = Prompts.ask(screen_name, source, analysis_json, question)

    claude_call(prompt)
  end

  def explain_finding(screen_name, finding_id)
    screen = screens[screen_name]
    return { error: "Screen not found" } unless screen

    finding = screen.dig(:analysis, "findings")&.find { |f| f["id"] == finding_id }
    return { error: "Finding not found" } unless finding

    source = File.read(screen[:full_path])
    prompt = Prompts.explain(screen_name, source, finding.to_json)

    claude_call(prompt)
  end

  def retry_screen(screen_name)
    screen = screens[screen_name]
    return { error: "Screen not found" } unless screen

    Thread.new do
      begin
        update_screen(screen_name, status: "analyzing", error: nil)
        source = File.read(screen[:full_path])
        prompt = Prompts.analyze(screen_name, source)

        result = claude_call(prompt)
        parsed = parse_json_response(result)

        write_sidecar(screen[:full_path], "analysis.json", result)
        update_screen(screen_name, status: "analyzed", analysis: parsed)
      rescue => e
        update_screen(screen_name, status: "error", error: e.message)
      end
    end

    { status: "retrying" }
  end

  # ── Helpers ────────────────────────────────────────────────

  def screens
    @state[:screens]
  end

  def to_json
    @mutex.synchronize { @state.to_json }
  end

  private

  def claude_call(prompt)
    # Escape the prompt for shell safety
    escaped = prompt.gsub("'", "'\\''")
    result = `claude -p '#{escaped}' 2>&1`

    unless $?.success?
      raise "claude -p failed (exit #{$?.exitstatus}): #{result[0..500]}"
    end

    result.strip
  end

  def parse_json_response(raw)
    # Claude might wrap JSON in markdown fences
    cleaned = raw.gsub(/\A```json\s*/, "").gsub(/\s*```\z/, "").strip
    JSON.parse(cleaned)
  rescue JSON::ParserError => e
    { "parse_error" => e.message, "raw_response" => raw[0..1000] }
  end

  def update_phase(phase)
    @mutex.synchronize { @state[:phase] = phase }
  end

  def update_screen(name, **attrs)
    @mutex.synchronize do
      @state[:screens][name] ||= {}
      attrs.each { |k, v| @state[:screens][name][k] = v }
    end
  end

  def add_error(msg)
    @mutex.synchronize { @state[:errors] << { message: msg, at: Time.now.iso8601 } }
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
