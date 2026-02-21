# Implementation Plan — Phase 3 (Enhance Mode)

> Generated from `tools/harden-controller/SPEC.proposed.md` (delta mode)
> Phase 3 of 3: Items 11-23 (prompts, orchestration E0-E10, routes, discovery resume, frontend)
> **Prerequisite**: Phase 2 (items 5-10d) complete and reviewed.

## Recovery Instructions

- If tests fail after an item, fix the failing tests before moving to the next item.
- If an item cannot be completed as described, add a `BLOCKED:` note to the item and move to the next one.
- After completing each item, verify the codebase is in a clean, working state before proceeding.
- Run `cd tools/harden-controller && bundle exec rake test` to verify tests pass after each item.

## Items

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
  - **Implementation detail — enhance sidecar path helper**: Add an `enhance_sidecar_path(target_path, filename)` helper method that computes paths under `.enhance/`:
    ```ruby
    def enhance_sidecar_path(target_path, filename)
      File.join(
        File.dirname(target_path),
        @enhance_sidecar_dir,
        File.basename(target_path, ".rb"),
        filename
      )
    end
    ```
    Use this helper in all enhance orchestration methods (items 13-19) instead of computing paths ad-hoc. This reduces duplication and path-computation errors.
  - **Implementation detail — workflow field additions**: When entering enhance mode, set `wf[:mode] = "enhance"` and add the new fields: `wf[:e_analysis] = parsed`, `wf[:research_topics] = parsed["research_topics"].map { |t| { prompt: t, status: "pending", result: nil } }`.

- [ ] 13. **Implement research phase (E1)**
  - **Implements**: Spec § Enhance Mode (E1 — Research), § Persistence (research_status.json, research/*.md), § Design Decisions (research via Messages API with web search).
  - **Completion**: `submit_research` method handles manual paste — sets topic status to `completed`, stores result, writes to `.enhance/<ctrl>/research/<topic_slug>.md`, checks completion (all non-rejected topics completed → advance to `e_extracting`). `submit_research_api` method handles Claude API research — sets topic to `researching`, calls `api_call` in background thread with web search, stores response, updates topic to `completed` (or back to `pending` on failure). `reject_research_topic` method sets topic to `rejected` and checks completion. `research_status.json` written on each topic state change for resume. Multiple API calls bounded by `MAX_API_CONCURRENCY`. All research tests pass.
  - **Scope boundary**: Does NOT implement E2 extraction (item 14). Does NOT implement Scheduler dispatch. Only adds research methods to enhance_orchestration.rb.
  - **Files**: `pipeline/enhance_orchestration.rb` (add research methods), `test/research_test.rb` (new file)
  - **Testing**: Test per Spec § Test Organization — research_test.rb covers: per-topic state transitions (pending → researching → completed, pending → completed via paste, pending → rejected), API research path (stub api_call, verify web search tool request), manual paste, topic rejection, completion tracking (auto-advance when all non-rejected topics done), API failure recovery (topic reverts to pending), concurrent API call bounding. Run `bundle exec rake test`.
  - **Implementation detail — topic slug**: Derive from the topic prompt: `topic_prompt.downcase.gsub(/[^a-z0-9]+/, "_").slice(0, 50)`.
  - **Implementation detail — research thread type**: `submit_research_api` uses a raw `Thread.new` (NOT `safe_thread`) with a `begin/rescue` block. On success: set topic status to `completed`, store result, write research MD file, run completion check. On failure: revert topic status to `pending`, log the error via `add_error`, do NOT change workflow status. `safe_thread` is too aggressive — it sets the entire workflow to `error` on exception, but the spec requires per-topic recovery (`pending` on API failure).
  - **Implementation detail — completion check**: After each topic state change (completed, rejected), check: `topics.reject { |t| t[:status] == "rejected" }.all? { |t| t[:status] == "completed" }`. On completion, set workflow status to `e_extracting`, then enqueue `run_extraction_chain` via Scheduler (with `safe_thread` fallback when Scheduler is unavailable).
  - **Implementation detail — research_status.json**: On each topic state change, write the current topic statuses to `.enhance/<ctrl>/research_status.json` for resume capability.

- [ ] 14. **Implement extract phase (E2)**
  - **Implements**: Spec § Enhance Mode (E2 — Extract), § Persistence (extract.json).
  - **Completion**: `run_extraction` method: reads analysis + research results, calls `claude -p` with `Prompts.extract`, produces POSSIBLE items list, writes `extract.json` to sidecar. Status transitions: `e_extracting` (set by caller or completion check) → method runs → sets up for synthesis. All extraction tests pass.
  - **Scope boundary**: Does NOT implement synthesis or audit. Only implements E2. The E2→E3→E4 chaining is handled by a separate chain entry point method (item 16). `run_extraction` is a pure work method — it reads input, calls claude, writes sidecar, and returns. It does NOT set workflow status. Status transitions (`e_extracting` → `e_synthesizing` → `e_auditing` → `e_awaiting_decisions`) are managed solely by `run_extraction_chain` (item 16).
  - **Files**: `pipeline/enhance_orchestration.rb` (add `run_extraction`), `test/extraction_test.rb` (new file)
  - **Testing**: Test per Spec § Test Organization — extraction_test.rb covers: item generation from research results, POSSIBLE item output format, error handling, sidecar write. Stub `claude_call`. Run `bundle exec rake test`.

- [ ] 15. **Implement synthesis phase (E3)**
  - **Implements**: Spec § Enhance Mode (E3 — Synthesize), § Persistence (synthesize.json).
  - **Completion**: `run_synthesis` method: reads analysis + POSSIBLE items + controller source, calls `claude -p` with `Prompts.synthesize`, produces READY items with impact/effort ratings, writes `synthesize.json`. Status transition: `e_synthesizing`. All synthesis tests pass.
  - **Scope boundary**: Does NOT implement audit. Only implements E3. `run_synthesis` is a pure work method — it reads input, calls claude, writes sidecar, and returns. It does NOT set workflow status. Status transitions are managed by `run_extraction_chain` (item 16).
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

- [ ] 19a. **Parameterize shared phases for enhance mode**
  - **Implements**: Prerequisite for items 19b-19c. Addresses gaps in shared phase methods that prevent enhance mode callers from directing sidecar output and staging paths correctly.
  - **Completion**: `shared_test` and `shared_ci_check` accept `sidecar_dir:` and `staging_subdir:` kwargs (defaulting to current hardening behavior), matching the pattern established by `shared_apply`. `shared_apply` and `shared_verify` accept `analysis_key:` kwarg (defaulting to `:analysis`) so enhance callers can pass `analysis_key: :e_analysis`. All four shared methods (`shared_apply`, `shared_test`, `shared_ci_check`, `shared_verify`) accept a `sidecar_output_dir:` kwarg for directing sidecar output files (`apply.json`, `test_results.json`, `ci_results.json`, `verification.json`) to batch-specific directories like `batches/<batch_id>/`. Existing hardening callers use defaults — no behavior change. All existing tests pass.
  - **Scope boundary**: Does NOT implement enhance orchestration. Only parameterizes shared phases for both-mode usage. Mirrors the pattern PLAN-2 used for items 10a-10d.
  - **Files**: `pipeline/shared_phases.rb` (add kwargs to `shared_test`, `shared_ci_check`, `shared_apply`, `shared_verify`), `test/pipeline_testing_test.rb` (add kwargs tests), `test/pipeline_ci_checks_test.rb` (add kwargs tests), `test/pipeline_hardening_test.rb` (verify no behavior change), `test/pipeline_verification_test.rb` (add kwargs tests)
  - **Testing**: Verify new kwargs work: `shared_test` and `shared_ci_check` with custom `sidecar_dir:`/`staging_subdir:`, `shared_apply` and `shared_verify` with `analysis_key: :e_analysis`, all four methods with `sidecar_output_dir:` pointing to a batch subdirectory. Verify existing hardening tests still pass with defaults. Run `bundle exec rake test`.

- [ ] 19b. **Implement batch execution iteration logic (E7-E10)**
  - **Implements**: Spec § Enhance Mode (E7-E10 — Apply/Test/CI/Verify), § Design Decisions (sequential batches within a controller, parallel across controllers), § Staging Write Pattern (enhance staging).
  - **Completion**: `run_batch_execution` method: iterates through approved batches sequentially within a controller. For each batch: runs the full E7→E10 chain via shared phases (from items 10a-10d and 19a) with enhance-mode-specific parameters (prompts from item 11, enhance sidecar/staging directories). Staging directory: `.enhance/<ctrl>/batches/<batch_id>/staging/`. Workflow tracks `current_batch_id`. Status transitions per batch: `e_applying` → `e_testing` / `e_fixing_tests` → `e_ci_checking` / `e_fixing_ci` → `e_verifying` → `e_batch_complete`. When last batch completes, workflow advances to `e_enhance_complete`. Fix loop exhaustion → `e_tests_failed` or `e_ci_failed` (retry re-runs from E7). All tests pass.
  - **Scope boundary**: Does NOT implement grant lifecycle (item 19c). Does NOT implement cross-controller parallelism via Scheduler (the orchestration method handles one controller's batches; the Scheduler dispatches across controllers in item 20). Only implements the batch iteration loop and delegation to shared phases.
  - **Files**: `pipeline/enhance_orchestration.rb` (add `run_batch_execution`), `test/batch_execution_test.rb` (new file)
  - **Testing**: Test per Spec § Test Organization — batch apply/test/ci/verify delegation to shared phases, sequential batch chain (batch 1 completes before batch 2 starts), current_batch_id tracking, e_enhance_complete on last batch, e_tests_failed/e_ci_failed status transitions. Stub shared phases. Run `bundle exec rake test`.
  - **Implementation detail — calling shared phases**: All four shared methods accept the kwargs added in 19a. Enhance mode callers pass enhance-specific values. Lambda signatures must match what the shared methods pass — Ruby lambdas enforce strict arity. Example:
    ```ruby
    shared_apply(name,
      apply_prompt_fn: ->(_name, _src, _aj, _dec, staging_dir:) {
        Prompts.e_apply(batch_items, analysis, source, staging_dir)
      },
      applying_status: "e_applying",
      applied_status: "e_batch_applied",  # internal gate
      skipped_status: nil,  # no skip in enhance
      sidecar_dir: @enhance_sidecar_dir,
      staging_subdir: "batches/#{batch_id}/staging",
      sidecar_output_dir: "batches/#{batch_id}",
      analysis_key: :e_analysis,
      phase_label: "Enhance apply"
    )
    ```
    Similarly for `shared_test` (fix_prompt_fn arity: `(_name, _src, _output, _aj, staging_dir:)`), `shared_ci_check`, and `shared_verify` — pass enhance-specific kwargs and match shared method call signatures.

- [ ] 19c. **Integrate LockManager grant lifecycle into batch execution**
  - **Implements**: Spec § LockManager grant lifecycle, § Design Decisions (grant held through entire batch lifecycle).
  - **Completion**: `run_batch_execution` acquires write locks via LockManager (`acquire` with timeout) before each batch's E7→E10 chain. Grant held throughout the chain, renewed after each `claude -p` return. Grant released via `ensure` block on completion or error. `grant_id` passed to all shared phase calls for `safe_write` enforcement. On fix loop exhaustion (`e_tests_failed` / `e_ci_failed`), grant is released; retry re-acquires locks. All tests pass.
  - **Scope boundary**: Does NOT modify LockManager itself (implemented in PLAN-2). Only integrates grant acquisition/renewal/release into the batch execution loop from 19b.
  - **Files**: `pipeline/enhance_orchestration.rb` (update `run_batch_execution`), `test/batch_execution_test.rb` (add grant lifecycle tests)
  - **Testing**: Test per Spec § Test Organization — grant lifecycle: acquired at E7, renewed on claude -p return, released on completion/error via ensure. Grant passed to shared phase calls (`grant_id: grant.id`). e_tests_failed/e_ci_failed with grant release. Retry re-acquires locks. Stub LockManager. Run `bundle exec rake test`.
  - **Implementation detail — grant renewal**: After each `claude_call` returns within a batch, call `@lock_manager.renew(grant_id: grant.id)`. This extends the TTL so long-running batches don't expire.
  - **Implementation detail — grant release via ensure**: Wrap the batch loop body in `begin...ensure` that calls `@lock_manager.release(grant_id: grant.id)` if grant is non-nil.
  - **Implementation detail — grant_id propagation**: Pass `grant_id: grant.id` to all shared phase calls (`shared_apply`, `shared_test`, `shared_ci_check`, `shared_verify`). The shared methods propagate it to `copy_from_staging`, which passes it to `safe_write`.

- [ ] 20. **Add enhance mode server routes**
  - **Implements**: Spec § Integration (HTTP Routes — all `/enhance/*` routes), § Server Layer (enhance routes use Scheduler for dispatch).
  - **Completion**: All enhance routes exist per Spec § HTTP Routes: `POST /enhance/analyze` (starts E0, uses Scheduler if available), `POST /enhance/research` (manual paste or topic rejection via `action` body parameter), `POST /enhance/research/api` (API research), `POST /enhance/decisions` (E5), `POST /enhance/batches/approve` (E6 approval, starts batch execution), `POST /enhance/batches/replan` (E6 rejection with notes), `POST /enhance/retry` (re-run last failed enhance phase), `POST /enhance/retry-tests` (retry batch from E7), `POST /enhance/retry-ci` (retry batch from E7), `GET /enhance/locks` (lock state). Analyze route dispatches via Scheduler when available, falls back to `safe_thread`. Human-gate routes update state directly. All routes use `try_transition` with appropriate guards (including compound guard `["h_complete", "e_enhance_complete"]` for analyze). All route behavior verified.
  - **Scope boundary**: Does NOT add frontend UI (items 22-23). Only adds server-side route handlers.
  - **Files**: `server.rb` (add all `/enhance/*` routes)
  - **Testing**: Route tests via rack-test in a new `test/enhance_routes_test.rb` file. Verify: correct try_transition guards, Scheduler dispatch for analyze, JSON body parameter handling, error responses for invalid states. Run `bundle exec rake test`.
  - **Implementation detail — route patterns**: Follow the existing route pattern in server.rb. Each route: parse JSON body, extract controller name, call `try_transition` with appropriate guard and target status, dispatch work via `safe_thread` or Scheduler. Example:
    ```ruby
    post '/enhance/analyze' do
      content_type :json
      body = JSON.parse(request.body.read)
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
  - **Implementation detail — research route handles paste and reject**: `POST /enhance/research` accepts a JSON body with an `action` field: `"paste"` (with `result` field) or `"reject"`. Example bodies:
    ```json
    {"controller": "posts_controller", "topic_index": 0, "action": "paste", "result": "..."}
    {"controller": "posts_controller", "topic_index": 0, "action": "reject"}
    ```
    The route dispatches to `submit_research` (paste) or `reject_research_topic` (reject) based on the action. This avoids a separate `/enhance/research/reject` endpoint.

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
