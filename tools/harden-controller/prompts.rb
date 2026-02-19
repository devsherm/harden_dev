module Prompts
  # Phase 1: Analyze a controller for hardening opportunities
  def self.analyze(controller_name, controller_source, routes_info: nil)
    <<~PROMPT
      You are a Rails security hardening specialist. Analyze this controller and identify all hardening opportunities.

      ## Controller: #{controller_name}

      ```ruby
      #{controller_source}
      ```

      #{"## Routes\n```\n#{routes_info}\n```" if routes_info}

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
  def self.harden(controller_name, controller_source, analysis_json, decision)
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

      Apply the hardening changes. Write the complete hardened controller file.

      ## Output Format

      Respond with ONLY this JSON (no markdown fences, no preamble):

      {
        "controller": "#{controller_name}",
        "status": "hardened",
        "changes_applied": [
          {
            "finding_id": "finding_001",
            "action_taken": "Description of what was changed",
            "lines_affected": "Brief description"
          }
        ],
        "hardened_source": "THE COMPLETE HARDENED CONTROLLER SOURCE CODE",
        "warnings": ["Any caveats or things the human should review"]
      }
    PROMPT
  end

  # Phase 3.5: Fix failing tests after hardening
  def self.fix_tests(controller_name, hardened_source, test_output, analysis_json)
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

      ## Output Format

      Respond with ONLY this JSON (no markdown fences, no preamble):

      {
        "controller": "#{controller_name}",
        "status": "fixed",
        "hardened_source": "THE COMPLETE FIXED CONTROLLER SOURCE CODE",
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

  private

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
      "Apply all suggested fixes."
    end
  end
end
