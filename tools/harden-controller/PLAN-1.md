# Implementation Plan — Phase 1 (Foundation Refactoring)

> Generated from `tools/harden-controller/SPEC.proposed.md` (delta mode)
> Phase 1 of 3: Items 1-4 (status renames, compound guard, prompt prefixes, staging→copy)

## Recovery Instructions

- If tests fail after an item, fix the failing tests before moving to the next item.
- If an item cannot be completed as described, add a `BLOCKED:` note to the item and move to the next one.
- After completing each item, verify the codebase is in a clean, working state before proceeding.
- Run `cd tools/harden-controller && bundle exec rake test` to verify tests pass after each item.
- Old `.harden/` sidecar directories from pre-migration runs are incompatible after item 1. Delete them if present in any test Rails app.

## Items

- [ ] 1. **Rename all hardening statuses with `h_` prefix and add `mode` field**
  - **Implements**: Spec § Pipeline Phases (Hardening Mode), § State Model (`h_` prefix convention), § Design Decisions (universal status prefixes). MIGRATION.md § Step 1.
  - **Completion**: All 15 hardening workflow statuses are prefixed with `h_` (see rename map in MIGRATION.md § Step 1). `build_workflow` returns `mode: "hardening"` as a new field. `ACTIVE_STATUSES` contains the 7 renamed active statuses. All tests pass with `bundle exec rake test`.
  - **Scope boundary**: Does NOT rename prompt store keys or `VALID_PROMPT_PHASES` (item 3). Does NOT introduce staging→copy (item 4). Does NOT rename: (a) JSON response fixture values (`"analyzed"`, `"hardened"`, `"fixed"`, `"verified"`) — these are agent response statuses, not workflow statuses; (b) query subsystem statuses (`"pending"`, `"complete"`, `"error"` in `@queries`); (c) sidecar filenames (`hardened.json`, etc.); (d) HTTP response payload strings in server.rb route handlers (e.g., `{ status: "analyzing" }`). See MIGRATION.md § Gotchas for the full disambiguation.
  - **Files**: `pipeline.rb` (ACTIVE_STATUSES, build_workflow), `pipeline/orchestration.rb` (all phase methods), `server.rb` (try_transition guard:/to: strings), `index.html` (CSS classes, JS status comparisons, status labels object, header summary counts), `test/orchestration_test_helper.rb` (seed_workflow seeds), `test/pipeline_analysis_test.rb`, `test/pipeline_hardening_test.rb`, `test/pipeline_testing_test.rb`, `test/pipeline_ci_checks_test.rb`, `test/pipeline_verification_test.rb`, `test/try_transition_test.rb`
  - **Testing**: Update all status string assertions in existing test files. Use the complete inventory in MIGRATION.md § Appendix A to verify every occurrence. Run `bundle exec rake test` — all tests must pass. Pay special attention to: (1) `load_existing_analysis` in orchestration.rb (easy to overlook, see MIGRATION.md § Gotchas), (2) redundant status sets in `run_analysis` and `run_hardening` (set by both try_transition and the method itself), (3) `index.html` CSS selectors (`.workflow-dot.<status>` and `.status-<status>` patterns).

- [ ] 2. **Add compound guard to `try_transition`**
  - **Implements**: Spec § Validation Logic (State Machine Guards — compound guard). MIGRATION.md § Step 4.
  - **Completion**: `try_transition` handles Array guards — succeeds if the workflow's current status matches any string in the array, returns descriptive error otherwise. All tests pass.
  - **Scope boundary**: Does NOT add enhance mode guards — only the Array guard mechanism. Does NOT touch prompt store keys or any other file.
  - **Files**: `pipeline.rb` (try_transition — add `when Array` branch)
  - **Testing**: Add tests in `test/try_transition_test.rb` for compound guard: (1) success when status matches one of the array entries, (2) failure when status matches none, (3) failure when no workflow exists. Run `bundle exec rake test`.
  - **Implementation detail**: In `try_transition`, between the existing `when :not_active` and `else` branches, add:
    ```ruby
    when Array
      return [false, "No workflow for #{name}"] unless wf
      return [false, "#{name} is #{status}, expected one of #{guard.join(', ')}"] unless guard.map(&:to_s).include?(status)
      wf[:status] = to
      wf[:error] = nil
    ```

- [ ] 3. **Prefix prompt phase keys with `h_`**
  - **Implements**: Spec § Design Decisions (prompt store for debugging with prefixed keys). MIGRATION.md § Step 3.
  - **Completion**: `VALID_PROMPT_PHASES` in server.rb uses `h_`-prefixed keys. `@prompt_store` assignments in orchestration.rb use `h_`-prefixed symbols (`:h_analyze`, `:h_harden`, `:h_fix_tests`, `:h_fix_ci`, `:h_verify`). `to_json` enriches workflow entries with `h_`-prefixed prompt keys. Frontend prompt copy buttons use `h_`-prefixed phase names in fetch URLs. All tests pass.
  - **Scope boundary**: Does NOT change any route handler logic beyond updating `VALID_PROMPT_PHASES` values. Does NOT add enhance prompt phases.
  - **Files**: `pipeline/orchestration.rb` (all `@prompt_store[name][:<phase>]` assignments — 5 locations: `run_analysis` `:analyze`→`:h_analyze`, `run_hardening` `:harden`→`:h_harden`, `run_testing` `:fix_tests`→`:h_fix_tests`, `run_ci_checks` `:fix_ci`→`:h_fix_ci`, `run_verification` `:verify`→`:h_verify`), `server.rb` (VALID_PROMPT_PHASES constant — change `%w[analyze harden fix_tests fix_ci verify]` to `%w[h_analyze h_harden h_fix_tests h_fix_ci h_verify]`), `index.html` (prompt copy button fetch URLs and prompts key references), `test/pipeline_analysis_test.rb` (prompt key assertions), `test/pipeline_verification_test.rb` (prompt key assertions)
  - **Testing**: Update existing prompt key assertions in test files. Run `bundle exec rake test`.

- [ ] 4. **Implement staging→copy write pattern**
  - **Implements**: Spec § Staging Write Pattern, § Design Decisions (unified staging→copy, staging cleanup between fix attempts). MIGRATION.md § Step 2.
  - **Completion**: `claude -p` agents write to staging directories instead of returning `hardened_source` in JSON responses. `claude_call` includes `--dangerously-skip-permissions` flag. `staging_path` and `copy_from_staging` helpers exist in sidecar.rb. `run_hardening`, `run_testing` (fix loop), and `run_ci_checks` (fix loop) use the staging→copy pattern. Prompts instruct agents to write to staging directories. Source viewer removed from index.html. All tests pass.
  - **Scope boundary**: Does NOT add `grant_id` parameter to `safe_write` (item 6). Does NOT add enhance mode staging directories. Does NOT change `safe_write` validation logic beyond what exists. Does NOT add any new routes.
  - **Files**: `pipeline/sidecar.rb` (add `staging_path`, `copy_from_staging`), `pipeline/claude_client.rb` (add `--dangerously-skip-permissions` to spawn), `pipeline/orchestration.rb` (refactor `run_hardening`, `run_testing` fix loop, `run_ci_checks` fix loop to use staging→copy), `prompts.rb` (update `harden`, `fix_tests`, `fix_ci` to use staging_dir parameter — remove "return hardened_source" instruction, add "write files to staging directory" instruction), `index.html` (remove hardened_source viewer), `test/orchestration_test_helper.rb` (remove `hardened_source` from fixtures, add staging support), `test/pipeline_hardening_test.rb`, `test/pipeline_testing_test.rb`, `test/pipeline_ci_checks_test.rb`, `test/sidecar_test.rb` (new `copy_from_staging` tests)
  - **Testing**: (1) New unit test for `copy_from_staging` in sidecar_test.rb — create staging directory with files, verify copy to correct real paths, verify `safe_write` rejects paths outside `allowed_write_paths`. (2) Update orchestration test fixtures — remove `hardened_source` from `hardened_fixture`, `fix_tests_fixture`, `fix_ci_fixture`; return metadata-only hashes. (3) Stub `copy_from_staging` in orchestration tests to write expected content to controller path (same effect as current `safe_write` from `hardened_source`). (4) Verify `original_source` capture still happens before `copy_from_staging` call. (5) Verify staging cleanup between fix attempts (rm -rf + recreate). Run `bundle exec rake test`.
