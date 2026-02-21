module Prompts
  # Phase 1: Analyze a controller for hardening opportunities
  def self.analyze(controller_name, controller_source)
    <<~PROMPT
      You are a Rails security hardening specialist. Analyze this controller and identify all hardening opportunities.

      ## Controller: #{controller_name}

      ```ruby
      #{controller_source}
      ```

      ## Your Task

      Analyze this controller for:
      1. Missing or weak strong parameters
      2. Authorization gaps (actions missing auth checks)
      3. Input validation issues
      4. Missing rate limiting
      5. CSRF concerns
      6. Unsafe redirects
      7. Information leakage in error handling
      8. Missing or incorrect HTTP status codes
      9. N+1 queries or other performance issues with security implications
      10. Any other security or hardening concerns

      ## Output Format

      Respond with ONLY this JSON (no markdown fences, no preamble):

      {
        "controller": "#{controller_name}",
        "status": "analyzed",
        "findings": [
          {
            "id": "finding_001",
            "severity": "high|medium|low",
            "category": "authorization|validation|params|rate_limiting|csrf|redirect|info_leak|other",
            "scope": "controller (fix is localized to this file) | module (fix spans namespace — models, views, controllers) | app (requires app-wide changes, e.g. adding an auth system)",
            "action": "action_name or null if controller-wide",
            "summary": "Brief one-line description",
            "detail": "Detailed explanation of the issue",
            "suggested_fix": "What should be done"
          }
        ],
        "overall_risk": "high|medium|low",
        "notes": "Any general observations about this controller"
      }
    PROMPT
  end

  # Phase 3: Apply hardening based on analysis and human decisions
  def self.harden(controller_name, controller_source, analysis_json, decision, staging_dir:)
    <<~PROMPT
      You are a Rails security hardening specialist. Apply the approved hardening changes to this controller.

      ## Controller: #{controller_name}

      ```ruby
      #{controller_source}
      ```

      ## Analysis Findings
      ```json
      #{analysis_json}
      ```

      ## Human Decision
      #{decision_instructions(decision)}

      ## Your Task

      Apply the hardening changes. Write the modified files to the staging directory at:
        #{staging_dir}

      The staging directory mirrors the app directory structure. For example, to modify
      `app/controllers/blog/posts_controller.rb`, write to:
        #{staging_dir}/app/controllers/blog/posts_controller.rb

      Create any necessary subdirectories within the staging directory.

      ## Output Format

      Respond with ONLY this JSON (no markdown fences, no preamble):

      {
        "controller": "#{controller_name}",
        "status": "hardened",
        "summary": "Brief description of changes made",
        "files_modified": [
          { "path": "app/controllers/blog/posts_controller.rb", "action": "modified" }
        ],
        "changes_applied": [
          {
            "finding_id": "finding_001",
            "action_taken": "Description of what was changed",
            "lines_affected": "Brief description"
          }
        ],
        "warnings": ["Any caveats or things the human should review"]
      }
    PROMPT
  end

  # Phase 3.5: Fix failing tests after hardening
  def self.fix_tests(controller_name, hardened_source, test_output, analysis_json, staging_dir:)
    <<~PROMPT
      You are a Rails security hardening specialist. The hardened controller below causes test failures.
      Fix the controller so tests pass while preserving as many hardening changes as possible.

      ## Controller: #{controller_name}

      ### Hardened Source (current)
      ```ruby
      #{hardened_source}
      ```

      ### Test Output
      ```
      #{test_output}
      ```

      ### Original Analysis
      ```json
      #{analysis_json}
      ```

      ## Your Task

      1. Read the test failures carefully
      2. Identify which hardening changes broke the tests
      3. Fix the controller so tests pass
      4. Preserve as many security hardening changes as possible — only revert what is necessary to fix tests
      5. Write the modified files to the staging directory at:
           #{staging_dir}

      The staging directory mirrors the app directory structure. For example, to modify
      `app/controllers/blog/posts_controller.rb`, write to:
        #{staging_dir}/app/controllers/blog/posts_controller.rb

      Create any necessary subdirectories within the staging directory.

      ## Output Format

      Respond with ONLY this JSON (no markdown fences, no preamble):

      {
        "controller": "#{controller_name}",
        "status": "fixed",
        "files_modified": [
          { "path": "app/controllers/blog/posts_controller.rb", "action": "modified" }
        ],
        "fixes_applied": [
          {
            "description": "What was changed to fix the test failure",
            "hardening_preserved": true,
            "notes": "Any relevant context"
          }
        ],
        "hardening_reverted": ["List of hardening changes that had to be reverted, if any"]
      }
    PROMPT
  end

  # Phase 3.75: Fix CI failures after hardening
  def self.fix_ci(controller_name, hardened_source, ci_output, analysis_json, staging_dir:)
    <<~PROMPT
      You are a Rails security hardening specialist. The hardened controller below causes CI check failures.
      Fix the controller so CI checks pass while preserving as many hardening changes as possible.

      ## Controller: #{controller_name}

      ### Hardened Source (current)
      ```ruby
      #{hardened_source}
      ```

      ### CI Check Output
      ```
      #{ci_output}
      ```

      ### Original Analysis
      ```json
      #{analysis_json}
      ```

      ## Your Task

      1. Read the CI check failures carefully
      2. Fix RuboCop and Brakeman issues in the controller code
      3. Note that bundler-audit and importmap-audit failures are NOT fixable from controller code — list them as unfixable
      4. Preserve as many security hardening changes as possible — only revert what is necessary to fix CI
      5. Write the modified files to the staging directory at:
           #{staging_dir}

      The staging directory mirrors the app directory structure. For example, to modify
      `app/controllers/blog/posts_controller.rb`, write to:
        #{staging_dir}/app/controllers/blog/posts_controller.rb

      Create any necessary subdirectories within the staging directory.

      ## Output Format

      Respond with ONLY this JSON (no markdown fences, no preamble):

      {
        "controller": "#{controller_name}",
        "status": "fixed",
        "files_modified": [
          { "path": "app/controllers/blog/posts_controller.rb", "action": "modified" }
        ],
        "fixes_applied": [
          {
            "description": "What was changed to fix the CI failure",
            "check": "rubocop|brakeman",
            "hardening_preserved": true,
            "notes": "Any relevant context"
          }
        ],
        "unfixable_issues": [
          {
            "check": "bundler-audit|importmap-audit",
            "description": "Why this cannot be fixed from controller code"
          }
        ]
      }
    PROMPT
  end

  # Phase 4: Verify hardening was applied correctly
  def self.verify(controller_name, original_source, hardened_source, analysis_json)
    <<~PROMPT
      You are a Rails security auditor. Verify that hardening was applied correctly.

      ## Controller: #{controller_name}

      ### Original
      ```ruby
      #{original_source}
      ```

      ### Hardened
      ```ruby
      #{hardened_source}
      ```

      ### Original Analysis
      ```json
      #{analysis_json}
      ```

      ## Your Task

      1. Verify each finding from the analysis was addressed
      2. Check that no new issues were introduced
      3. Confirm the hardened code is syntactically valid
      4. Flag any concerns

      ## Output Format

      Respond with ONLY this JSON (no markdown fences, no preamble):

      {
        "controller": "#{controller_name}",
        "status": "verified",
        "findings_addressed": [
          { "finding_id": "finding_001", "addressed": true, "notes": "" }
        ],
        "new_issues": [],
        "syntax_valid": true,
        "recommendation": "accept|review|reject",
        "notes": ""
      }
    PROMPT
  end

  # Ad-hoc: Answer a question about a controller
  def self.ask(controller_name, controller_source, analysis_json, question)
    <<~PROMPT
      You are a Rails security specialist. Answer this question about a controller.

      ## Controller: #{controller_name}

      ```ruby
      #{controller_source}
      ```

      ## Analysis
      ```json
      #{analysis_json}
      ```

      ## Question
      #{question}

      Answer concisely and practically. Reference specific lines or methods when relevant.
    PROMPT
  end

  # Ad-hoc: Explain a specific finding
  def self.explain(controller_name, controller_source, finding_json)
    <<~PROMPT
      You are a Rails security specialist. Explain this finding in plain terms.

      ## Controller: #{controller_name}

      ```ruby
      #{controller_source}
      ```

      ## Finding
      ```json
      #{finding_json}
      ```

      Explain:
      1. What the risk is in practical terms (what could an attacker do?)
      2. How to fix it (show code)
      3. How serious it is relative to other common Rails issues

      Be concise. Aim for a developer who knows Rails but isn't a security specialist.
    PROMPT
  end

  # ── Enhance Mode Prompts ────────────────────────────────────────────────────

  # E0 — Analyze: understand the controller's intent and generate research topics
  def self.e_analyze(controller_name, source, views, routes, models, verification_report)
    <<~PROMPT
      You are a senior Rails engineer performing a deep analysis of a controller to identify improvement opportunities. Use --dangerously-skip-permissions to read any app code you need for context.

      ## Controller: #{controller_name}

      ### Controller Source
      ```ruby
      #{source}
      ```

      ### Views
      #{views.empty? ? "(none)" : views.map { |path, content| "**#{path}**\n```erb\n#{content}\n```" }.join("\n\n")}

      ### Routes (excerpt)
      ```
      #{routes}
      ```

      ### Related Models
      #{models.empty? ? "(none)" : models.map { |path, content| "**#{path}**\n```ruby\n#{content}\n```" }.join("\n\n")}

      ### Hardening Verification Report
      ```json
      #{verification_report}
      ```

      ## Your Task

      Analyze this controller's purpose, design patterns, and current implementation quality. Identify:
      1. The controller's primary responsibility and user-facing intent
      2. Architectural patterns in use (service objects, concerns, scopes, etc.)
      3. Areas that could benefit from improvement (performance, maintainability, UX, testability)
      4. Research topics that would yield actionable improvements — external patterns, library options, best practices

      ## Output Format

      Respond with ONLY this JSON (no markdown fences, no preamble):

      {
        "controller": "#{controller_name}",
        "intent": "One or two sentences describing the controller's primary responsibility",
        "architecture_notes": "Key architectural patterns and design choices observed",
        "improvement_areas": [
          {
            "area": "Brief label (e.g., performance, maintainability)",
            "description": "What could be improved and why"
          }
        ],
        "research_topics": [
          "A specific, actionable research question or topic prompt suitable for web search or Claude research (e.g., 'Rails caching patterns for N+1 prevention in index actions')"
        ]
      }
    PROMPT
  end

  # E1 — Research: used as the API call prompt for each research topic
  def self.research(topic_prompt)
    <<~PROMPT
      You are a senior Rails engineer researching a specific improvement topic for a Rails controller. Use web search to gather current, accurate information.

      ## Research Topic

      #{topic_prompt}

      ## Your Task

      Research this topic thoroughly. Focus on:
      1. Current best practices and recommended approaches
      2. Specific Rails idioms, gems, or patterns that apply
      3. Trade-offs and when each approach is most appropriate
      4. Concrete implementation examples where helpful

      Synthesize what you find into a clear, actionable summary. Aim for practical guidance that can directly inform controller improvements — not general introductions.
    PROMPT
  end

  # E2 — Extract: generate POSSIBLE items from analysis and research results
  def self.extract(analysis, research_results)
    <<~PROMPT
      You are a senior Rails engineer. From a controller analysis and research results, generate a list of POSSIBLE actionable improvement items.

      ## Analysis Document
      ```json
      #{analysis}
      ```

      ## Research Results
      #{research_results.map.with_index(1) { |r, i| "### Research Topic #{i}\n#{r}" }.join("\n\n")}

      ## Your Task

      Synthesize the analysis and research into a concrete list of POSSIBLE improvements. Each item must be:
      - Specific and actionable (not vague like "improve performance")
      - Directly applicable to this controller
      - Grounded in the research or analysis findings

      ## Output Format

      Respond with ONLY this JSON (no markdown fences, no preamble):

      {
        "possible_items": [
          {
            "id": "item_001",
            "title": "Brief title",
            "description": "Concrete description of the improvement and how to implement it",
            "source": "which research topic or analysis area informed this item",
            "files_likely_affected": ["app/controllers/...", "app/models/..."]
          }
        ]
      }
    PROMPT
  end

  # E3 — Synthesize: compare POSSIBLE items to current implementation, rate impact/effort
  def self.synthesize(analysis, possible_items, source)
    <<~PROMPT
      You are a senior Rails engineer. Compare a list of POSSIBLE improvement items against the current controller implementation and rate each for impact and effort.

      ## Analysis Document
      ```json
      #{analysis}
      ```

      ## POSSIBLE Items
      ```json
      #{possible_items}
      ```

      ## Current Controller Source
      ```ruby
      #{source}
      ```

      ## Your Task

      For each POSSIBLE item:
      1. Determine if it is already implemented or not applicable to this controller — if so, exclude it
      2. For remaining items, rate impact (high/medium/low) and effort (high/medium/low)
      3. Provide a brief rationale for each rating

      ## Output Format

      Respond with ONLY this JSON (no markdown fences, no preamble):

      {
        "ready_items": [
          {
            "id": "item_001",
            "title": "Brief title",
            "description": "Concrete description of the improvement",
            "impact": "high|medium|low",
            "effort": "high|medium|low",
            "rationale": "Why this impact and effort rating",
            "files_likely_affected": ["app/controllers/...", "app/models/..."]
          }
        ],
        "excluded_items": [
          {
            "id": "item_001",
            "title": "Brief title",
            "reason": "already_implemented|not_applicable"
          }
        ]
      }
    PROMPT
  end

  # E4 — Audit: annotate READY items with prior-decision context from past runs
  def self.audit(ready_items, deferred_items, rejected_items)
    <<~PROMPT
      You are a senior Rails engineer reviewing improvement items for a controller. Annotate the READY items with context from prior operator decisions.

      ## READY Items
      ```json
      #{ready_items}
      ```

      ## Previously Deferred Items (from prior enhance cycles)
      ```json
      #{deferred_items.empty? ? "[]" : deferred_items.to_json}
      ```

      ## Previously Rejected Items (from prior enhance cycles)
      ```json
      #{rejected_items.empty? ? "[]" : rejected_items.to_json}
      ```

      ## Your Task

      For each READY item, check if a similar item was previously deferred or rejected. If so, annotate the item with:
      - The prior decision (deferred or rejected)
      - The operator's notes from that decision (if any)
      - A suggested default for this cycle (DEFER if previously deferred, REJECT if previously rejected, TODO if new)

      Do NOT filter out items — all READY items must appear in the output. The operator makes the final call.

      ## Output Format

      Respond with ONLY this JSON (no markdown fences, no preamble):

      {
        "annotated_items": [
          {
            "id": "item_001",
            "title": "Brief title",
            "description": "Concrete description of the improvement",
            "impact": "high|medium|low",
            "effort": "high|medium|low",
            "rationale": "Impact/effort rationale",
            "files_likely_affected": ["app/controllers/...", "app/models/..."],
            "prior_decision": "deferred|rejected|null",
            "prior_notes": "Operator's notes from prior decision, or null",
            "suggested_default": "TODO|DEFER|REJECT"
          }
        ]
      }
    PROMPT
  end

  # E6 — Batch plan: propose execution batches from approved TODO items
  def self.batch_plan(todo_items, analysis, source, operator_notes: nil)
    <<~PROMPT
      You are a senior Rails engineer designing an implementation plan. Group approved improvement items into batches for sequential execution.

      ## Approved TODO Items
      ```json
      #{todo_items}
      ```

      ## Analysis Document
      ```json
      #{analysis}
      ```

      ## Controller Source
      ```ruby
      #{source}
      ```

      #{operator_notes ? "## Operator Notes\n#{operator_notes}\n" : ""}
      ## Your Task

      Group the TODO items into ordered batches. Consider:
      - **Effort**: High-effort items should get their own batch
      - **File overlap**: Items touching the same files should batch together
      - **Dependencies**: Dependent items should be in the same batch or ordered correctly
      - **Risk**: Higher-risk changes first (easier to validate incrementally)

      For each batch, declare the specific files that will be modified (`write_targets`). Be specific — list individual files, not directories.

      ## Output Format

      Respond with ONLY this JSON (no markdown fences, no preamble):

      {
        "batches": [
          {
            "id": "batch_001",
            "title": "Brief description of this batch",
            "items": ["item_001", "item_002"],
            "write_targets": [
              "app/controllers/blog/posts_controller.rb",
              "test/controllers/blog/posts_controller_test.rb"
            ],
            "estimated_effort": "high|medium|low",
            "rationale": "Why these items are grouped together"
          }
        ]
      }
    PROMPT
  end

  # E7 — Apply: apply a batch of improvements (staging write pattern)
  def self.e_apply(batch_items, analysis, source, staging_dir)
    <<~PROMPT
      You are a senior Rails engineer. Apply a batch of approved improvement items to a Rails controller. Use --dangerously-skip-permissions to read any app code you need for context.

      ## Batch Items to Implement
      ```json
      #{batch_items}
      ```

      ## Analysis Document
      ```json
      #{analysis}
      ```

      ## Current Source (at least the controller; read other relevant files as needed)
      ```ruby
      #{source}
      ```

      ## Your Task

      Implement all items in this batch. Write the modified files to the staging directory at:
        #{staging_dir}

      The staging directory mirrors the app directory structure. For example, to modify
      `app/controllers/blog/posts_controller.rb`, write to:
        #{staging_dir}/app/controllers/blog/posts_controller.rb

      Create any necessary subdirectories within the staging directory.

      Rules:
      - Only modify the files declared in the batch's `write_targets`
      - Read any other files you need for context but do NOT write them
      - Make all changes from the batch items — do not skip items
      - Maintain existing code style and conventions

      ## Output Format

      Respond with ONLY this JSON (no markdown fences, no preamble). Do NOT include file contents in the response — only metadata.

      {
        "batch_id": "batch_001",
        "status": "applied",
        "summary": "Brief description of changes made",
        "files_modified": [
          { "path": "app/controllers/blog/posts_controller.rb", "action": "modified" }
        ],
        "changes_applied": [
          {
            "item_id": "item_001",
            "action_taken": "Description of what was changed",
            "notes": "Any relevant context"
          }
        ],
        "warnings": ["Any caveats or things the operator should review"]
      }
    PROMPT
  end

  # E8 — Fix tests: fix failing tests after batch apply (staging write pattern)
  def self.e_fix_tests(controller_name, test_output, analysis, staging_dir)
    <<~PROMPT
      You are a senior Rails engineer. A batch of improvements applied to #{controller_name} has caused test failures. Fix the code so tests pass while preserving as many improvements as possible. Use --dangerously-skip-permissions to read any app code you need for context.

      ### Test Output
      ```
      #{test_output}
      ```

      ### Analysis Document
      ```json
      #{analysis}
      ```

      ## Your Task

      1. Read the test failures carefully
      2. Read the current state of modified files in the staging directory or app directory
      3. Identify which changes broke the tests
      4. Fix the code so tests pass
      5. Preserve as many improvements as possible — only revert what is necessary
      6. Write the corrected files to the staging directory at:
           #{staging_dir}

      The staging directory mirrors the app directory structure.

      ## Output Format

      Respond with ONLY this JSON (no markdown fences, no preamble). Do NOT include file contents in the response — only metadata.

      {
        "controller": "#{controller_name}",
        "status": "fixed",
        "files_modified": [
          { "path": "app/controllers/blog/posts_controller.rb", "action": "modified" }
        ],
        "fixes_applied": [
          {
            "description": "What was changed to fix the test failure",
            "improvement_preserved": true,
            "notes": "Any relevant context"
          }
        ],
        "improvements_reverted": ["List of improvements that had to be reverted, if any"]
      }
    PROMPT
  end

  # E9 — Fix CI: fix CI failures after batch apply (staging write pattern)
  def self.e_fix_ci(controller_name, ci_output, analysis, staging_dir)
    <<~PROMPT
      You are a senior Rails engineer. A batch of improvements applied to #{controller_name} has caused CI check failures. Fix the code so CI checks pass while preserving as many improvements as possible. Use --dangerously-skip-permissions to read any app code you need for context.

      ### CI Check Output
      ```
      #{ci_output}
      ```

      ### Analysis Document
      ```json
      #{analysis}
      ```

      ## Your Task

      1. Read the CI check failures carefully
      2. Read the current state of modified files in the staging directory or app directory
      3. Fix RuboCop and Brakeman issues in the code
      4. Note that bundler-audit and importmap-audit failures are NOT fixable from controller code — list them as unfixable
      5. Preserve as many improvements as possible — only revert what is necessary
      6. Write the corrected files to the staging directory at:
           #{staging_dir}

      The staging directory mirrors the app directory structure.

      ## Output Format

      Respond with ONLY this JSON (no markdown fences, no preamble). Do NOT include file contents in the response — only metadata.

      {
        "controller": "#{controller_name}",
        "status": "fixed",
        "files_modified": [
          { "path": "app/controllers/blog/posts_controller.rb", "action": "modified" }
        ],
        "fixes_applied": [
          {
            "description": "What was changed to fix the CI failure",
            "check": "rubocop|brakeman",
            "improvement_preserved": true,
            "notes": "Any relevant context"
          }
        ],
        "unfixable_issues": [
          {
            "check": "bundler-audit|importmap-audit",
            "description": "Why this cannot be fixed from controller code"
          }
        ]
      }
    PROMPT
  end

  # E10 — Verify: verify that batch improvements were applied correctly
  def self.e_verify(controller_name, original_source, current_source, analysis, batch_items)
    <<~PROMPT
      You are a senior Rails engineer performing a verification review. Confirm that a batch of improvements was applied correctly to #{controller_name}. Use --dangerously-skip-permissions to read any related files for context.

      ## Original Source (before improvements)
      ```ruby
      #{original_source}
      ```

      ## Current Source (after improvements)
      ```ruby
      #{current_source}
      ```

      ## Analysis Document
      ```json
      #{analysis}
      ```

      ## Batch Items That Should Be Applied
      ```json
      #{batch_items}
      ```

      ## Your Task

      1. Verify each batch item was addressed in the current source
      2. Check that no new issues were introduced (bugs, style violations, regressions)
      3. Confirm the modified code is syntactically valid and follows existing conventions
      4. Flag any concerns

      ## Output Format

      Respond with ONLY this JSON (no markdown fences, no preamble):

      {
        "controller": "#{controller_name}",
        "status": "verified",
        "items_addressed": [
          { "item_id": "item_001", "addressed": true, "notes": "" }
        ],
        "new_issues": [],
        "syntax_valid": true,
        "recommendation": "accept|review|reject",
        "notes": ""
      }
    PROMPT
  end

  def self.decision_instructions(decision)
    case decision["action"]
    when "approve"
      "Apply ALL suggested fixes from the analysis."
    when "modify"
      "Apply the suggested fixes with these modifications:\n#{decision["notes"]}"
    when "selective"
      approved = decision["approved_findings"]&.join(", ")
      "Only address these specific findings: #{approved}. Leave everything else unchanged."
    else
      raise ArgumentError, "Unknown decision action: #{decision["action"].inspect}"
    end
  end

  private_class_method :decision_instructions
end
