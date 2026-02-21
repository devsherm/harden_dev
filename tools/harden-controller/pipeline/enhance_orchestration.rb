# frozen_string_literal: true

class Pipeline
  module EnhanceOrchestration
    # ── E0: Enhance Analysis ─────────────────────────────────
    #
    # Reads controller source + views + routes + related models + hardening
    # verification report, calls claude -p with Prompts.e_analyze, parses
    # response, writes analysis.json to .enhance/ sidecar, stores research
    # topic prompts in workflow.
    #
    # Entry guard: workflow must be h_complete or e_enhance_complete.
    # Status transitions: e_analyzing → e_awaiting_research.
    #
    def run_enhance_analysis(name)
      source_path = ctrl_name = verification_json = nil
      @mutex.synchronize do
        wf = @state[:workflows][name]
        wf[:status] = "e_analyzing"
        wf[:mode] = "enhance"
        wf[:error] = nil
        source_path = wf[:full_path]
        ctrl_name = wf[:name]

        # Load hardening verification report from workflow if present
        verification_json = wf[:verification].to_json
      end

      begin
        source = File.read(source_path)

        # Gather views associated with this controller
        views = gather_views(ctrl_name)

        # Gather routes excerpt
        routes = gather_routes

        # Gather related models
        models = gather_models(source)

        # Also try to load verification from sidecar if not in workflow
        if verification_json == "null"
          verified_sidecar = sidecar_path(source_path, "verification.json")
          verification_json = File.exist?(verified_sidecar) ? File.read(verified_sidecar).strip : "{}"
        end

        prompt = Prompts.e_analyze(ctrl_name, source, views, routes, models, verification_json)
        result = claude_call(prompt)
        raise "Pipeline cancelled" if cancelled?
        parsed = parse_json_response(result)

        # Write analysis.json to .enhance/ sidecar
        enhance_dir = enhance_sidecar_path(source_path, "analysis.json")
        FileUtils.mkdir_p(File.dirname(enhance_dir))
        content = JSON.pretty_generate(parsed)
        File.write(enhance_dir, content.end_with?("\n") ? content : "#{content}\n")

        # Build research topics array from parsed response
        raw_topics = parsed["research_topics"] || []
        research_topics = raw_topics.map { |t| { prompt: t, status: "pending", result: nil } }

        @mutex.synchronize do
          wf = @state[:workflows][name]
          wf[:e_analysis] = parsed
          wf[:research_topics] = research_topics
          wf[:status] = "e_awaiting_research"
          @prompt_store[name] ||= {}
          @prompt_store[name][:e_analyze] = prompt
        end
      rescue => e
        @mutex.synchronize do
          wf = @state[:workflows][name]
          wf[:last_active_status] = wf[:status]
          wf[:error] = sanitize_error(e.message)
          wf[:status] = "error"
          add_error("Enhance analysis failed for #{name}: #{e.message}")
        end
      end
    end

    private

    # Compute the path to a file within the .enhance/ sidecar directory.
    # Structure: <controller_dir>/.enhance/<controller_name>/<filename>
    def enhance_sidecar_path(target_path, filename)
      File.join(
        File.dirname(target_path),
        @enhance_sidecar_dir,
        File.basename(target_path, ".rb"),
        filename
      )
    end

    # Gather view files associated with a controller.
    # Returns a hash of { relative_path => content }.
    def gather_views(ctrl_name)
      # Derive view directory name from controller name
      # e.g. "posts_controller" → "posts", "blog/posts_controller" → "blog/posts"
      view_name = ctrl_name.sub(/_controller\z/, "")
      view_dir = File.join(@rails_root, "app", "views", view_name)
      views = {}
      if Dir.exist?(view_dir)
        Dir.glob(File.join(view_dir, "**", "*.{erb,html.erb,json.jbuilder,jbuilder}")).each do |path|
          relative = path.sub("#{@rails_root}/", "")
          views[relative] = File.read(path)
        rescue => _e
          # Skip unreadable files
        end
      end
      views
    end

    # Gather routes excerpt from the Rails app.
    # Returns a string with route output, or a placeholder if not available.
    def gather_routes
      routes_file = File.join(@rails_root, "config", "routes.rb")
      return "(routes unavailable)" unless File.exist?(routes_file)
      File.read(routes_file)
    rescue => _e
      "(routes unavailable)"
    end

    # Gather related model files referenced in the controller source.
    # Returns a hash of { relative_path => content }.
    def gather_models(controller_source)
      models = {}
      model_dir = File.join(@rails_root, "app", "models")
      return models unless Dir.exist?(model_dir)

      # Find model class references in the source
      # e.g., Blog::Post, User, Comment
      model_refs = controller_source.scan(/[A-Z][A-Za-z:]+/).uniq

      Dir.glob(File.join(model_dir, "**", "*.rb")).each do |path|
        basename = File.basename(path, ".rb")
        # Check if any model ref matches this file (case-insensitive snake_case match)
        if model_refs.any? { |ref|
             ref_parts = ref.split("::").map { |p| p.gsub(/([A-Z])/, '_\1').downcase.sub(/\A_/, "") }
             ref_parts.last == basename
           }
          relative = path.sub("#{@rails_root}/", "")
          models[relative] = File.read(path)
        end
      rescue => _e
        # Skip unreadable files
      end
      models
    end

    public

    # ── E1: Research ─────────────────────────────────────────
    #
    # Three methods for the research phase:
    #   submit_research      — manual paste: marks topic completed, checks completion
    #   submit_research_api  — API research: fires background thread, marks researching
    #   reject_research_topic — marks topic rejected, checks completion
    #
    # Completion check: when all non-rejected topics are completed, advances to
    # e_extracting and enqueues run_extraction_chain.
    #
    # research_status.json is written to the enhance sidecar on every topic
    # state change for resume capability.

    # Manual paste path: store result, mark topic completed, check completion.
    def submit_research(name, topic_index, result)
      source_path = nil
      @mutex.synchronize do
        wf = @state[:workflows][name]
        return unless wf
        topics = wf[:research_topics]
        return unless topics && topics[topic_index]
        topics[topic_index][:status] = "completed"
        topics[topic_index][:result] = result
        source_path = wf[:full_path]
      end

      write_research_md(source_path, name, topic_index, result)
      write_research_status(source_path, name)
      check_research_completion(name, source_path)
    end

    # Reject a research topic: mark rejected, check completion.
    def reject_research_topic(name, topic_index)
      source_path = nil
      @mutex.synchronize do
        wf = @state[:workflows][name]
        return unless wf
        topics = wf[:research_topics]
        return unless topics && topics[topic_index]
        topics[topic_index][:status] = "rejected"
        source_path = wf[:full_path]
      end

      write_research_status(source_path, name)
      check_research_completion(name, source_path)
    end

    # API research path: mark topic as researching, fire background thread.
    # On success: completed + store result + write MD + check completion.
    # On failure: revert to pending + log error (do NOT fail the whole workflow).
    def submit_research_api(name, topic_index)
      prompt = topic_prompt = source_path = nil
      @mutex.synchronize do
        wf = @state[:workflows][name]
        return unless wf
        topics = wf[:research_topics]
        return unless topics && topics[topic_index]
        topics[topic_index][:status] = "researching"
        topic_prompt = topics[topic_index][:prompt]
        source_path = wf[:full_path]
      end

      write_research_status(source_path, name)

      prompt = Prompts.research(topic_prompt)
      idx = topic_index
      src = source_path

      # Use raw Thread.new (not safe_thread) for per-topic recovery.
      # safe_thread would set the whole workflow to error on any exception.
      Thread.new do
        begin
          result = api_call(prompt)
          @mutex.synchronize do
            wf = @state[:workflows][name]
            if wf
              topics = wf[:research_topics]
              if topics && topics[idx] && topics[idx][:status] == "researching"
                topics[idx][:status] = "completed"
                topics[idx][:result] = result
              end
            end
          end
          write_research_md(src, name, idx, result)
          write_research_status(src, name)
          check_research_completion(name, src)
        rescue => e
          @mutex.synchronize do
            wf = @state[:workflows][name]
            if wf
              topics = wf[:research_topics]
              if topics && topics[idx] && topics[idx][:status] == "researching"
                topics[idx][:status] = "pending"
              end
              add_error("Research API failed for #{name} topic #{idx}: #{e.message}")
            end
          end
          write_research_status(src, name)
        end
      end

      nil
    end

    private

    # Derive a filesystem-safe slug from a topic prompt.
    def topic_slug(topic_prompt)
      topic_prompt.downcase.gsub(/[^a-z0-9]+/, "_").slice(0, 50)
    end

    # Write research result to .enhance/<ctrl>/research/<slug>.md
    def write_research_md(source_path, name, topic_index, result)
      topics = @mutex.synchronize do
        wf = @state[:workflows][name]
        wf ? wf[:research_topics].dup : []
      end
      topic = topics[topic_index]
      return unless topic

      slug = topic_slug(topic[:prompt])
      research_dir = enhance_sidecar_path(source_path, File.join("research", "#{slug}.md"))
      FileUtils.mkdir_p(File.dirname(research_dir))
      File.write(research_dir, result)
    rescue => e
      @mutex.synchronize { add_error("Failed to write research MD for #{name}: #{e.message}") }
    end

    # Write current topic statuses to .enhance/<ctrl>/research_status.json
    def write_research_status(source_path, name)
      topics = @mutex.synchronize do
        wf = @state[:workflows][name]
        wf ? wf[:research_topics].dup : []
      end
      status_path = enhance_sidecar_path(source_path, "research_status.json")
      FileUtils.mkdir_p(File.dirname(status_path))
      statuses = topics.map { |t| { prompt: t[:prompt], status: t[:status] } }
      content = JSON.pretty_generate(statuses)
      File.write(status_path, content.end_with?("\n") ? content : "#{content}\n")
    rescue => e
      @mutex.synchronize { add_error("Failed to write research_status.json for #{name}: #{e.message}") }
    end

    public

    # ── E2: Extract ───────────────────────────────────────────
    #
    # Reads analysis + research results from the workflow, calls claude -p
    # with Prompts.extract, produces a POSSIBLE items list, and writes
    # extract.json to the enhance sidecar.
    #
    # This is a pure work method — it does NOT set workflow status.
    # Status transitions (e_extracting → e_synthesizing → …) are managed
    # exclusively by run_extraction_chain (item 16).
    #
    def run_extraction(name)
      source_path = analysis = research_results = nil
      @mutex.synchronize do
        wf = @state[:workflows][name]
        return unless wf
        source_path = wf[:full_path]
        analysis = wf[:e_analysis] || {}
        topics = wf[:research_topics] || []
        research_results = topics
          .reject { |t| t[:status] == "rejected" }
          .select { |t| t[:result] }
          .map { |t| t[:result] }
      end

      analysis_json = JSON.generate(analysis)
      prompt = Prompts.extract(analysis_json, research_results)
      result = claude_call(prompt)
      raise "Pipeline cancelled" if cancelled?
      parsed = parse_json_response(result)

      # Write extract.json to .enhance/ sidecar
      extract_path = enhance_sidecar_path(source_path, "extract.json")
      FileUtils.mkdir_p(File.dirname(extract_path))
      content = JSON.pretty_generate(parsed)
      File.write(extract_path, content.end_with?("\n") ? content : "#{content}\n")

      parsed
    end

    # ── E3: Synthesize ────────────────────────────────────────
    #
    # Reads analysis + POSSIBLE items + controller source from the workflow,
    # calls claude -p with Prompts.synthesize, produces READY items with
    # impact/effort ratings, and writes synthesize.json to the enhance sidecar.
    #
    # This is a pure work method — it does NOT set workflow status.
    # Status transitions (e_extracting → e_synthesizing → …) are managed
    # exclusively by run_extraction_chain (item 16).
    #
    def run_synthesis(name)
      source_path = analysis = possible_items = source = nil
      @mutex.synchronize do
        wf = @state[:workflows][name]
        return unless wf
        source_path = wf[:full_path]
        analysis = wf[:e_analysis] || {}
        possible_items = wf[:e_possible_items] || {}
      end

      source = File.read(source_path)
      analysis_json = JSON.generate(analysis)
      possible_items_json = JSON.generate(possible_items)
      prompt = Prompts.synthesize(analysis_json, possible_items_json, source)
      result = claude_call(prompt)
      raise "Pipeline cancelled" if cancelled?
      parsed = parse_json_response(result)

      # Write synthesize.json to .enhance/ sidecar
      synthesize_path = enhance_sidecar_path(source_path, "synthesize.json")
      FileUtils.mkdir_p(File.dirname(synthesize_path))
      content = JSON.pretty_generate(parsed)
      File.write(synthesize_path, content.end_with?("\n") ? content : "#{content}\n")

      parsed
    end

    # ── E4: Audit ─────────────────────────────────────────────
    #
    # Reads READY items + per-controller deferred/rejected items from the
    # .enhance/<ctrl>/decisions/ directory, calls claude -p with Prompts.audit,
    # annotates items with prior-decision context (does NOT filter), and writes
    # audit.json to the enhance sidecar.
    #
    # This is a pure work method — it does NOT set workflow status.
    # Status transitions (e_auditing → e_awaiting_decisions) are managed
    # exclusively by run_extraction_chain.
    #
    def run_audit(name)
      source_path = ready_items = nil
      @mutex.synchronize do
        wf = @state[:workflows][name]
        return unless wf
        source_path = wf[:full_path]
        ready_items = wf[:e_ready_items] || {}
      end

      # Load per-controller deferred/rejected items from sidecar decisions/
      deferred_path  = enhance_sidecar_path(source_path, File.join("decisions", "deferred.json"))
      rejected_path  = enhance_sidecar_path(source_path, File.join("decisions", "rejected.json"))
      deferred_items = File.exist?(deferred_path) ? JSON.parse(File.read(deferred_path)) : []
      rejected_items = File.exist?(rejected_path) ? JSON.parse(File.read(rejected_path)) : []

      ready_items_json = JSON.generate(ready_items)
      prompt = Prompts.audit(ready_items_json, deferred_items, rejected_items)
      result = claude_call(prompt)
      raise "Pipeline cancelled" if cancelled?
      parsed = parse_json_response(result)

      # Write audit.json to .enhance/ sidecar
      audit_path = enhance_sidecar_path(source_path, "audit.json")
      FileUtils.mkdir_p(File.dirname(audit_path))
      content = JSON.pretty_generate(parsed)
      File.write(audit_path, content.end_with?("\n") ? content : "#{content}\n")

      parsed
    end

    private

    # E2→E4 chain entry point: calls run_extraction → run_synthesis → run_audit
    # sequentially, updating workflow status at each step.
    # Status transitions: e_extracting → e_synthesizing → e_auditing → e_awaiting_decisions
    def run_extraction_chain(name)
      # E2: Extract — status already set to e_extracting by caller
      extract_result = run_extraction(name)
      return unless extract_result

      @mutex.synchronize do
        wf = @state[:workflows][name]
        return unless wf
        wf[:e_possible_items] = extract_result
        wf[:status] = "e_synthesizing"
      end

      # E3: Synthesize
      synthesize_result = run_synthesis(name)
      return unless synthesize_result

      @mutex.synchronize do
        wf = @state[:workflows][name]
        return unless wf
        wf[:e_ready_items] = synthesize_result
        wf[:status] = "e_auditing"
      end

      # E4: Audit
      audit_result = run_audit(name)
      return unless audit_result

      @mutex.synchronize do
        wf = @state[:workflows][name]
        return unless wf
        wf[:e_audit] = audit_result
        wf[:status] = "e_awaiting_decisions"
      end
    end

    # Check if all non-rejected topics are completed.
    # If so, advance workflow to e_extracting and enqueue extraction chain.
    def check_research_completion(name, source_path)
      complete = @mutex.synchronize do
        wf = @state[:workflows][name]
        return unless wf
        topics = wf[:research_topics] || []
        non_rejected = topics.reject { |t| t[:status] == "rejected" }
        non_rejected.all? { |t| t[:status] == "completed" }
      end

      return unless complete

      @mutex.synchronize do
        wf = @state[:workflows][name]
        return unless wf
        wf[:status] = "e_extracting"
      end

      if @scheduler
        @scheduler.enqueue(WorkItem.new(
          workflow: name,
          phase: :e_extracting,
          callback: ->(_grant_id) { run_extraction_chain(name) }
        ))
      else
        safe_thread(workflow_name: name) { run_extraction_chain(name) }
      end
    end

    public

    # ── Retry entry point for E2→E4 extraction chain ──────────
    #
    # Sets workflow to e_extracting and re-runs the full E2→E3→E4 chain.
    # Used by the /enhance/retry route when the error occurred during
    # extraction, synthesis, or audit phases.
    #
    def retry_extraction_chain(name)
      @mutex.synchronize do
        wf = @state[:workflows][name]
        return unless wf
        wf[:status] = "e_extracting"
        wf[:error] = nil
      end
      run_extraction_chain(name)
    end

    # ── E5: Decide ────────────────────────────────────────────
    #
    # Receives per-item decisions (TODO/DEFER/REJECT), stores in workflow
    # e_decisions, writes decisions.json to sidecar. DEFER items are persisted
    # to .enhance/<ctrl>/decisions/deferred.json and REJECT items to
    # .enhance/<ctrl>/decisions/rejected.json for use by the audit phase (E4)
    # in future cycles. Advances workflow to e_planning_batches.
    #
    # Guard: workflow must be e_awaiting_decisions.
    #
    def submit_enhance_decisions(name, decisions)
      source_path = e_audit = nil
      @mutex.synchronize do
        wf = @state[:workflows][name]
        return [false, "No workflow for #{name}"] unless wf
        return [false, "#{name} is #{wf[:status]}, expected e_awaiting_decisions"] unless wf[:status] == "e_awaiting_decisions"

        wf[:e_decisions] = decisions
        source_path = wf[:full_path]
        e_audit = wf[:e_audit] || {}
      end

      now = Time.now.iso8601

      # Build per-decision lookup from the audit annotated_items
      annotated_items = e_audit["annotated_items"] || []
      items_by_id = annotated_items.each_with_object({}) { |item, h| h[item["id"]] = item }

      # Collect DEFER and REJECT items for persistence
      deferred_entries = []
      rejected_entries = []

      decisions.each do |item_id, decision_value|
        item = items_by_id[item_id] || {}
        entry = {
          "id" => item_id,
          "title" => item["title"],
          "description" => item["description"],
          "decision" => decision_value.to_s.upcase,
          "notes" => nil,
          "timestamp" => now
        }
        case decision_value.to_s.upcase
        when "DEFER"
          deferred_entries << entry
        when "REJECT"
          rejected_entries << entry
        end
      end

      # Write decisions.json to enhance sidecar
      decisions_json_path = enhance_sidecar_path(source_path, "decisions.json")
      FileUtils.mkdir_p(File.dirname(decisions_json_path))
      content = JSON.pretty_generate(decisions)
      File.write(decisions_json_path, content.end_with?("\n") ? content : "#{content}\n")

      # Persist DEFER items to decisions/deferred.json (merging with existing)
      persist_decisions_file(source_path, "deferred.json", deferred_entries)

      # Persist REJECT items to decisions/rejected.json (merging with existing)
      persist_decisions_file(source_path, "rejected.json", rejected_entries)

      # Advance workflow status
      @mutex.synchronize do
        wf = @state[:workflows][name]
        return [false, "Workflow disappeared for #{name}"] unless wf
        wf[:status] = "e_planning_batches"
      end

      [true, nil]
    end

    public

    # ── E6: Batch Plan ────────────────────────────────────────
    #
    # Reads approved TODO items + analysis + controller source, calls claude -p
    # with Prompts.batch_plan, produces ordered batch definitions with write_targets,
    # and writes batches.json to the enhance sidecar.
    #
    # Status transitions: e_planning_batches → e_awaiting_batch_approval (human gate).
    # Stores batches in workflow under :e_batches.
    #
    # Called either by the orchestration layer (after E5) or by replan_batches.
    #
    def run_batch_planning(name, operator_notes: nil)
      source_path = e_analysis = e_decisions = e_audit = nil
      @mutex.synchronize do
        wf = @state[:workflows][name]
        return unless wf
        source_path = wf[:full_path]
        e_analysis  = wf[:e_analysis] || {}
        e_decisions = wf[:e_decisions] || {}
        e_audit     = wf[:e_audit] || {}
      end

      source = File.read(source_path)

      # Build the list of approved TODO items from audit annotated_items + decisions
      annotated_items = e_audit["annotated_items"] || []
      todo_items = annotated_items.select do |item|
        e_decisions[item["id"]].to_s.upcase == "TODO"
      end

      analysis_json = JSON.generate(e_analysis)
      prompt = Prompts.batch_plan(todo_items, analysis_json, source, operator_notes: operator_notes)
      result = claude_call(prompt)
      raise "Pipeline cancelled" if cancelled?
      parsed = parse_json_response(result)

      # Write batches.json to .enhance/ sidecar
      batches_path = enhance_sidecar_path(source_path, "batches.json")
      FileUtils.mkdir_p(File.dirname(batches_path))
      content = JSON.pretty_generate(parsed)
      File.write(batches_path, content.end_with?("\n") ? content : "#{content}\n")

      @mutex.synchronize do
        wf = @state[:workflows][name]
        return unless wf
        wf[:e_batches] = parsed
        wf[:status] = "e_awaiting_batch_approval"
        @prompt_store[name] ||= {}
        @prompt_store[name][:batch_plan] = prompt
      end

      parsed
    end

    # Re-plan batches with optional operator notes.
    # Cycles e_awaiting_batch_approval → e_planning_batches → e_awaiting_batch_approval.
    # Re-planning is unbounded — the operator may invoke this as many times as needed.
    #
    def replan_batches(name, operator_notes: nil)
      @mutex.synchronize do
        wf = @state[:workflows][name]
        return [false, "No workflow for #{name}"] unless wf
        unless wf[:status] == "e_awaiting_batch_approval"
          return [false, "#{name} is #{wf[:status]}, expected e_awaiting_batch_approval"]
        end
        wf[:status] = "e_planning_batches"
        wf[:error]  = nil
      end

      begin
        run_batch_planning(name, operator_notes: operator_notes)
        [true, nil]
      rescue => e
        @mutex.synchronize do
          wf = @state[:workflows][name]
          if wf
            wf[:last_active_status] = wf[:status]
            wf[:error]  = sanitize_error(e.message)
            wf[:status] = "error"
            add_error("Batch re-planning failed for #{name}: #{e.message}")
          end
        end
        [false, sanitize_error(e.message)]
      end
    end

    # ── E7-E10: Batch Execution ───────────────────────────────
    #
    # Iterates through approved batches sequentially within a controller.
    # For each batch, runs the full E7→E10 chain via shared phases:
    #   E7: e_applying      (shared_apply)
    #   E8: e_testing       (shared_test, with e_fixing_tests fix loop)
    #   E9: e_ci_checking   (shared_ci_check, with e_fixing_ci fix loop)
    #   E10: e_verifying    (shared_verify)
    #
    # On completion of the last batch, advances to e_enhance_complete.
    # Fix loop exhaustion sets e_tests_failed or e_ci_failed.
    # The workflow tracks current_batch_id during execution.
    #
    # Entry: workflow must be e_awaiting_batch_approval (callers should use
    # try_transition before calling this method).
    #
    def run_batch_execution(name)
      source_path = e_batches = e_analysis = nil
      @mutex.synchronize do
        wf = @state[:workflows][name]
        return unless wf
        source_path  = wf[:full_path]
        e_batches    = wf[:e_batches] || {}
        e_analysis   = wf[:e_analysis] || {}
      end

      batches = e_batches["batches"] || []
      return if batches.empty?

      batches.each_with_index do |batch, idx|
        batch_id = batch["id"]
        batch_items = batch["items"] || []
        is_last = (idx == batches.size - 1)

        # Track current batch in workflow
        @mutex.synchronize do
          wf = @state[:workflows][name]
          return unless wf
          wf[:current_batch_id] = batch_id
        end

        # Compute batch-specific sidecar output directory
        batch_sidecar_dir = File.join(
          File.dirname(source_path),
          @enhance_sidecar_dir,
          File.basename(source_path, ".rb"),
          "batches",
          batch_id
        )
        FileUtils.mkdir_p(batch_sidecar_dir)

        # Capture batch items + analysis for prompt lambdas (closures)
        captured_batch_items = batch_items
        captured_analysis    = JSON.generate(e_analysis)

        # Resolve write_targets to absolute paths for lock acquisition
        write_targets = (batch["write_targets"] || []).map do |rel_path|
          File.join(@rails_root, rel_path)
        end

        # Acquire write locks for this batch's target files.
        # Released via ensure block on completion or error.
        grant = nil
        begin
          grant = @lock_manager.acquire(
            holder:      "enhance/#{name}/#{batch_id}",
            write_paths: write_targets,
            timeout:     30
          )

          # ── E7: Apply ───────────────────────────────────────────
          shared_apply(name,
            apply_prompt_fn: ->(_ctrl, src, _analysis_json, _decision, staging_dir:) {
              Prompts.e_apply(captured_batch_items, captured_analysis, src, staging_dir)
            },
            applying_status:   "e_applying",
            applied_status:    "e_batch_applied",
            skipped_status:    nil,
            sidecar_dir:       @enhance_sidecar_dir,
            staging_subdir:    "staging",
            prompt_key:        :"e_apply_#{batch_id}",
            sidecar_file:      "apply.json",
            phase_label:       "Enhance apply (#{batch_id})",
            analysis_key:      :e_analysis,
            sidecar_output_dir: batch_sidecar_dir,
            grant_id:          grant.id
          )
          @lock_manager.renew(grant.id)

          # Check if apply succeeded (guard for next phase)
          current_status = @mutex.synchronize { @state[:workflows][name]&.[](:status) }
          break unless current_status == "e_batch_applied"

          # ── E8: Test ────────────────────────────────────────────
          shared_test(name,
            guard_status:        "e_batch_applied",
            testing_status:      "e_testing",
            fixing_status:       "e_fixing_tests",
            tested_status:       "e_batch_tested",
            tests_failed_status: "e_tests_failed",
            fix_prompt_fn: ->(_ctrl, src, output, _analysis_json, staging_dir:) {
              Prompts.e_fix_tests(name, output, captured_analysis, staging_dir)
            },
            prompt_key:          :"e_fix_tests_#{batch_id}",
            phase_label:         "Enhance testing (#{batch_id})",
            sidecar_dir:         @enhance_sidecar_dir,
            staging_subdir:      "staging",
            analysis_key:        :e_analysis,
            sidecar_output_dir:  batch_sidecar_dir,
            grant_id:            grant.id
          )
          @lock_manager.renew(grant.id)

          current_status = @mutex.synchronize { @state[:workflows][name]&.[](:status) }
          break unless current_status == "e_batch_tested"

          # ── E9: CI Check ────────────────────────────────────────
          shared_ci_check(name,
            guard_status:       "e_batch_tested",
            ci_checking_status: "e_ci_checking",
            fixing_status:      "e_fixing_ci",
            ci_passed_status:   "e_batch_ci_passed",
            ci_failed_status:   "e_ci_failed",
            fix_prompt_fn: ->(_ctrl, src, failed_output, _analysis_json, staging_dir:) {
              Prompts.e_fix_ci(name, failed_output, captured_analysis, staging_dir)
            },
            prompt_key:         :"e_fix_ci_#{batch_id}",
            phase_label:        "Enhance CI (#{batch_id})",
            sidecar_dir:        @enhance_sidecar_dir,
            staging_subdir:     "staging",
            analysis_key:       :e_analysis,
            sidecar_output_dir: batch_sidecar_dir,
            grant_id:           grant.id
          )
          @lock_manager.renew(grant.id)

          current_status = @mutex.synchronize { @state[:workflows][name]&.[](:status) }
          break unless current_status == "e_batch_ci_passed"

          # ── E10: Verify ─────────────────────────────────────────
          shared_verify(name,
            guard_status:     "e_batch_ci_passed",
            verifying_status: "e_verifying",
            verified_status:  "e_batch_complete",
            verify_prompt_fn: ->(ctrl_name, original_source, current_source, _analysis_json) {
              Prompts.e_verify(ctrl_name, original_source, current_source, captured_analysis, captured_batch_items)
            },
            prompt_key:        :"e_verify_#{batch_id}",
            phase_label:       "Enhance verify (#{batch_id})",
            analysis_key:      :e_analysis,
            sidecar_output_dir: batch_sidecar_dir
          )
          @lock_manager.renew(grant.id)

          current_status = @mutex.synchronize { @state[:workflows][name]&.[](:status) }
          break unless current_status == "e_batch_complete"

          # If this was the last batch, advance to e_enhance_complete.
          # For non-last batches, the loop continues; the next shared_apply call
          # will set e_applying directly (shared_apply has no guard check on entry).
          next unless is_last

          @mutex.synchronize do
            wf = @state[:workflows][name]
            wf[:status] = "e_enhance_complete" if wf
          end
        ensure
          # Always release the grant on completion or error.
          # Idempotent — safe to call even if grant was never acquired.
          @lock_manager.release(grant.id) if grant
        end
      end
    end

    private

    # Read existing decisions file, merge new entries (replacing by id), write back.
    def persist_decisions_file(source_path, filename, new_entries)
      return if new_entries.empty?

      file_path = enhance_sidecar_path(source_path, File.join("decisions", filename))
      FileUtils.mkdir_p(File.dirname(file_path))

      # Load existing entries and merge (new entries replace old by id)
      existing = File.exist?(file_path) ? JSON.parse(File.read(file_path)) : []
      existing_by_id = existing.each_with_object({}) { |e, h| h[e["id"]] = e }
      new_entries.each { |e| existing_by_id[e["id"]] = e }
      merged = existing_by_id.values

      content = JSON.pretty_generate(merged)
      File.write(file_path, content.end_with?("\n") ? content : "#{content}\n")
    rescue => e
      @mutex.synchronize { add_error("Failed to write decisions/#{filename} for source: #{e.message}") }
    end

    public
  end
end
