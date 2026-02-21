# frozen_string_literal: true

class Pipeline
  module SharedPhases
    # ── Shared Verify Phase ──────────────────────────────────────
    #
    # Core implementation for the "verify changes" phase shared across
    # hardening mode and enhance mode. Thin wrappers (run_verification,
    # and future enhance verifier) delegate here with mode-specific
    # parameters.
    #
    # Parameters:
    #   name              - controller/workflow name
    #   guard_status      - status required to proceed (e.g. "h_ci_passed")
    #   verifying_status  - status to set while running (e.g. "h_verifying")
    #   verified_status   - status to set on success (e.g. "h_complete")
    #   verify_prompt_fn  - callable(ctrl_name, original_source, hardened_source, analysis_json) → prompt
    #   prompt_key        - symbol key under which to store the prompt (e.g. :h_verify)
    #
    def shared_verify(name, guard_status:, verifying_status:, verified_status:,
                      verify_prompt_fn:, prompt_key:, phase_label: "Verification")
      source_path = ctrl_name = original_source = analysis_json = nil
      @mutex.synchronize do
        workflow = @state[:workflows][name]
        return unless workflow[:status] == guard_status
        workflow[:status] = verifying_status
        source_path = workflow[:full_path]
        ctrl_name = workflow[:name]
        original_source = workflow[:original_source]
        analysis_json = workflow[:analysis].to_json
      end

      hardened_source = File.read(source_path)

      begin
        prompt = verify_prompt_fn.call(ctrl_name, original_source, hardened_source, analysis_json)
        result = claude_call(prompt)
        raise "Pipeline cancelled" if cancelled?
        parsed = parse_json_response(result)

        write_sidecar(source_path, "verification.json", JSON.pretty_generate(parsed))

        @mutex.synchronize do
          wf = @state[:workflows][name]
          wf[:verification] = parsed
          wf[:status] = verified_status
          wf[:completed_at] = Time.now.iso8601
          @prompt_store[name] ||= {}
          @prompt_store[name][prompt_key] = prompt
        end
      rescue => e
        @mutex.synchronize do
          wf = @state[:workflows][name]
          wf[:error] = sanitize_error(e.message)
          wf[:status] = "error"
          add_error("#{phase_label} failed for #{name}: #{e.message}")
        end
      end
    end

    # ── Shared Apply Phase ───────────────────────────────────────
    #
    # Core implementation for the "apply changes" phase shared across
    # hardening mode and enhance mode. Thin wrappers (run_hardening,
    # and future run_enhance_apply) delegate here with mode-specific
    # parameters.
    #
    # Parameters:
    #   name            - controller/workflow name
    #   apply_prompt_fn - callable(ctrl_name, source, analysis_json, decision, staging_dir:) → prompt string
    #   applied_status  - status to set on success (e.g. "h_hardened")
    #   applying_status - status to set while running (e.g. "h_hardening")
    #   skipped_status  - status to set when decision is "skip" (e.g. "h_skipped")
    #   sidecar_dir     - sidecar directory name (e.g. ".harden")
    #   staging_subdir  - subdirectory name under the sidecar dir for staging (default "staging")
    #   prompt_key      - symbol key under which to store the prompt (e.g. :h_harden)
    #   sidecar_file    - filename for the JSON sidecar written on success (e.g. "hardened.json")
    #   grant_id        - lock grant ID for enhance mode writes (nil = hardening mode)
    #
    # ── Shared Test Phase ─────────────────────────────────────
    #
    # Core implementation for the "run tests + fix" phase shared across
    # hardening mode and enhance mode.
    #
    # ── Shared CI Check Phase ────────────────────────────────
    #
    # Core implementation for the "run CI checks + fix" phase shared across
    # hardening mode and enhance mode. Thin wrappers (run_ci_checks, and future
    # enhance CI runner) delegate here with mode-specific parameters.
    #
    # Parameters:
    #   name                 - controller/workflow name
    #   guard_status         - status required to proceed (e.g. "h_tested")
    #   ci_checking_status   - status to set while running CI checks (e.g. "h_ci_checking")
    #   fixing_status        - status to set during Claude-assisted fix (e.g. "h_fixing_ci")
    #   ci_passed_status     - status to set when all checks pass (e.g. "h_ci_passed")
    #   ci_failed_status     - status to set when all attempts fail (e.g. "h_ci_failed")
    #   fix_prompt_fn        - callable(ctrl_name, source, failed_output, analysis_json, staging_dir:) → prompt
    #   prompt_key           - symbol key under which to store the fix prompt (e.g. :h_fix_ci)
    #   next_phase_fn        - callable(name) called after success (nil = do nothing)
    #
    def shared_ci_check(name, guard_status:, ci_checking_status:, fixing_status:,
                        ci_passed_status:, ci_failed_status:,
                        fix_prompt_fn:, prompt_key:, next_phase_fn: nil,
                        phase_label: "CI checking", grant_id: nil)
      source_path = ctrl_name = controller_relative = nil
      @mutex.synchronize do
        workflow = @state[:workflows][name]
        return unless workflow[:status] == guard_status
        workflow[:status] = ci_checking_status
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
              wf[:status] = fixing_status
              analysis_json = wf[:analysis].to_json
            end

            failed_output = checks.reject { |c| c[:passed] }.map { |c|
              "== #{c[:name]} (#{c[:command]}) ==\n#{c[:output]}"
            }.join("\n\n")

            hardened_source = File.read(source_path)

            stg = staging_path(source_path)
            FileUtils.rm_rf(stg)
            FileUtils.mkdir_p(stg)

            prompt = fix_prompt_fn.call(ctrl_name, hardened_source, failed_output, analysis_json, staging_dir: stg)

            fix_result = claude_call(prompt)
            raise "Pipeline cancelled" if cancelled?
            parsed = parse_json_response(fix_result)

            @mutex.synchronize do
              @prompt_store[name] ||= {}
              @prompt_store[name][prompt_key] = prompt
            end

            copy_from_staging(stg, grant_id: grant_id)

            fix_attempts << {
              attempt: i + 1,
              fixes_applied: parsed["fixes_applied"],
              unfixable_issues: parsed["unfixable_issues"]
            }

            @mutex.synchronize do
              wf = @state[:workflows][name]
              wf[:status] = ci_checking_status
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
            wf[:status] = ci_passed_status
          else
            wf[:status] = ci_failed_status
            add_error("#{phase_label}: checks still failing for #{name} after #{fix_attempts.length} fix attempt(s)")
            return
          end
        end
      rescue => e
        @mutex.synchronize do
          wf = @state[:workflows][name]
          wf[:error] = sanitize_error(e.message)
          wf[:status] = "error"
          add_error("#{phase_label} failed for #{name}: #{e.message}")
        end
        return
      end

      next_phase_fn&.call(name)
    end
    #
    # Core implementation for the "run tests + fix" phase shared across
    # hardening mode and enhance mode. Thin wrappers (run_testing, and future
    # enhance test runner) delegate here with mode-specific parameters.
    #
    # Parameters:
    #   name              - controller/workflow name
    #   guard_status      - status required to proceed (e.g. "h_hardened")
    #   testing_status    - status to set while running tests (e.g. "h_testing")
    #   fixing_status     - status to set during Claude-assisted fix (e.g. "h_fixing_tests")
    #   tested_status     - status to set when tests pass (e.g. "h_tested")
    #   tests_failed_status - status to set when all attempts fail (e.g. "h_tests_failed")
    #   fix_prompt_fn     - callable(ctrl_name, source, output, analysis_json, staging_dir:) → prompt
    #   prompt_key        - symbol key under which to store the fix prompt (e.g. :h_fix_tests)
    #   next_phase_fn     - callable(name) called after success (nil = do nothing)
    #
    def shared_test(name, guard_status:, testing_status:, fixing_status:,
                    tested_status:, tests_failed_status:,
                    fix_prompt_fn:, prompt_key:, next_phase_fn: nil,
                    phase_label: "Testing", grant_id: nil)
      source_path = ctrl_name = nil
      @mutex.synchronize do
        workflow = @state[:workflows][name]
        return unless workflow[:status] == guard_status
        workflow[:status] = testing_status
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
              wf[:status] = fixing_status
              analysis_json = wf[:analysis].to_json
            end

            hardened_source = File.read(source_path)

            stg = staging_path(source_path)
            FileUtils.rm_rf(stg)
            FileUtils.mkdir_p(stg)

            prompt = fix_prompt_fn.call(ctrl_name, hardened_source, output, analysis_json, staging_dir: stg)

            fix_result = claude_call(prompt)
            raise "Pipeline cancelled" if cancelled?
            parsed = parse_json_response(fix_result)

            @mutex.synchronize do
              @prompt_store[name] ||= {}
              @prompt_store[name][prompt_key] = prompt
            end

            copy_from_staging(stg, grant_id: grant_id)

            # Re-run tests
            @mutex.synchronize do
              wf = @state[:workflows][name]
              wf[:status] = testing_status
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
            wf[:status] = tested_status
          else
            wf[:status] = tests_failed_status
            add_error("#{phase_label}: tests still failing for #{name} after #{attempts.length} attempt(s)")
            return
          end
        end
      rescue => e
        @mutex.synchronize do
          wf = @state[:workflows][name]
          wf[:error] = sanitize_error(e.message)
          wf[:status] = "error"
          add_error("#{phase_label} failed for #{name}: #{e.message}")
        end
        return
      end

      next_phase_fn&.call(name)
    end

    # ── Shared Apply Phase ───────────────────────────────────────
    #
    # Core implementation for the "apply changes" phase shared across
    # hardening mode and enhance mode. Thin wrappers (run_hardening,
    # and future run_enhance_apply) delegate here with mode-specific
    # parameters.
    #
    # Parameters:
    #   name            - controller/workflow name
    #   apply_prompt_fn - callable(ctrl_name, source, analysis_json, decision, staging_dir:) → prompt string
    #   applied_status  - status to set on success (e.g. "h_hardened")
    #   applying_status - status to set while running (e.g. "h_hardening")
    #   skipped_status  - status to set when decision is "skip" (e.g. "h_skipped")
    #   sidecar_dir     - sidecar directory name (e.g. ".harden")
    #   staging_subdir  - subdirectory name under the sidecar dir for staging (default "staging")
    #   prompt_key      - symbol key under which to store the prompt (e.g. :h_harden)
    #   sidecar_file    - filename for the JSON sidecar written on success (e.g. "hardened.json")
    #   grant_id        - lock grant ID for enhance mode writes (nil = hardening mode)
    #
    def shared_apply(name, apply_prompt_fn:, applied_status:, applying_status:,
                     skipped_status:, sidecar_dir:, staging_subdir: "staging",
                     prompt_key: :h_harden, sidecar_file: "hardened.json",
                     grant_id: nil, phase_label: "Hardening")
      source_path = ctrl_name = analysis_json = decision = nil
      @mutex.synchronize do
        workflow = @state[:workflows][name]

        if workflow[:decision] && workflow[:decision]["action"] == "skip"
          workflow[:status] = skipped_status
          workflow[:completed_at] = Time.now.iso8601
          return
        end

        workflow[:status] = applying_status
        source_path = workflow[:full_path]
        ctrl_name = workflow[:name]
        analysis_json = workflow[:analysis].to_json
        decision = workflow[:decision]
      end

      begin
        source = File.read(source_path)

        # Compute sidecar directory for this controller using the given sidecar_dir param.
        controller_sidecar_dir = File.join(
          File.dirname(source_path), sidecar_dir, File.basename(source_path, ".rb")
        )
        FileUtils.mkdir_p(controller_sidecar_dir)

        stg = File.join(controller_sidecar_dir, staging_subdir)
        FileUtils.rm_rf(stg)
        FileUtils.mkdir_p(stg)

        prompt = apply_prompt_fn.call(ctrl_name, source, analysis_json, decision, staging_dir: stg)
        result = claude_call(prompt)
        raise "Pipeline cancelled" if cancelled?
        parsed = parse_json_response(result)

        sidecar_file_path = File.join(controller_sidecar_dir, sidecar_file)
        content = JSON.pretty_generate(parsed)
        File.write(sidecar_file_path, content.end_with?("\n") ? content : "#{content}\n")

        @mutex.synchronize do
          wf = @state[:workflows][name]
          wf[:original_source] = source
          wf[:hardened] = parsed
          wf[:status] = applied_status
          @prompt_store[name] ||= {}
          @prompt_store[name][prompt_key] = prompt
        end

        copy_from_staging(stg, grant_id: grant_id)
      rescue => e
        @mutex.synchronize do
          wf = @state[:workflows][name]
          wf[:error] = sanitize_error(e.message)
          wf[:status] = "error"
          add_error("#{phase_label} failed for #{name}: #{e.message}")
        end
      end
    end
  end
end
