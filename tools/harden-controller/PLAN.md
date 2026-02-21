# Implementation Plan

> Generated from `tools/harden-controller/SPEC.proposed.md` (delta mode)

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

- [ ] 5. **Implement LockManager class**
  - **Implements**: Spec § LockManager (Enhance Mode) — all methods, LockGrant fields, conflict rules, acquisition semantics, grant lifecycle, TTL reaper.
  - **Completion**: `pipeline/lock_manager.rb` exists with `LockManager` class implementing: `try_acquire`, `acquire` (blocking with timeout), `release`, `renew`, `check_conflicts`, `active_grants`. Also defines `LockGrant`, `LockRequest`, `OverLockError`, `LockTimeoutError`, `LockViolationError`. Grant TTL (30 min default) with heartbeat renewal. Background reaper thread releases expired grants. All-or-nothing acquisition semantics. Directory path rejection (`OverLockError`). All LockManager tests pass.
  - **Scope boundary**: Does NOT integrate with Pipeline class (item 9). Does NOT modify `safe_write` (item 6). The LockManager is a standalone, independently testable class.
  - **Files**: `pipeline/lock_manager.rb` (new file), `test/lock_manager_test.rb` (new file)
  - **Testing**: Test per Spec § Test Organization — lock_manager_test.rb covers: try_acquire (success, conflict, directory rejection), acquire with timeout (success, LockTimeoutError), release (idempotent), conflict detection via check_conflicts, grant TTL reaper (expired grants released, renewed grants kept), heartbeat renewal. Test all-or-nothing semantics (partial conflict = no locks granted). Test OverLockError for directory paths.
  - **Implementation detail — LockGrant**: Use a Struct or plain class with fields: `id` (SecureRandom.uuid), `holder` (String), `write_paths` (Array<String>), `acquired_at` (Time), `expires_at` (Time, default 30 min from now), `released` (Boolean, default false). Store grants in a Hash keyed by id, guarded by a Mutex.
  - **Implementation detail — try_acquire**: (1) Reject any path where `File.directory?` returns true (raise `OverLockError`). (2) Check each requested path against all active (non-released, non-expired) grants. If any conflict, return nil. (3) If no conflicts, create a `LockGrant` with all paths, store it, return it.
  - **Implementation detail — acquire**: Loop calling `try_acquire` with a sleep interval (e.g. 0.5s), raising `LockTimeoutError` after timeout seconds.
  - **Implementation detail — reaper**: `Thread.new` that runs `loop { sleep 60; release_expired_grants }`. Check `expires_at < Time.now` for each active grant. Mark as released. Use `@reaper_thread` instance variable so tests can verify the reaper runs. Provide a `stop_reaper` method for clean test teardown.

- [ ] 6. **Add grant enforcement to `safe_write`**
  - **Implements**: Spec § Validation Logic (Grant Enforcement), § Design Decisions (path-validated writes, shared core orchestration).
  - **Completion**: `safe_write` accepts optional `grant_id:` keyword argument. When `grant_id` is nil (hardening mode), behavior is unchanged — uses `allowed_write_paths`. When `grant_id` is provided (enhance mode), four checks pass: (1) uses `enhance_allowed_write_paths` for allowlist, (2) path within selected allowlist, (3) valid non-expired non-released grant exists, (4) target path in grant's `write_paths`. Failures raise `LockViolationError`. All sidecar tests pass.
  - **Scope boundary**: Does NOT change `write_sidecar`. Does NOT integrate LockManager into Pipeline (item 9). Only modifies `safe_write` signature and validation logic.
  - **Files**: `pipeline/sidecar.rb` (update `safe_write`), `test/sidecar_test.rb` (new grant enforcement tests)
  - **Testing**: New tests in sidecar_test.rb: (1) grant_id nil — existing behavior unchanged, uses `allowed_write_paths`. (2) grant_id provided — uses `enhance_allowed_write_paths`, requires valid grant, requires path in grant's write_paths. (3) Invalid grant_id raises LockViolationError. (4) Expired grant raises LockViolationError. (5) Path not in grant's write_paths raises LockViolationError. (6) Path outside enhance_allowed_write_paths raises error. Run `bundle exec rake test`.
  - **Implementation detail**: `safe_write` needs access to `@lock_manager` and `@enhance_allowed_write_paths` instance variables. These don't exist yet on Pipeline (added in item 9). For now, the method should check `if grant_id` and if so, look up `@lock_manager` and `@enhance_allowed_write_paths` — both of which tests can set via `instance_variable_set`. The current `safe_write(path, content)` signature changes to `safe_write(path, content, grant_id: nil)`. All existing callers pass no `grant_id`, so they get the existing behavior.

- [ ] 7. **Implement Claude Messages API client**
  - **Implements**: Spec § Integration (Claude Messages API), § Concurrency Model (API semaphore), § Design Decisions (research via Messages API with web search).
  - **Completion**: `api_call` method exists in claude_client.rb. Accepts `prompt` and optional `model:` parameter (default `"claude-sonnet-4-6"`). Makes HTTP POST to Claude Messages API with `web_search_20250305` tool (up to 10 searches). Extracts and concatenates only `text`-type content blocks — discards `server_tool_use` and `web_search_tool_result` blocks. `@api_semaphore` (Mutex) + `@api_slots` (ConditionVariable) limit concurrent API calls to `MAX_API_CONCURRENCY` (20). API key sourced from `@api_key` instance variable. All API client tests pass.
  - **Scope boundary**: Does NOT integrate with Pipeline.new (item 9 adds the `api_key` kwarg and initializes semaphore). Does NOT implement research phase orchestration (item 13). Only adds the API call method and concurrency primitives.
  - **Files**: `pipeline/claude_client.rb` (add `api_call`, `acquire_api_slot`, `release_api_slot`), `pipeline.rb` (add `MAX_API_CONCURRENCY` constant), `test/api_call_test.rb` (new file)
  - **Testing**: Test per Spec § Test Organization — api_call_test.rb covers: successful API call with web search tool, response text extraction (only text blocks), error handling (API failures), API semaphore concurrency limiting. Stub HTTP calls (do not make real API calls in tests). Run `bundle exec rake test`.
  - **Implementation detail — HTTP request**: Use `Net::HTTP` (stdlib, no new gem). POST to `https://api.anthropic.com/v1/messages` with headers `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`. Body: `{ model:, max_tokens: 4096, tools: [{ type: "web_search_20250305", name: "web_search", max_uses: 10 }], messages: [{ role: "user", content: prompt }] }`.
  - **Implementation detail — response extraction**: Iterate `response["content"]`, select blocks where `type == "text"`, concatenate their `text` fields with newlines. Discard `server_tool_use` and `web_search_tool_result` blocks.
  - **Implementation detail — semaphore**: Mirror the existing `@claude_semaphore`/`@claude_slots`/`@claude_active` pattern. Add `@api_semaphore` (Mutex), `@api_slots` (ConditionVariable), `@api_active` (Integer) — these will be initialized in Pipeline.initialize in item 9. For the standalone test, set them up directly on the test pipeline instance.

- [ ] 8. **Implement Scheduler class**
  - **Implements**: Spec § Scheduler (Enhance Mode) — all methods, WorkItem fields, priority ordering, dispatch loop, starvation prevention.
  - **Completion**: `pipeline/scheduler.rb` exists with `Scheduler` class implementing: `enqueue`, `start`, `stop`, `queue_depth`, `active_items`. Dispatch loop runs in its own thread, checking `claude_slot_available?` and `try_acquire` before dispatching. Priority ordering: `e_applying > e_extracting > e_analyzing`. Starvation prevention: items waiting >10 minutes get priority escalation. Graceful shutdown — waits for active agents, doesn't dispatch new ones. All Scheduler tests pass.
  - **Scope boundary**: Does NOT integrate with Pipeline class (item 9). The Scheduler depends on LockManager (item 5) for `try_acquire` calls. It is a standalone class that accepts a LockManager and claude semaphore reference at construction.
  - **Files**: `pipeline/scheduler.rb` (new file), `test/scheduler_test.rb` (new file)
  - **Testing**: Test per Spec § Test Organization — scheduler_test.rb covers: enqueue (adds to queue), dispatch loop (dispatches when slot available and locks acquired), priority ordering (e_applying > e_extracting > e_analyzing), starvation prevention (10-minute escalation), graceful shutdown (stop waits for active, no new dispatch). Use mock LockManager and semaphore for isolation. Run `bundle exec rake test`.
  - **Implementation detail — WorkItem**: Define as a Struct with fields: `id` (SecureRandom.uuid), `workflow` (String), `phase` (Symbol), `lock_request` (LockRequest), `status` (:queued), `queued_at` (Time.now), `dispatched_at` (nil), `grant_id` (nil), `callback` (Proc).
  - **Implementation detail — LockRequest**: Define as a Struct with field `write_paths` (Array<String>, default empty).
  - **Implementation detail — dispatch loop**: Thread that loops with `sleep 0.5`, sorts queue by priority, iterates sorted items, checks `claude_slot_available?` (delegates to a callable passed at construction), calls `lock_manager.try_acquire` for items with non-empty write_paths, dispatches via `safe_thread_proc.call` (callable passed at construction) to run the item's callback. On `@shutdown`, stop dispatching and join active threads.
  - **Implementation detail — priority**: Map phases to priority numbers: `e_applying` → 0, `e_extracting` → 1, `e_analyzing` → 2, others → 3. Sort by `[priority, queued_at]`. Starvation: if `Time.now - item.queued_at > 600`, set effective priority to -1.

- [ ] 9. **Expand Pipeline class for enhance mode infrastructure**
  - **Implements**: Spec § Pipeline Configuration, § State Model (enhance workflow fields, ACTIVE_STATUSES), § Design Decisions (configurable pipeline with per-mode defaults, reset! clears in-memory state only).
  - **Completion**: `Pipeline.new` accepts new kwargs: `enhance_sidecar_dir` (default `".enhance"`), `enhance_allowed_write_paths` (default `["app/controllers", "app/views", "app/models", "app/services", "test/"]`), `api_key` (default `ENV["ANTHROPIC_API_KEY"]`), `lock_manager` (default creates new), `scheduler` (default creates new). `ACTIVE_STATUSES` includes all enhance mode active statuses per Spec § State Model. `initialize` creates `@lock_manager` and `@scheduler`, initializes `@api_semaphore`/`@api_slots`/`@api_active`. `reset!` clears LockManager grants and Scheduler queue. `to_json` includes lock state (`active_grants`, `queue_depth`, `active_items`) in output. `VALID_PROMPT_PHASES` in server.rb extended with enhance phases. All tests pass.
  - **Scope boundary**: Does NOT add enhance mode routes (item 18). Does NOT add enhance orchestration methods. Only expands the Pipeline class infrastructure and state model.
  - **Files**: `pipeline.rb` (kwargs, initialize, reset!, to_json, ACTIVE_STATUSES, require statements for new files), `server.rb` (VALID_PROMPT_PHASES expansion, update `$pipeline` instantiation if needed), `test/test_helper.rb` (may need kwargs for LockManager/Scheduler mocks), `test/pipeline_reset_test.rb` (verify reset clears enhance state)
  - **Testing**: Update pipeline_reset_test.rb to verify LockManager and Scheduler are cleared. Verify to_json includes lock/scheduler state. Verify new kwargs have correct defaults. Existing tests must still pass (new kwargs have defaults). Run `bundle exec rake test`.
  - **Implementation detail — ACTIVE_STATUSES**: Replace the current array with:
    ```ruby
    ACTIVE_STATUSES = %w[
      h_analyzing h_hardening h_testing h_fixing_tests
      h_ci_checking h_fixing_ci h_verifying
      e_analyzing e_extracting e_synthesizing
      e_auditing e_planning_batches e_applying e_testing
      e_fixing_tests e_ci_checking e_fixing_ci e_verifying
    ].freeze
    ```
  - **Implementation detail — VALID_PROMPT_PHASES**: Extend to include enhance phases:
    ```ruby
    VALID_PROMPT_PHASES = %w[
      h_analyze h_harden h_fix_tests h_fix_ci h_verify
      e_analyze e_apply e_fix_tests e_fix_ci e_verify
    ].freeze
    ```
  - **Implementation detail — initialize additions**: Add after existing instance variables:
    ```ruby
    @enhance_sidecar_dir = enhance_sidecar_dir
    @enhance_allowed_write_paths = enhance_allowed_write_paths
    @api_key = api_key
    @lock_manager = lock_manager || LockManager.new
    @scheduler = scheduler || Scheduler.new(lock_manager: @lock_manager, ...)
    @api_semaphore = Mutex.new
    @api_slots = ConditionVariable.new
    @api_active = 0
    ```
  - **Implementation detail — reset!**: Add within the mutex block: `@lock_manager.release_all` (add this method to LockManager if needed), `@scheduler.stop` if running, `@api_active = 0`.
  - **Implementation detail — to_json**: Add to the merged hash: `locks: { active_grants: @lock_manager.active_grants, queue_depth: @scheduler.queue_depth, active_items: @scheduler.active_items }`.

- [ ] 10a. **Create `shared_phases.rb`, extract `shared_apply` from `run_hardening`**
  - **Implements**: Spec § Code Organization (`pipeline/shared_phases.rb`), § Design Decisions (shared core orchestration for write phases, thin wrappers).
  - **Completion**: `pipeline/shared_phases.rb` exists with `SharedPhases` module containing `shared_apply`. `pipeline.rb` has `require_relative "pipeline/shared_phases"` and `include SharedPhases`. `run_hardening` in orchestration.rb is a thin wrapper that delegates to `shared_apply` with hardening-specific parameters. All existing hardening tests pass without modification.
  - **Scope boundary**: Does NOT extract `shared_test`, `shared_ci_check`, or `shared_verify` (items 10b-10d). Does NOT add enhance mode orchestration. Only creates the module, establishes the pattern, and extracts `shared_apply`.
  - **Files**: `pipeline/shared_phases.rb` (new file — module with `shared_apply`), `pipeline/orchestration.rb` (`run_hardening` becomes thin wrapper), `pipeline.rb` (add `require_relative` and `include SharedPhases`)
  - **Testing**: All existing hardening tests must pass without changes to their call sites or assertions. The refactoring is transparent to callers. If any test fails, the shared helper parameterization is wrong — fix the helper, not the test. Run `bundle exec rake test`.
  - **Implementation detail — shared helper signature**:
    ```ruby
    def shared_apply(name, apply_prompt_fn:, applied_status:, applying_status:,
                     skipped_status:, sidecar_dir:, staging_subdir: "staging",
                     grant_id: nil)
    ```
    The hardening wrapper calls it with `apply_prompt_fn: method(:hardening_apply_prompt)`, `applied_status: "h_hardened"`, `applying_status: "h_hardening"`, `skipped_status: "h_skipped"`, `sidecar_dir: @sidecar_dir`.
  - **Implementation detail — extraction strategy**: Copy the body of `run_hardening` into `shared_apply`, replacing every hardcoded status string with a parameter. Replace `run_hardening` body with a one-line delegation to `shared_apply`.

- [ ] 10b. **Extract `shared_test` from `run_testing`**
  - **Implements**: Spec § Code Organization (`pipeline/shared_phases.rb`), § Design Decisions (shared core orchestration for write phases, thin wrappers).
  - **Completion**: `shared_test` exists in `SharedPhases` module. `run_testing` in orchestration.rb is a thin wrapper that delegates to `shared_test` with hardening-specific parameters (statuses: `"h_testing"`, `"h_fixing_tests"`, `"h_tested"`, `"h_tests_failed"`, prompt generator). All existing tests pass.
  - **Scope boundary**: Follows the pattern established in 10a. Does NOT extract `shared_ci_check` or `shared_verify`.
  - **Files**: `pipeline/shared_phases.rb` (add `shared_test`), `pipeline/orchestration.rb` (`run_testing` becomes thin wrapper)
  - **Testing**: All existing hardening tests must pass without changes. Run `bundle exec rake test`.

- [ ] 10c. **Extract `shared_ci_check` from `run_ci_checks`**
  - **Implements**: Spec § Code Organization (`pipeline/shared_phases.rb`), § Design Decisions (shared core orchestration for write phases, thin wrappers).
  - **Completion**: `shared_ci_check` exists in `SharedPhases` module. `run_ci_checks` in orchestration.rb is a thin wrapper. All existing tests pass.
  - **Scope boundary**: Follows the pattern established in 10a. Does NOT extract `shared_verify`.
  - **Files**: `pipeline/shared_phases.rb` (add `shared_ci_check`), `pipeline/orchestration.rb` (`run_ci_checks` becomes thin wrapper)
  - **Testing**: All existing hardening tests must pass without changes. Run `bundle exec rake test`.

- [ ] 10d. **Extract `shared_verify` from `run_verification`**
  - **Implements**: Spec § Code Organization (`pipeline/shared_phases.rb`), § Design Decisions (shared core orchestration for write phases, thin wrappers).
  - **Completion**: `shared_verify` exists in `SharedPhases` module. `run_verification` in orchestration.rb is a thin wrapper. All existing tests pass. All four shared phase helpers are now complete.
  - **Scope boundary**: Completes the shared phases extraction. Does NOT add enhance mode orchestration (items 12-17). Routes and test call sites remain unchanged — they still call `run_hardening`, `run_testing`, etc.
  - **Files**: `pipeline/shared_phases.rb` (add `shared_verify`), `pipeline/orchestration.rb` (`run_verification` becomes thin wrapper)
  - **Testing**: All existing hardening tests must pass without changes. Run `bundle exec rake test`.

- [ ] 11. **Add all enhance mode prompt templates**
  - **Implements**: Spec § Code Organization (`prompts.rb` — enhance prompt templates), § Enhance Mode phase details (E0-E10 inputs and outputs).
  - **Completion**: `prompts.rb` contains new class methods: `Prompts.e_analyze`, `Prompts.research`, `Prompts.extract`, `Prompts.synthesize`, `Prompts.audit`, `Prompts.batch_plan`, `Prompts.e_apply`, `Prompts.e_fix_tests`, `Prompts.e_fix_ci`, `Prompts.e_verify`. Each prompt accepts the inputs specified in the Spec § Enhance Mode phase details and instructs the agent to produce the specified output format. Write-phase prompts (`e_apply`, `e_fix_tests`, `e_fix_ci`) use the staging directory pattern (agent writes to staging, returns metadata-only JSON). All prompts use `--dangerously-skip-permissions` context (agents read app code freely). Existing tests pass.
  - **Scope boundary**: Does NOT implement orchestration logic. Only adds prompt template methods to prompts.rb. Prompt content is a separate concern from pipeline infrastructure.
  - **Files**: `prompts.rb`
  - **Testing**: No new test file needed for prompts alone (prompts are tested indirectly through orchestration tests in items 12-17). Verify existing tests still pass. Run `bundle exec rake test`.
  - **Implementation detail — method signatures** (derived from Spec § Enhance Mode phase details):
    - `e_analyze(controller_name, source, views, routes, models, verification_report)` → JSON: analysis document + research topic prompts
    - `research(topic_prompt)` → used as the API call prompt, returns text
    - `extract(analysis, research_results)` → JSON: POSSIBLE items list
    - `synthesize(analysis, possible_items, source)` → JSON: READY items with impact/effort
    - `audit(ready_items, deferred_items, rejected_items)` → JSON: annotated READY items
    - `batch_plan(todo_items, analysis, source, operator_notes: nil)` → JSON: batch definitions with write_targets
    - `e_apply(batch_items, analysis, source, staging_dir)` → JSON: metadata-only (agent writes to staging)
    - `e_fix_tests(controller_name, test_output, analysis, staging_dir)` → JSON: metadata-only
    - `e_fix_ci(controller_name, ci_output, analysis, staging_dir)` → JSON: metadata-only
    - `e_verify(controller_name, original_source, current_source, analysis, batch_items)` → JSON: verification report

- [ ] 12. **Implement enhance analysis phase (E0)**
  - **Implements**: Spec § Enhance Mode (E0 — Analyze), § Persistence (analysis.json), § State Model (enhance workflow fields).
  - **Completion**: `pipeline/enhance_orchestration.rb` exists with `EnhanceOrchestration` module. `run_enhance_analysis` method: reads controller source + views + routes + related models + hardening verification report, calls `claude -p` with `Prompts.e_analyze`, parses response, writes `analysis.json` to `.enhance/` sidecar, stores research topic prompts in workflow. Workflow status transitions: entry from `h_complete` or `e_enhance_complete` → `e_analyzing` → `e_awaiting_research`. Workflow fields populated: `e_analysis`, `research_topics` (array of topic objects with `prompt`, `status: "pending"`, `result: nil`). Mode field set to `"enhance"`. All enhance analysis tests pass.
  - **Scope boundary**: Does NOT implement research phase (item 13). Does NOT implement Scheduler dispatch (the orchestration method is called directly; Scheduler integration happens in item 20 routes). Only creates the enhance orchestration file and E0 method.
  - **Files**: `pipeline/enhance_orchestration.rb` (new file), `pipeline.rb` (add require_relative and include), `test/enhance_analysis_test.rb` (new file)
  - **Testing**: Test per Spec § Test Organization — enhance_analysis_test.rb covers: happy path (analysis produces structured output + research topics), hardening prerequisite check (must be `h_complete` or `e_enhance_complete`), error handling (claude -p failure sets `error` status), sidecar write verification. Stub `claude_call`. Run `bundle exec rake test`.
  - **Implementation detail — enhance sidecar path**: Use `@enhance_sidecar_dir` instead of `@sidecar_dir`. The sidecar helpers in sidecar.rb use `@sidecar_dir`, so enhance orchestration should call `sidecar_path` with a locally overridden directory, or compute the path directly: `File.join(File.dirname(source_path), @enhance_sidecar_dir, ctrl_name, filename)`.
  - **Implementation detail — workflow field additions**: When entering enhance mode, set `wf[:mode] = "enhance"` and add the new fields: `wf[:e_analysis] = parsed`, `wf[:research_topics] = parsed["research_topics"].map { |t| { prompt: t, status: "pending", result: nil } }`.

- [ ] 13. **Implement research phase (E1)**
  - **Implements**: Spec § Enhance Mode (E1 — Research), § Persistence (research_status.json, research/*.md), § Design Decisions (research via Messages API with web search).
  - **Completion**: `submit_research` method handles manual paste — sets topic status to `completed`, stores result, writes to `.enhance/<ctrl>/research/<topic_slug>.md`, checks completion (all non-rejected topics completed → advance to `e_extracting`). `submit_research_api` method handles Claude API research — sets topic to `researching`, calls `api_call` in background thread with web search, stores response, updates topic to `completed` (or back to `pending` on failure). `reject_research_topic` method sets topic to `rejected` and checks completion. `research_status.json` written on each topic state change for resume. Multiple API calls bounded by `MAX_API_CONCURRENCY`. All research tests pass.
  - **Scope boundary**: Does NOT implement E2 extraction (item 14). Does NOT implement Scheduler dispatch. Only adds research methods to enhance_orchestration.rb.
  - **Files**: `pipeline/enhance_orchestration.rb` (add research methods), `test/research_test.rb` (new file)
  - **Testing**: Test per Spec § Test Organization — research_test.rb covers: per-topic state transitions (pending → researching → completed, pending → completed via paste, pending → rejected), API research path (stub api_call, verify web search tool request), manual paste, topic rejection, completion tracking (auto-advance when all non-rejected topics done), API failure recovery (topic reverts to pending), concurrent API call bounding. Run `bundle exec rake test`.
  - **Implementation detail — topic slug**: Derive from the topic prompt: `topic_prompt.downcase.gsub(/[^a-z0-9]+/, "_").slice(0, 50)`.
  - **Implementation detail — completion check**: After each topic state change (completed, rejected), check: `topics.reject { |t| t[:status] == "rejected" }.all? { |t| t[:status] == "completed" }`. If true, set workflow status to `"e_extracting"` and trigger the E2→E4 chain (or just set the status — the route handler or Scheduler will dispatch the chain).
  - **Implementation detail — research_status.json**: On each topic state change, write the current topic statuses to `.enhance/<ctrl>/research_status.json` for resume capability.

- [ ] 14. **Implement extract phase (E2)**
  - **Implements**: Spec § Enhance Mode (E2 — Extract), § Persistence (extract.json).
  - **Completion**: `run_extraction` method: reads analysis + research results, calls `claude -p` with `Prompts.extract`, produces POSSIBLE items list, writes `extract.json` to sidecar. Status transitions: `e_extracting` (set by caller or completion check) → method runs → sets up for synthesis. All extraction tests pass.
  - **Scope boundary**: Does NOT implement synthesis or audit. Only implements E2. The E2→E3→E4 chaining is handled by a separate chain entry point method (item 16).
  - **Files**: `pipeline/enhance_orchestration.rb` (add `run_extraction`), `test/extraction_test.rb` (new file)
  - **Testing**: Test per Spec § Test Organization — extraction_test.rb covers: item generation from research results, POSSIBLE item output format, error handling, sidecar write. Stub `claude_call`. Run `bundle exec rake test`.

- [ ] 15. **Implement synthesis phase (E3)**
  - **Implements**: Spec § Enhance Mode (E3 — Synthesize), § Persistence (synthesize.json).
  - **Completion**: `run_synthesis` method: reads analysis + POSSIBLE items + controller source, calls `claude -p` with `Prompts.synthesize`, produces READY items with impact/effort ratings, writes `synthesize.json`. Status transition: `e_synthesizing`. All synthesis tests pass.
  - **Scope boundary**: Does NOT implement audit. Only implements E3.
  - **Files**: `pipeline/enhance_orchestration.rb` (add `run_synthesis`), `test/synthesis_test.rb` (new file)
  - **Testing**: Test per Spec § Test Organization — synthesis_test.rb covers: impact/effort rating, filtering already-implemented items, READY item generation, sidecar write. Stub `claude_call`. Run `bundle exec rake test`.

- [ ] 16. **Implement audit phase (E4) and E2→E4 chain entry point**
  - **Implements**: Spec § Enhance Mode (E4 — Audit), § Design Decisions (synchronous phase chaining for analysis pipelines), § Persistence (audit.json, decisions/deferred.json, decisions/rejected.json).
  - **Completion**: `run_audit` method: reads READY items + per-controller deferred/rejected items from `.enhance/<ctrl>/decisions/`, calls `claude -p` with `Prompts.audit`, annotates items with prior-decision context (does NOT filter), writes `audit.json`. `run_extraction_chain` method: calls `run_extraction` → `run_synthesis` → `run_audit` sequentially in one thread, status updating as chain progresses (`e_extracting` → `e_synthesizing` → `e_auditing` → `e_awaiting_decisions`). All chain tests pass.
  - **Scope boundary**: Does NOT implement E5 decisions (item 17). The chain is called as a unit after E1 completes.
  - **Files**: `pipeline/enhance_orchestration.rb` (add `run_audit`, `run_extraction_chain`), `test/audit_test.rb` (new file)
  - **Testing**: Test per Spec § Test Organization — audit_test.rb covers: annotation (not filtering) against prior deferred/rejected items, prior-decision context and suggested defaults, sidecar write. Also test the chain sequencing in a separate test: E2 status → E3 status → E4 status → `e_awaiting_decisions`. Stub `claude_call`. Run `bundle exec rake test`.
  - **Implementation detail — deferred/rejected loading**: Read from `.enhance/<ctrl>/decisions/deferred.json` and `rejected.json` if they exist. Pass empty arrays if files don't exist (first enhance cycle).

- [ ] 17. **Implement enhance decisions phase (E5)**
  - **Implements**: Spec § Enhance Mode (E5 — Decide), § Persistence (decisions.json, decisions/deferred.json, decisions/rejected.json).
  - **Completion**: `submit_enhance_decisions` method: receives per-item decisions (TODO/DEFER/REJECT), stores in workflow `e_decisions`, writes `decisions.json` to sidecar. DEFER items persisted to `.enhance/<ctrl>/decisions/deferred.json` (per-controller, with description, decision, timestamp, optional notes). REJECT items persisted to `.enhance/<ctrl>/decisions/rejected.json` (same format). These persist across enhance cycles for the audit phase (E4). Workflow advances to `e_planning_batches` (triggers batch planning). Requires guard status `e_awaiting_decisions`. All tests pass.
  - **Scope boundary**: Does NOT implement batch planning (item 18). Only handles decision persistence and state transition.
  - **Files**: `pipeline/enhance_orchestration.rb` (add `submit_enhance_decisions`), `test/enhance_decisions_test.rb` (new file)
  - **Testing**: Verify: decision submission with TODO/DEFER/REJECT mix, deferred.json and rejected.json persistence (file contents match expected format), workflow status advance to `e_planning_batches`, guard check (must be `e_awaiting_decisions`). Run `bundle exec rake test`.

- [ ] 18. **Implement batch planning phase (E6)**
  - **Implements**: Spec § Enhance Mode (E6 — Batch plan), § Persistence (batches.json).
  - **Completion**: `run_batch_planning` method: reads approved TODO items + analysis + controller source, calls `claude -p` with `Prompts.batch_plan`, produces ordered batch definitions with `write_targets` (specific file paths) and estimated effort. Writes `batches.json` to sidecar. Workflow transitions: `e_planning_batches` → `e_awaiting_batch_approval` (human gate). Batch re-planning: `replan_batches` method accepts operator notes, cycles `e_awaiting_batch_approval` → `e_planning_batches` → `e_awaiting_batch_approval` with operator notes as additional context. Re-planning is unbounded. Stores batches in workflow with batch ids. All tests pass.
  - **Scope boundary**: Does NOT implement batch execution (item 19). Only produces batch definitions for human review.
  - **Files**: `pipeline/enhance_orchestration.rb` (add `run_batch_planning`, `replan_batches`), `test/batch_planning_test.rb` (new file)
  - **Testing**: Test per Spec § Test Organization — batch grouping by effort/overlap/dependencies, write target declaration, batch plan approval flow, re-planning with notes (status cycling), sidecar write. Run `bundle exec rake test`.

- [ ] 19. **Implement batch execution phases (E7-E10)**
  - **Implements**: Spec § Enhance Mode (E7-E10 — Apply/Test/CI/Verify), § Design Decisions (sequential batches within a controller, parallel across controllers), § Staging Write Pattern (enhance staging), § LockManager grant lifecycle.
  - **Completion**: `run_batch_execution` method: iterates through approved batches sequentially within a controller. For each batch: acquires write locks via LockManager (`acquire` with timeout), runs the full E7→E10 chain via shared phases (from item 10a-10d) with enhance-mode-specific parameters (prompts from item 11, enhance sidecar/staging directories, grant_id for safe_write enforcement). Grant held throughout the chain, renewed after each `claude -p` return. Grant released via `ensure` block on completion or error. Staging directory: `.enhance/<ctrl>/<batch_id>/staging/`. Workflow tracks `current_batch_id`. Status transitions per batch: `e_applying` → `e_testing` / `e_fixing_tests` → `e_ci_checking` / `e_fixing_ci` → `e_verifying` → `e_batch_complete`. When last batch completes, workflow advances to `e_enhance_complete`. Fix loop exhaustion → `e_tests_failed` or `e_ci_failed` (grant released, retry re-runs from E7). All tests pass.
  - **Scope boundary**: Does NOT implement cross-controller parallelism via Scheduler (the orchestration method handles one controller's batches; the Scheduler dispatches across controllers in item 20). Does NOT modify shared phases — only calls them with enhance parameters.
  - **Files**: `pipeline/enhance_orchestration.rb` (add `run_batch_execution`), `test/batch_execution_test.rb` (new file)
  - **Testing**: Test per Spec § Test Organization — batch apply/test/ci/verify with lock grants (stub LockManager), shared core orchestration delegation, sequential batch chain (batch 1 completes before batch 2 starts), current_batch_id tracking, grant lifecycle (acquired at E7, renewed on claude -p return, released on completion/error via ensure), e_enhance_complete on last batch, e_tests_failed/e_ci_failed with grant release. Run `bundle exec rake test`.
  - **Implementation detail — grant renewal**: After each `claude_call` returns within a batch, call `@lock_manager.renew(grant_id: grant.id)`. This extends the TTL so long-running batches don't expire.
  - **Implementation detail — grant release via ensure**: Wrap the batch loop body in `begin...ensure` that calls `@lock_manager.release(grant_id: grant.id)` if grant is non-nil.
  - **Implementation detail — calling shared phases**: Call `shared_apply` with enhance-specific params:
    ```ruby
    shared_apply(name,
      apply_prompt_fn: -> { Prompts.e_apply(batch_items, analysis, source, staging_dir) },
      applying_status: "e_applying",
      applied_status: "e_batch_applied",  # internal gate
      skipped_status: nil,  # no skip in enhance
      sidecar_dir: @enhance_sidecar_dir,
      staging_subdir: "#{batch_id}/staging",
      grant_id: grant.id
    )
    ```
    Similarly for `shared_test`, `shared_ci_check`, `shared_verify`.

- [ ] 20. **Add enhance mode server routes**
  - **Implements**: Spec § Integration (HTTP Routes — all `/enhance/*` routes), § Server Layer (enhance routes use Scheduler for dispatch).
  - **Completion**: All enhance routes exist per Spec § HTTP Routes: `POST /enhance/analyze` (starts E0, uses Scheduler if available), `POST /enhance/research` (manual paste), `POST /enhance/research/api` (API research), `POST /enhance/decisions` (E5), `POST /enhance/batches/approve` (E6 approval, starts batch execution), `POST /enhance/batches/replan` (E6 rejection with notes), `POST /enhance/retry` (re-run last failed enhance phase), `POST /enhance/retry-tests` (retry batch from E7), `POST /enhance/retry-ci` (retry batch from E7), `GET /enhance/locks` (lock state). Analyze route dispatches via Scheduler when available, falls back to `safe_thread`. Human-gate routes update state directly. All routes use `try_transition` with appropriate guards (including compound guard `["h_complete", "e_enhance_complete"]` for analyze). All route behavior verified.
  - **Scope boundary**: Does NOT add frontend UI (items 22-23). Only adds server-side route handlers.
  - **Files**: `server.rb` (add all `/enhance/*` routes)
  - **Testing**: Route tests via rack-test in a new `test/enhance_routes_test.rb` file. Verify: correct try_transition guards, Scheduler dispatch for analyze, JSON body parameter handling, error responses for invalid states. Run `bundle exec rake test`.
  - **Implementation detail — route patterns**: Follow the existing route pattern in server.rb. Each route: parse JSON body, extract controller name, call `try_transition` with appropriate guard and target status, dispatch work via `safe_thread` or Scheduler. Example:
    ```ruby
    post '/enhance/analyze' do
      content_type :json
      body = parse_json_body
      controller = body["controller"]
      halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?
      ok, err = $pipeline.try_transition(controller, guard: ["h_complete", "e_enhance_complete"], to: "e_analyzing")
      halt 409, { error: err }.to_json unless ok
      if $pipeline.scheduler
        $pipeline.scheduler.enqueue(workflow: controller, phase: :e_analyze, lock_request: LockRequest.new(write_paths: [])) { $pipeline.run_enhance_analysis(controller) }
      else
        $pipeline.safe_thread(workflow_name: controller) { $pipeline.run_enhance_analysis(controller) }
      end
      { status: "enhancing", controller: controller }.to_json
    end
    ```

- [ ] 21. **Enhance discovery to scan `.enhance/` sidecars for resume**
  - **Implements**: Spec § Persistence (Resume on restart — resume rules), § Design Decisions (sidecar files enable resumability).
  - **Completion**: `discover_controllers` scans both `.harden/` and `.enhance/` sidecar directories for each controller. Resume rules applied: `.harden/verification.json` → `h_complete`; `.enhance/analysis.json` with pending research topics → `e_awaiting_research`; `.enhance/decisions.json` without `batches.json` → `e_awaiting_decisions`; `.enhance/batches.json` without batch apply → `e_awaiting_batch_approval`; partial batch progress resumes at appropriate phase. Controller discovery entries include enhance sidecar presence/timestamps. Deferred and rejected items loaded from `.enhance/<ctrl>/decisions/` at startup for audit phase. All discovery tests pass.
  - **Scope boundary**: Does NOT change the discovery sorting logic. Only adds `.enhance/` scanning and resume status determination.
  - **Files**: `pipeline/orchestration.rb` (update `discover_controllers`), `test/pipeline_discovery_test.rb` (add enhance sidecar tests)
  - **Testing**: New tests: controller with `.enhance/` sidecar at various phases resumes correctly, deferred/rejected items loaded from sidecar. Existing discovery tests still pass. Run `bundle exec rake test`.
  - **Implementation detail — enhance sidecar scanning**: After the existing `.harden/` sidecar checks, add parallel checks for `.enhance/` files:
    ```ruby
    enhance_analysis_file = File.join(File.dirname(path), @enhance_sidecar_dir, basename, "analysis.json")
    enhance_decisions_file = File.join(File.dirname(path), @enhance_sidecar_dir, basename, "decisions.json")
    enhance_batches_file = File.join(File.dirname(path), @enhance_sidecar_dir, basename, "batches.json")
    # ... check existence and determine resume status
    ```
  - **Implementation detail — resume status determination**: Check in order from most-complete to least-complete: (1) all batches have verification.json → `e_enhance_complete`, (2) batches.json exists with partial batch progress → resume at appropriate batch phase, (3) batches.json exists with no progress → `e_awaiting_batch_approval`, (4) decisions.json exists without batches.json → `e_awaiting_decisions`, (5) analysis.json exists with research_status.json showing pending topics → `e_awaiting_research`, (6) analysis.json exists with all research complete → `e_extracting`.

- [ ] 22. **Add enhance mode status rendering to frontend**
  - **Implements**: Spec § Frontend (enhance mode status display), § State Model (enhance workflow fields, mode field).
  - **Completion**: `index.html` renders enhance mode statuses correctly. New CSS classes for all `e_`-prefixed statuses (dot colors, status badges). Status labels object extended with enhance status display names. Sidebar shows mode indicator per controller (hardening vs enhance). Controllers at `h_complete` show "Start Enhance" button. Active phase detection includes enhance statuses. Header summary counts include enhance statuses. Mode-aware workflow detail rendering — shows appropriate phase information based on `workflow.mode`. Existing hardening UI unchanged.
  - **Scope boundary**: Does NOT add interactive enhance panels (item 23). Only adds status rendering, mode indicators, and the enhance entry point button. Detail panels show phase status and basic output but not interactive controls.
  - **Files**: `index.html`
  - **Testing**: Manual verification — load the UI, verify enhance statuses render with correct colors/labels, verify mode indicator appears, verify "Start Enhance" button appears for h_complete controllers. Existing hardening UI must still work.

- [ ] 23. **Add enhance mode interactive panels to frontend**
  - **Implements**: Spec § Frontend (research topic management, item review, batch plan review, lock contention visualization, batch progress tracking).
  - **Completion**: Research panel (E1): displays all topics with status, "USE API" button, manual paste textarea, "Reject" button per topic, topic completion indicator. Item review panel (E5): sorted item list with prior-decision defaults (new→TODO, deferred→DEFER, rejected→REJECT), impact/effort badges, override controls, submit button. Batch plan panel (E6): batch list with items and write targets, "Approve" and "Reject with Notes" buttons. Batch progress panel (E7-E10): current batch status, phase progress indicator, retry buttons for `e_tests_failed`/`e_ci_failed`. Lock visualization: active grants list, queue depth, contention indicators. All panels use the established morphdom rendering pattern — build HTML string, morphdom diffs. Client-side state for enhance panels tracked in `perController`.
  - **Scope boundary**: Does NOT change the rendering architecture. Follows existing patterns (morphdom, perController state, apiFetch for POSTs).
  - **Files**: `index.html`
  - **Testing**: Manual verification — test each panel: research topic interactions (API call, paste, reject), item decision submission, batch plan approval/rejection, batch progress display, lock state display. Verify morphdom preserves focus state in enhance panels (textarea, inputs).
