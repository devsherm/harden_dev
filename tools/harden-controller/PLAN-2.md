# Implementation Plan — Phase 2 (Infrastructure + Shared Phases)

> Generated from `tools/harden-controller/SPEC.proposed.md` (delta mode)
> Phase 2 of 3: Items 5-10d (LockManager, grant enforcement, API client, Scheduler, Pipeline expansion, shared phase extraction)
> **Prerequisite**: Phase 1 (items 1-4) complete and reviewed.

## Recovery Instructions

- If tests fail after an item, fix the failing tests before moving to the next item.
- If an item cannot be completed as described, add a `BLOCKED:` note to the item and move to the next one.
- After completing each item, verify the codebase is in a clean, working state before proceeding.
- Run `cd tools/harden-controller && bundle exec rake test` to verify tests pass after each item.

## Items

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
