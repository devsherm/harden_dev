# frozen_string_literal: true

class Pipeline
  module Orchestration
    # ── Discovery ──────────────────────────────────────────────

    def discover_controllers
      @mutex.synchronize { @state[:phase] = "discovering" }

      full_glob = File.join(@rails_root, @discovery_glob)
      # Derive the base directory from the glob (everything before the first wildcard)
      base_dir = @discovery_glob.split("*").first.chomp("/")
      base_dir_full = File.join(@rails_root, base_dir)
      unless Dir.exist?(base_dir_full)
        @mutex.synchronize do
          add_error("Discovery directory not found: #{base_dir_full}")
          @state[:phase] = "ready"
        end
        return
      end

      discovered = []

      Dir.glob(full_glob).each do |path|
        basename = File.basename(path, ".rb")
        next if @discovery_excludes.include?(basename)

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

    def load_existing_analysis(name)
      entry = find_controller(name)

      analysis_file = sidecar_path(entry[:full_path], "analysis.json")
      raise "No existing analysis for #{name}" unless File.exist?(analysis_file)

      raw = File.read(analysis_file)
      parsed = parse_json_response(raw)

      @mutex.synchronize do
        workflow = @state[:workflows][name] ||= build_workflow(entry)
        workflow[:analysis] = parsed
        workflow[:status] = "h_awaiting_decisions"
      end
    end

    # ── Phase 1: Analysis ──────────────────────────────────────

    def run_analysis(name)
      source_path = ctrl_name = nil
      @mutex.synchronize do
        workflow = @state[:workflows][name]
        workflow[:status] = "h_analyzing"
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

        ensure_sidecar_dir(source_path)
        write_sidecar(source_path, "analysis.json", JSON.pretty_generate(parsed))

        @mutex.synchronize do
          wf = @state[:workflows][name]
          wf[:analysis] = parsed
          wf[:status] = "h_awaiting_decisions"
          @prompt_store[name] ||= {}
          @prompt_store[name][:h_analyze] = prompt
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
      shared_apply(name,
                   apply_prompt_fn: method(:hardening_apply_prompt),
                   applied_status:  "h_hardened",
                   applying_status: "h_hardening",
                   skipped_status:  "h_skipped",
                   sidecar_dir:     @sidecar_dir,
                   prompt_key:      :h_harden,
                   sidecar_file:    "hardened.json")
      run_testing(name) if workflow_status(name) == "h_hardened"
    end

    private

    def hardening_apply_prompt(ctrl_name, source, analysis_json, decision, staging_dir:)
      Prompts.harden(ctrl_name, source, analysis_json, decision, staging_dir: staging_dir)
    end

    public

    # ── Phase 3.5: Testing ─────────────────────────────────────

    def run_testing(name)
      shared_test(name,
                  guard_status:        "h_hardened",
                  testing_status:      "h_testing",
                  fixing_status:       "h_fixing_tests",
                  tested_status:       "h_tested",
                  tests_failed_status: "h_tests_failed",
                  fix_prompt_fn:       method(:hardening_fix_tests_prompt),
                  prompt_key:          :h_fix_tests,
                  next_phase_fn:       method(:run_ci_checks))
    end

    private

    def hardening_fix_tests_prompt(ctrl_name, source, output, analysis_json, staging_dir:)
      Prompts.fix_tests(ctrl_name, source, output, analysis_json, staging_dir: staging_dir)
    end

    public

    # ── Phase 3.75: CI Checking ──────────────────────────────

    def run_ci_checks(name)
      shared_ci_check(name,
                      guard_status:       "h_tested",
                      ci_checking_status: "h_ci_checking",
                      fixing_status:      "h_fixing_ci",
                      ci_passed_status:   "h_ci_passed",
                      ci_failed_status:   "h_ci_failed",
                      fix_prompt_fn:      method(:hardening_fix_ci_prompt),
                      prompt_key:         :h_fix_ci,
                      next_phase_fn:      method(:run_verification))
    end

    private

    def hardening_fix_ci_prompt(ctrl_name, source, failed_output, analysis_json, staging_dir:)
      Prompts.fix_ci(ctrl_name, source, failed_output, analysis_json, staging_dir: staging_dir)
    end

    public

    # ── Phase 4: Verification ─────────────────────────────────

    def run_verification(name)
      shared_verify(name,
                    guard_status:     "h_ci_passed",
                    verifying_status: "h_verifying",
                    verified_status:  "h_complete",
                    verify_prompt_fn: method(:hardening_verify_prompt),
                    prompt_key:       :h_verify)
    end

    private

    def hardening_verify_prompt(ctrl_name, original_source, hardened_source, analysis_json)
      Prompts.verify(ctrl_name, original_source, hardened_source, analysis_json)
    end

    public

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

  end
end
