# Harden Controller — Spec

## Intent

A standalone Sinatra application that orchestrates parallel `claude -p` calls to analyze, evaluate, and modify Rails controllers through a browser-based UI with human-in-the-loop approval. The pipeline operates in two sequential modes:

1. **Hardening mode** — Security-focused analysis and remediation (authorization, validation, rate limiting). The current pipeline.
2. **Enhance mode** — Research-driven improvement that adds richer analysis, item extraction, synthesis with impact/effort ratings, audit against prior decisions, human review, intelligent batch planning, and parallel write agents with file-level locking. Automatically entered per-controller when hardening completes.

The architecture is task-agnostic — both modes use the same discover-analyze-decide-apply-test-verify structure, but enhance mode inserts research, extraction, synthesis, and audit phases before the human gate, and adds a batch planning phase before apply. Prompts in `prompts.rb` determine what each mode actually does. Designed for a single operator exposed over ngrok.

## Terminology

| Term | Definition |
|---|---|
| **Pipeline** | The singleton `Pipeline` instance (`$pipeline`) that manages all state, threading, and phase orchestration. One per server process. |
| **Controller** | A Rails controller file discovered by glob. The unit of analysis, decision-making, and workflow tracking. |
| **Workflow** | Per-controller state machine tracking progress through pipeline phases. Keyed by controller basename (e.g., `posts_controller`). A workflow progresses through hardening mode first, then enhance mode. |
| **Phase** | A discrete step in the pipeline: discover, analyze, decide, harden, test, ci_check, verify (hardening mode); e_analyze, research, extract, synthesize, audit, e_decide, batch_plan, apply, e_test, e_ci_check, e_verify (enhance mode). Each phase either calls `claude -p`, runs shell commands, calls the Claude Messages API, or awaits human input. |
| **Mode** | Either `hardening` or `enhance`. Determines which phase sequence a controller follows. Per-controller — different controllers can be in different modes simultaneously. |
| **Finding** | A structured analysis result identifying a hardening opportunity (hardening mode). Has severity (high/medium/low), category, scope (controller/module/app), and suggested fix. |
| **Blocker** | A finding with scope `module` or `app` — requires changes beyond the controller file. Displayed separately in the UI; must be dismissed before hardening proceeds. |
| **Item** | A structured improvement opportunity (enhance mode). Has description, impact rating (high/medium/low), effort rating (high/medium/low), and rationale. Items progress through statuses: POSSIBLE → READY → TODO/DEFER/REJECT. |
| **Batch** | A subset of approved TODO items grouped for implementation in a single `claude -p` call (enhance mode). Determined by effort, file overlap, and dependencies. |
| **Grant** | A LockGrant — an active set of read and/or write locks held by a work item (enhance mode). |
| **Work item** | A unit of work dispatched to the Scheduler (enhance mode). Maps to one controller (for read-only phases) or one batch (for write phases). |
| **Sidecar** | A JSON file stored in a `.harden/` (hardening mode) or `.enhance/` (enhance mode) directory adjacent to the target controller. Persists phase outputs across restarts. Both directories are configurable. |
| **Decision** | The operator's response to analysis findings. In hardening mode: `approve`, `selective`, `modify`, or `skip`. In enhance mode: `TODO`, `DEFER`, or `REJECT` per item. |
| **Write target** | A specific file path that a batch's `claude -p` agent will modify (enhance mode). Declared during batch planning, enforced by safe_write. |
| **Contention tier** | A classification (app, module, controller) describing how many agents a file's write lock affects (enhance mode). A mental model for operators, not a system concept. |
| **Query** | An ad-hoc question or finding explanation request. Dispatched to `claude -p` in a background thread; results delivered via SSE. |
| **Safe write** | Path-validated file write. Rejects writes outside `allowed_write_paths` and resolves symlinks to prevent traversal. In enhance mode, also enforces lock grant coverage. |
| **Try transition** | Atomic state machine gate. Checks a guard condition under mutex and transitions workflow status, preventing double-starts. |

## Architecture

### Pipeline Phases

#### Hardening Mode

```
discover → analyze → awaiting_decisions
  → skip ─────────────────────────────────────────────────────→ skipped
  → harden → hardened → test → fix_tests (loop)
      → tested → ci_check → fix_ci (loop)
          → ci_passed → verify → hardening_complete ──→ [enhance mode]
      │                   └──→ ci_failed (retry available)
      └──→ tests_failed (retry available)
```

Discovery is global (one pass over the entire `discovery_glob`). All subsequent phases operate per-controller. The phase chain from `harden` through `verify` executes sequentially within a single thread per controller — `run_hardening` calls `run_testing`, which calls `run_ci_checks`, which calls `run_verification`. The `awaiting_decisions` phase is a human gate that breaks this chain.

When a controller reaches `hardening_complete`, it automatically transitions to enhance mode (beginning at `e_analyze`).

Intermediate gate statuses control phase sequencing:

| Status | Set by | Guards entry to |
|---|---|---|
| `hardened` | `run_hardening` on success | `run_testing` |
| `tested` | `run_testing` on test pass | `run_ci_checks` |
| `ci_passed` | `run_ci_checks` on CI pass | `run_verification` |
| `hardening_complete` | `run_verification` on success | enhance mode entry |

Terminal/retry statuses:

| Status | Meaning | Recovery |
|---|---|---|
| `skipped` | Operator chose `skip` decision | Re-analyze |
| `tests_failed` | Fix loop exhausted `MAX_FIX_ATTEMPTS` | Retry button in UI |
| `ci_failed` | Fix loop exhausted `MAX_CI_FIX_ATTEMPTS` | Retry button in UI |

#### Enhance Mode

```
hardening_complete →
  e_analyze → researching → extracting → synthesizing → auditing →
  e_awaiting_decisions → planning_batches →
  [per batch: applying → e_testing/e_fixing_tests → e_ci_checking/e_fixing_ci → e_verifying] →
  enhance_complete
```

Enhance mode begins automatically per-controller when hardening completes. The `e_` prefix distinguishes enhance mode statuses from hardening mode statuses in the shared state model.

Enhance mode phases operate at two granularities: phases through `planning_batches` are per-controller; phases from `applying` through `e_verifying` are per-batch. Multiple batches for the same controller may execute in parallel if their write targets don't conflict (mediated by the LockManager).

| # | Phase | Granularity | Execution | Write locks | Human | Output |
|---|---|---|---|---|---|---|
| E0 | Analyze | Controller | Parallel | No | No | Intent analysis + research topics |
| E1 | Research | Controller | Mixed | No | Yes (choose method per topic) | Research results |
| E2 | Extract | Controller | Parallel | No | No | POSSIBLE items |
| E3 | Synthesize | Controller | Parallel | No | No | READY items + ratings |
| E4 | Audit | Controller | Parallel | No | No | De-duped READY items |
| E5 | Decide | Controller | — | No | Yes (TODO/DEFER/REJECT) | Approved TODOs |
| E6 | Batch plan | Controller | Per-controller | No | Yes (review batches) | Batch definitions + write targets |
| E7 | Apply | Batch | Parallel* | Yes | No | Modified files |
| E8 | Test/fix | Batch | Sequential | Yes (held) | No | Test results |
| E9 | CI/fix | Batch | Sequential | Yes (held) | No | CI results |
| E10 | Verify | Batch | Sequential | Yes (held) | No | Verification report |

\* Parallel across batches whose write targets don't conflict. Sequential within a batch (apply → test → ci → verify).

##### Phase details

**E0 — Analyze**: Per controller. Read app code and understand the controller's intent, purpose, and current implementation. Uses `claude -p --dangerously-skip-permissions`. Read-only on app code. Parallel across controllers, bounded by `MAX_CLAUDE_CONCURRENCY`. Produces a structured analysis document and a list of research topics as prompts.

Input: controller source, views, routes, related models, hardening verification report.
Output: analysis document + research topic prompts.
Status: `e_analyzing`

**E1 — Research**: Per controller. For each research topic from analysis, the operator chooses one of:
1. **Claude API** — send the prompt to the Claude Messages API (text completion, no tool use). The pipeline makes the HTTP call and stores the response.
2. **Manual paste** — the operator researches the topic externally (claude.ai, documentation, etc.) and pastes the result into the UI.

Research results are stored per-topic. The phase completes for a controller when all topics have responses. This phase is not dispatched to `claude -p` — it's a gathering phase.

Status: `researching`

**E2 — Extract**: Per controller. From all research results, generate a list of POSSIBLE actionable items. Uses `claude -p --dangerously-skip-permissions`. Each item is a concrete improvement.

Input: analysis document + all research results.
Output: POSSIBLE items list.
Status: `extracting`

**E3 — Synthesize**: Per controller. Compare the current implementation to POSSIBLE items. For each item, determine applicability and rate impact (high/medium/low) and effort (high/medium/low). Items already implemented or not applicable are filtered out. Remaining items become READY.

Input: analysis document + POSSIBLE items + controller source code.
Output: READY items list with ratings and rationale.
Status: `synthesizing`

**E4 — Audit**: Per controller. Compare READY items against existing deferred and rejected items from prior runs. De-duplicate — rejected items don't reappear unless the operator explicitly re-enables them. Deferred items are flagged but included.

Input: READY items list + persistent deferred/rejected item store.
Output: de-duped READY items list with prior-decision annotations.
Status: `auditing`

**E5 — Decide**: Human gate. The operator reviews each READY item and categorizes it: **TODO** (approved), **DEFER** (revisit later, persists), or **REJECT** (not wanted, persists). The operator can also propose new items not surfaced by analysis/research.

Status: `e_awaiting_decisions`

**E6 — Batch plan**: From approved TODO items, a `claude -p --dangerously-skip-permissions` call proposes execution batches. Batching considers effort (high-effort items get their own batch), file overlap (items touching the same files batch together), and dependencies (dependent items batch together or are ordered). Each batch definition includes the TODO items, `write_targets` (specific file paths), and estimated effort. The operator reviews and can adjust batches before execution starts.

Input: approved TODO items + analysis document + controller source code.
Output: ordered list of batch definitions with write_targets.
Status: `planning_batches`

**E7–E10 — Apply → Test → CI → Verify**: Per batch. Write locks are acquired at the start of E7 and held through E10 completion. These phases use the shared core orchestration (same as hardening's harden/test/ci/verify) with enhance-mode-specific prompts. On completion or error, all locks for the batch are released.

Status per batch: `applying` → `e_testing` / `e_fixing_tests` → `e_ci_checking` / `e_fixing_ci` → `e_verifying` → `enhance_complete`

### State Model

All state lives in `@state` (a Hash), accessed exclusively through `@mutex.synchronize`. Key structure:

| Field | Type | Description |
|---|---|---|
| `phase` | String | Global pipeline phase: `"idle"`, `"discovering"`, `"ready"` |
| `controllers` | Array | Discovery results (immutable after discovery completes) |
| `workflows` | Hash | Per-controller workflow state, keyed by controller name |
| `errors` | Array | Global error log with timestamps |

Workflow entries contain: `name`, `path`, `full_path`, `mode` (`"hardening"` or `"enhance"`), `status`, `analysis`, `decision`, `hardened`, `test_results`, `ci_results`, `verification`, `error`, `started_at`, `completed_at`, `original_source`.

Enhance mode adds to workflow entries: `e_analysis`, `research_topics`, `research_results`, `possible_items`, `ready_items`, `e_decisions`, `batches`, `batch_workflows` (a Hash of per-batch state keyed by batch ID).

#### Queries Subsystem

Ad-hoc questions and finding explanations are tracked in a separate `@queries` instance variable (an Array), outside `@state` but guarded by the same `@mutex`. Each query entry records the question, the response from `claude -p`, and metadata (controller name, timestamp, type). The `ask_question` and `explain_finding` orchestration methods append to `@queries`.

`MAX_QUERIES` (50) caps the array size. `prune_queries` removes the oldest entries when the cap is exceeded. The `to_json` method merges `@queries` into the serialized output alongside `@state`, so the frontend receives queries via the SSE stream.

### Concurrency Model

- One global `Pipeline` instance with a single `@mutex` guarding `@state`.
- `safe_thread` wraps `Thread.new` with exception handling — sets workflow to `error` on unhandled exception. Dead threads are pruned on each `safe_thread` call.
- `@claude_semaphore` (Mutex) + `@claude_slots` (ConditionVariable) limit concurrent `claude -p` calls to `MAX_CLAUDE_CONCURRENCY` (12).
- `spawn_with_timeout` runs subprocesses in their own process group (`pgroup: true`), sends TERM then KILL on timeout or cancellation.
- `cancel!` and `cancelled?` read/write a boolean without mutex — atomic under CRuby's GVL.

#### LockManager (Enhance Mode)

Thread-safe object that tracks active grants and resolves conflicts. All state guarded by a single `Mutex`. Only used by enhance mode — hardening mode dispatches directly via `safe_thread` with no locking.

**Lock types:**

| Lock | Semantics | Used by |
|---|---|---|
| **Read** | Multiple readers allowed; may target files or directories | Read-only phases (optional), write phases reading analysis output |
| **Write** | Exclusive; must target individual files (not directories) | Apply/test/CI/verify phases modifying app code |

**Conflict rules:**

| Held \ Requested | Read | Write |
|---|---|---|
| **Read** | OK | BLOCKED |
| **Write** | BLOCKED | BLOCKED |

**Path overlap:**

| Active lock | Requested lock | Overlap? |
|---|---|---|
| File A | File A | Yes |
| File A | File B | No |
| Directory D | File within D | Yes |
| File within D | Directory D | Yes |
| Directory D | Directory E | Yes if one contains the other; No if disjoint |

When paths overlap, the compatibility matrix determines whether the request is blocked.

**Over-lock detection:** Write lock requests specifying a directory path are rejected with an `OverLockError`. Write locks must always specify individual files.

**Acquisition semantics:**

- **All-or-nothing.** Request all paths at once. Either all locks are granted or none are. This prevents deadlocks — there is no hold-and-wait condition.
- **Timeout-bounded queuing.** Work items wait up to `LOCK_TIMEOUT` seconds (default 300). If the timeout expires, the item stays queued with an incremented retry count. Items exceeding `MAX_LOCK_RETRIES` move to error state.
- **No lock expansion after dispatch.** Once dispatched, an agent's lock footprint is fixed. If the agent discovers it needs a file it didn't lock, the write is rejected by `safe_write` and the gap is surfaced to the operator. The fix is to refine batch planning prompts, not to weaken enforcement.

**Grant lifecycle:** Grants are held through the entire write lifecycle (apply → test → CI → verify). Released on completion or error. Each grant has a TTL (default 30 minutes) as a safety net — a background reaper releases expired grants.

**Methods:**

```ruby
# Non-blocking. Returns a LockGrant if all paths can be locked, nil otherwise.
# Raises OverLockError if any write path is a directory.
try_acquire(holder:, read_paths: [], write_paths: []) -> LockGrant | nil

# Blocking up to timeout. Returns a LockGrant or raises LockTimeoutError.
acquire(holder:, read_paths: [], write_paths: [], timeout: 300) -> LockGrant

# Release a grant. Idempotent.
release(grant_id:)

# Check what would conflict without acquiring. For diagnostics and UI.
check_conflicts(read_paths: [], write_paths: []) -> [ConflictInfo]

# Snapshot of all active grants. For SSE state broadcast.
active_grants -> [GrantSnapshot]
```

**LockGrant fields:**

| Field | Type | Description |
|---|---|---|
| `id` | String | Unique grant identifier (UUID) |
| `holder` | String | Identifier of the work item holding the grant |
| `read_paths` | Array\<String\> | File and directory paths with read access |
| `write_paths` | Array\<String\> | File paths with write access (no directories) |
| `acquired_at` | Time | When the grant was issued |
| `expires_at` | Time | TTL expiry (default 30 minutes) |
| `released` | Boolean | Whether the grant has been released |

**Contention model:** Every file in the target app belongs at exactly one level in a three-level hierarchy. This is a conceptual model for reasoning about lock contention, not a system concept — the LockManager operates at file granularity.

| Level | Scope | Contention | Examples |
|---|---|---|---|
| **App** | Shared across all modules | High — blocks all agents needing the same file | `app/controllers/concerns/authentication.rb`, `app/views/layouts/application.html.erb` |
| **Module** | Shared within a module | Moderate — blocks agents within the same module | `app/models/blog/post.rb`, module-shared partials and services |
| **Controller** | Private to one controller | Low — only that controller's batches contend | Controller file, its views, its tests, its services |

Rules: categorize by most specific consumer, promote only when a consumer in a different controller appears. Batch planning should identify specific files not broad directories. Shared files are read-heavy write-rare.

#### Scheduler (Enhance Mode)

Manages the work queue and dispatch loop for enhance mode phases. Only used when enhance mode is active. Hardening mode dispatches directly via `safe_thread`.

**Methods:**

```ruby
# Add a work item to the queue.
enqueue(workflow:, phase:, lock_request:, &callback)

# Start the dispatch loop (runs in its own thread).
start

# Graceful shutdown — wait for active agents, don't dispatch new ones.
stop

# Current queue depth (for UI).
queue_depth -> Integer

# Active work items (for UI).
active_items -> [WorkItem]
```

**WorkItem fields:**

| Field | Type | Description |
|---|---|---|
| `id` | String | Unique identifier |
| `workflow` | String | Controller name (phases E0-E6) or batch identifier (phases E7-E10) |
| `phase` | Symbol | `:e_analyze`, `:extract`, `:synthesize`, `:audit`, `:apply`, etc. |
| `lock_request` | LockRequest | Read and write paths needed |
| `status` | Symbol | `:queued`, `:dispatched`, `:completed`, `:error` |
| `queued_at` | Time | When the item entered the queue |
| `dispatched_at` | Time | When dispatched |
| `grant_id` | String | The LockGrant id, once dispatched |

**LockRequest fields:**

| Field | Type | Description |
|---|---|---|
| `read_paths` | Array\<String\> | File and directory paths needing read access |
| `write_paths` | Array\<String\> | File paths needing write access (no directories) |

**Priority ordering:** Near-completion work first: `e_verify > e_test/e_ci > apply > extract/synthesize/audit > e_analyze`. Starvation prevention: work items waiting longer than 10 minutes receive priority escalation.

**Dispatch loop:**

```
loop do
  break if @shutdown

  @queue.sort_by_priority.each do |item|
    next unless claude_slot_available?
    grant = @lock_manager.try_acquire(
      holder: item.id,
      read_paths: item.lock_request.read_paths,
      write_paths: item.lock_request.write_paths
    )
    next unless grant

    item.status = :dispatched
    item.grant_id = grant.id
    safe_thread { run_agent(item, grant) }
  end

  sleep 0.5
end
```

### Server Layer

Sinatra application (`server.rb`) with Puma. Routes dispatch work by calling `try_transition` (to prevent double-starts) then spawning a `safe_thread` for the phase method. State is broadcast to the frontend via SSE (polling `to_json` every 500ms, sending only on change).

Enhance mode routes use the Scheduler for dispatch instead of direct `safe_thread` calls. Human-gate phases (e_decide, batch_plan review) update state directly on operator action without the Scheduler.

### Frontend

Single-file SPA (`index.html`). No build tools. CDN dependencies: marked (Markdown rendering), DOMPurify (sanitization), morphdom (DOM diffing). The `render()` function builds the full UI as an HTML string, then `morphdom` diffs and patches only what changed — preserving scroll positions, focus state, and input values. Per-controller client-side state (`perController`) tracks finding decisions, dismissed blockers, and open/closed sections; this state is not in the SSE payload.

Enhance mode adds UI for: research topic management (API call vs manual paste), item review (TODO/DEFER/REJECT), batch plan review/adjustment, lock contention visualization, and batch progress tracking.

## Code Organization

| File | Purpose |
|---|---|
| `server.rb` | Sinatra routes, authentication, SSE streaming, CORS, CSRF protection, signal handling, startup |
| `pipeline.rb` | `Pipeline` class definition, constants, `try_transition`, `initialize`, `reset!`, `to_json`, state accessors |
| `pipeline/orchestration.rb` | Hardening phase logic: `discover_controllers`, `run_analysis`, `load_existing_analysis`, `submit_decision`, `run_hardening`, `run_testing`, `run_ci_checks`, `run_verification`, `ask_question`, `explain_finding` |
| `pipeline/enhance_orchestration.rb` | Enhance phase logic: `run_enhance_analysis`, `submit_research`, `run_extraction`, `run_synthesis`, `run_audit`, `submit_enhance_decisions`, `run_batch_planning`, `run_batch_apply`, `run_batch_testing`, `run_batch_ci_checks`, `run_batch_verification` |
| `pipeline/claude_client.rb` | `claude_call` (acquire slot, spawn CLI, release slot), `parse_json_response` (strips markdown fences, extracts JSON from prose), `api_call` (Claude Messages API for research) |
| `pipeline/process_management.rb` | `safe_thread`, `cancel!`, `cancelled?`, `shutdown`, `spawn_with_timeout`, `run_all_ci_checks` |
| `pipeline/sidecar.rb` | `sidecar_path`, `ensure_sidecar_dir`, `write_sidecar`, `safe_write`, `derive_test_path`, `default_derive_test_path` |
| `pipeline/lock_manager.rb` | `LockManager` class: `try_acquire`, `acquire`, `release`, `check_conflicts`, `active_grants`, grant reaper |
| `pipeline/scheduler.rb` | `Scheduler` class: `enqueue`, `start`, `stop`, dispatch loop, priority ordering |
| `pipeline/shared_phases.rb` | Shared core orchestration for apply/test/ci/verify used by both modes with mode-specific prompts |
| `prompts.rb` | All `claude -p` prompt templates: hardening (`analyze`, `harden`, `fix_tests`, `fix_ci`, `verify`, `ask`, `explain`) and enhance (`e_analyze`, `research`, `extract`, `synthesize`, `batch_plan`, `e_apply`, `e_fix_tests`, `e_fix_ci`, `e_verify`) |
| `index.html` | Single-file SPA — all CSS, JS, HTML inline. Two-panel layout (sidebar + detail). SSE-driven rendering via morphdom. |
| `Gemfile` | Dependencies: sinatra, sinatra-contrib, puma; test group: minitest, rack-test, rake |
| `Rakefile` | `rake test` — runs all `test/**/*_test.rb` |

### Test Organization

| File | Coverage |
|---|---|
| `test/test_helper.rb` | `PipelineTestCase` base class (tmpdir setup, pipeline init, FD leak detection) |
| `test/orchestration_test_helper.rb` | `OrchestrationTestCase` — filesystem scaffolding, workflow seeding, fixture factories, stub helpers for `claude_call` and `spawn_with_timeout` |
| `test/auth_test.rb` | Authentication (enabled/disabled), CSRF protection, rate limiting, security headers, SSE connection cap, session fixation, CORS |
| `test/claude_concurrency_test.rb` | Semaphore slot acquisition, blocking, cancellation unblocking |
| `test/parse_json_response_test.rb` | JSON parsing: clean, markdown-wrapped, prose-embedded, arrays, garbage, nested braces |
| `test/pipeline_analysis_test.rb` | Analysis happy path, error handling, cancelled pipeline, load from sidecar, edge cases |
| `test/pipeline_hardening_test.rb` | Hardening approve/skip/error, no hardened_source, submit_decision chaining, cancellation |
| `test/pipeline_testing_test.rb` | Test pass/fail/fix loop, status guards, test file detection, spawn errors |
| `test/pipeline_ci_checks_test.rb` | CI pass/fail/fix loop, status guards, controller rewrite on fix |
| `test/pipeline_ci_join_test.rb` | `run_all_ci_checks` thread joining: all pass, one fails, exception handling |
| `test/pipeline_verification_test.rb` | Verification happy path, error, status guard, JSON parse error, prompt content |
| `test/pipeline_discovery_test.rb` | Missing directory, valid controllers, custom glob, custom excludes |
| `test/pipeline_reset_test.rb` | State clearing, cancelled flag, thread joining, race window drainage |
| `test/pipeline_spawn_test.rb` | spawn success/failure/timeout, FD leak prevention |
| `test/sidecar_test.rb` | safe_write path validation (traversal, symlink, nested), derive_test_path, custom allowed_write_paths, custom sidecar_dir, custom test_path_resolver |
| `test/try_transition_test.rb` | `:not_active` guard (no workflow, active, completed, error, unknown), named guards, concurrent transitions |
| `test/sanitize_error_test.rb` | Rails root replacement, realpath replacement, no-path passthrough, non-string input |
| `test/enhance_analysis_test.rb` | Enhance analysis happy path, research topic generation, hardening prerequisite check |
| `test/research_test.rb` | API research path, manual paste, topic completion tracking, API failure recovery |
| `test/extraction_test.rb` | Item extraction from research results, POSSIBLE item generation |
| `test/synthesis_test.rb` | Impact/effort rating, filtering already-implemented items, READY item generation |
| `test/audit_test.rb` | De-duplication against deferred/rejected items, prior-decision annotations |
| `test/batch_planning_test.rb` | Batch grouping by effort/overlap/dependencies, write target declaration |
| `test/batch_execution_test.rb` | Batch apply/test/ci/verify with lock grants, shared core orchestration |
| `test/lock_manager_test.rb` | try_acquire, acquire with timeout, release, conflict detection, over-lock rejection, grant TTL reaper |
| `test/scheduler_test.rb` | Enqueue, dispatch loop, priority ordering, starvation prevention, graceful shutdown |
| `test/api_call_test.rb` | Claude Messages API integration, concurrency limiting, error handling |

## Design Decisions

- **Global singleton pipeline**: A single `$pipeline` instance with one mutex simplifies reasoning about concurrency. All state access goes through `@mutex.synchronize`. This is sufficient for a single-operator tool; distributed locking is a non-goal.

- **Sequential phase chaining within a thread (hardening mode)**: `run_hardening` directly calls `run_testing`, which calls `run_ci_checks`, which calls `run_verification`. This eliminates coordination overhead between phases and ensures the controller file is not modified between phases. The thread holds the workflow from hardening through verification.

- **Scheduler-dispatched phases (enhance mode)**: Enhance mode uses the Scheduler for dispatch instead of direct `safe_thread` calls. This enables parallel batch execution across controllers with lock-based conflict resolution. Read-only phases (E0-E4) are dispatched without locks. Write phases (E7-E10) acquire locks before dispatch.

- **Two-mode sequential pipeline**: Hardening is a prerequisite for enhance. This ensures controllers have a baseline security posture before broader improvements begin. The transition is automatic per-controller — when `run_verification` succeeds in hardening mode, the workflow status advances to `e_analyzing`.

- **`try_transition` as the concurrency gate**: Routes call `try_transition` before spawning threads. The guard-and-transition is atomic under mutex, so concurrent requests for the same controller cannot both succeed. The `:not_active` guard checks against `ACTIVE_STATUSES` — any status representing async work in progress.

- **`cancel!`/`cancelled?` without mutex**: These read/write a single boolean, which is atomic under CRuby's GVL. The `cancelled?` check is polled in `spawn_with_timeout` and `acquire_claude_slot` loops to enable responsive cancellation without mutex contention.

- **Process groups for subprocess management**: `spawn_with_timeout` creates subprocesses with `pgroup: true` and kills via `-TERM`/`-KILL` on the process group. This prevents orphaned child processes (e.g., if `claude -p` spawns sub-processes).

- **Prompt store for debugging**: Prompts sent to `claude -p` are stored in `@prompt_store` (keyed by controller name and phase) and exposed via GET `/pipeline/:name/prompts/:phase`. The route validates the phase against `VALID_PROMPT_PHASES` and returns 404 for unrecognized phases. The `to_json` method enriches each workflow entry with a `prompts` key — a hash mapping stored prompt phases to `true`, indicating which phases have stored prompts available. The frontend uses this to render "Copy Prompt" buttons so the operator can reproduce or debug any phase's claude call.

- **SSE with change detection**: The `/events` endpoint polls `to_json` every 500ms and sends only when the JSON differs from the last sent value. `to_json` itself is cached for 100ms to avoid redundant serialization under concurrent SSE connections.

- **Morphdom for efficient DOM updates**: The frontend renders the entire UI as a string on every state change, then uses morphdom to diff against the live DOM. The `onBeforeElUpdated` callback skips focused `INPUT`/`TEXTAREA` elements to preserve cursor position. This eliminates manual DOM manipulation while preserving user interaction state.

- **Blockers as a UI concept, not a pipeline concept**: Findings with scope `module` or `app` are displayed as "out-of-scope blockers" in the UI. The pipeline itself does not enforce blocker dismissal — this is a client-side gate. All undismissed blockers must be dismissed before the "Harden" button is enabled, but this logic lives entirely in `index.html`.

- **Path-validated writes via `safe_write`**: All file writes go through `safe_write` which resolves paths via `File.realpath` and checks against `allowed_write_paths`. This prevents directory traversal and symlink escapes. In enhance mode, `safe_write` additionally validates grant coverage (see Validation Logic).

- **Configurable pipeline with per-mode defaults**: `Pipeline.new` accepts keyword arguments for `rails_root`, `sidecar_dir`, `enhance_sidecar_dir`, `allowed_write_paths`, `enhance_allowed_write_paths`, `discovery_glob`, `discovery_excludes`, and `test_path_resolver`. Hardening and enhance modes have independent sidecar directories and write path allowlists.

- **CSRF via `X-Requested-With` header**: Instead of token-based CSRF, all POST routes (except `/auth`) require the `X-Requested-With: XMLHttpRequest` header. This works because the SPA makes all state-changing requests via `fetch()` which attaches the header, and the Same-Origin Policy prevents cross-origin `fetch` from setting custom headers.

- **Rate limiting on `/auth`**: Failed authentication attempts are tracked per IP (using rightmost `X-Forwarded-For` entry for ngrok). After `AUTH_MAX_ATTEMPTS` (5) failures within `AUTH_WINDOW` (900s), further attempts receive 429. Successful login resets the counter. The tracking map is pruned to prevent unbounded growth (`AUTH_MAX_TRACKED_IPS` = 10,000).

- **Session fixation prevention**: The session ID is regenerated on successful authentication via `env["rack.session.options"][:renew] = true`.

- **Error sanitization**: `sanitize_error` replaces `@rails_root` and its `File.realpath` with `<project>` in all error messages, preventing path disclosure to the browser.

- **CI checks run in parallel threads**: `run_all_ci_checks` spawns one thread per CI check (rubocop, brakeman, bundler-audit, importmap-audit) and joins all. If any thread raises, the others are killed and joined before re-raising.

- **Fix loops are bounded**: Test fixes and CI fixes each have a maximum retry count (`MAX_FIX_ATTEMPTS` = 2, `MAX_CI_FIX_ATTEMPTS` = 2). If fixes do not resolve failures within the limit, the workflow enters `tests_failed` or `ci_failed` status with a retry button in the UI.

- **Sidecar files enable resumability**: Discovery scans for existing sidecar files and exposes their presence and timestamps. Hardening sidecars (`.harden/`) store analysis, hardened code, test results, CI results, and verification. Enhance sidecars (`.enhance/`) store analysis, research, items, decisions, batches, and per-batch results. The frontend offers "Use Existing" to load a prior analysis without re-running claude.

- **Shared core orchestration for write phases**: Apply/test/ci/verify logic is extracted into shared helpers that both hardening and enhance modes call with different prompts and state keys. This avoids duplication while keeping the modes' prompt templates and sidecar formats independent.

- **LockManager uses all-or-nothing acquisition**: Deadlock prevention without lock ordering. A work item requests all needed paths at once — either all are granted or none. Combined with the Scheduler's dispatch loop, this ensures no hold-and-wait condition.

- **Grant TTL as safety net**: Each grant expires after 30 minutes. A background reaper releases expired grants. This handles edge cases where a thread dies without releasing (e.g., `Thread.kill` from signal handler). Normal operation releases grants explicitly via `ensure` blocks.

- **Research via Messages API, not `claude -p`**: Research prompts may benefit from web access, but `--dangerously-skip-permissions` would bypass all tool permissions. The Claude Messages API provides text completion without tool use, which is what research needs. A separate concurrency limit (`MAX_API_CONCURRENCY` = 20) keeps API calls from starving CLI calls.

- **`shutdownServer()` uses `innerHTML`**: This is intentional — it is a terminal state with no further renders. Converting to morphdom would add complexity with no benefit.

- **Port fallback with TOCTOU retry**: `find_open_port` checks the preferred port, falling back to an OS-assigned port. If the port is taken between check and bind, up to `MAX_PORT_RETRIES` (3) retries occur.

## Validation Logic

### JSON Response Parsing

`parse_json_response` handles three response formats from `claude -p`:

1. Clean JSON — parsed directly.
2. Markdown-fenced JSON — strips leading `` ```json `` and trailing `` ``` `` before parsing.
3. JSON embedded in prose — locates the first `{` and last `}` in the response and parses the substring between them.

The method raises if the parsed result is not a Hash (rejects arrays). If no valid JSON object is found, it raises with the first 200 characters of the response for debugging.

### Path Validation

`safe_write` and `write_sidecar` resolve the target path's directory via `File.realpath` and verify it starts with the realpath of at least one entry in `allowed_write_paths` (relative to `rails_root`). This catches:

- Directory traversal via `../`
- Symlink escapes (symlinks inside allowed directories pointing outside)
- Absolute paths outside the project

#### Grant Enforcement (Enhance Mode)

When a `grant_id` is provided to `safe_write`, two additional checks apply:

1. **Grant validity.** A valid, non-expired, non-released `LockGrant` must exist for the given `grant_id`.
2. **Grant coverage.** The target path must appear in the grant's `write_paths` (exact match).

When `grant_id` is nil, these checks are skipped (hardening mode / legacy behavior). If any check fails, the write is rejected with a `LockViolationError`.

The path allowlist and grant coverage serve as independent safety layers: the allowlist catches bugs in grant computation, and grants catch bugs in the allowlist configuration.

### State Machine Guards

`try_transition` enforces two guard types:

- **`:not_active`** — succeeds if no workflow exists for the controller, or if the existing workflow's status is not in `ACTIVE_STATUSES`. Creates or resets the workflow. Prevents double-starts.
- **Named guard** (e.g., `"awaiting_decisions"`, `"hardening_complete"`) — succeeds only if the workflow's current status exactly matches the guard string. Used for phase-specific transitions (e.g., decisions can only be submitted when status is `awaiting_decisions`; enhance analysis can only start when status is `hardening_complete`).

Both guards operate atomically under `@mutex`. On success, the status is updated and error is cleared. On failure, a descriptive error string is returned.

## Integration

### External Dependencies

- **`claude` CLI**: All automated phases invoke `claude -p <prompt>` via `spawn_with_timeout`. The CLI must be installed and authenticated. Concurrent calls are bounded by `MAX_CLAUDE_CONCURRENCY` (12).
- **Claude Messages API**: Research phase (enhance mode) uses the Messages API for text completion. Requires `ANTHROPIC_API_KEY`. Concurrent calls are bounded by `MAX_API_CONCURRENCY` (20).
- **Rails test runner**: `bin/rails test [file]` for test execution. Falls back to full suite if no controller-specific test file exists.
- **CI tools**: RuboCop (`bin/rubocop`), Brakeman (`bin/brakeman`), bundler-audit (`bin/bundler-audit`), importmap audit (`bin/importmap audit`). All run via `spawn_with_timeout` with `chdir` set to `rails_root`.
- **CDN libraries** (frontend): marked 15.0.7, DOMPurify 3.2.5, morphdom 2.7.4 — loaded with SRI integrity hashes.

### Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `RAILS_ROOT` | `.` | Path to the target Rails application |
| `HARDEN_PASSCODE` | Auto-generated if binding non-localhost | Login passcode for browser UI |
| `PORT` | `4567` | Server port (falls back to random if in use) |
| `SESSION_SECRET` | Auto-generated | Rack session encryption key |
| `CORS_ORIGIN` | None | Enable CORS for a specific origin (local dev) |
| `ANTHROPIC_API_KEY` | None | Claude Messages API key for research phase (enhance mode). If unset, only manual paste is available. |

### HTTP Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/` | Serve `index.html` (or login page if auth enabled and not authenticated) |
| POST | `/auth` | Authenticate with passcode |
| POST | `/auth/logout` | Clear session |
| GET | `/pipeline/status` | JSON state snapshot |
| POST | `/pipeline/analyze` | Start hardening analysis for a controller |
| POST | `/pipeline/load-analysis` | Load existing hardening analysis from sidecar |
| POST | `/pipeline/reset` | Reset pipeline and re-discover |
| POST | `/decisions` | Submit hardening finding decisions for a controller |
| POST | `/ask` | Ad-hoc question about a controller |
| POST | `/explain/:finding_id` | Explain a specific finding |
| POST | `/pipeline/retry-tests` | Retry testing from `tests_failed` |
| POST | `/pipeline/retry-ci` | Retry CI from `ci_failed` |
| POST | `/pipeline/retry` | Retry from `error` (re-runs analysis) |
| POST | `/shutdown` | Graceful server shutdown |
| GET | `/events` | SSE stream of pipeline state |
| GET | `/pipeline/:name/prompts/:phase` | Retrieve stored prompt for debugging (phase must be in `VALID_PROMPT_PHASES`) |
| POST | `/enhance/analyze` | Start enhance analysis for a controller (requires `hardening_complete`) |
| POST | `/enhance/research` | Submit research result (API or manual paste) for a topic |
| POST | `/enhance/research/api` | Trigger Claude API research for a topic |
| POST | `/enhance/decisions` | Submit enhance item decisions (TODO/DEFER/REJECT) |
| POST | `/enhance/batches/approve` | Approve batch plan and start execution |
| POST | `/enhance/batches/adjust` | Modify batch plan (move items, split/merge) |
| POST | `/enhance/retry-tests` | Retry batch testing from `e_testing` failure |
| POST | `/enhance/retry-ci` | Retry batch CI from `e_ci_checking` failure |
| GET | `/enhance/locks` | Current lock state and queue depth |

### Persistence (Enhance Mode)

Each enhance phase writes structured output to the `.enhance/` sidecar directory:

```
.enhance/
  <controller_name>/
    analysis.json          # E0 output
    research/
      <topic_slug>.md      # E1 output (one file per topic)
    extract.json           # E2 output
    synthesize.json        # E3 output
    audit.json             # E4 output
    decisions.json         # E5 output
    batches.json           # E6 output
    batches/
      <batch_id>/
        apply.json         # E7 output
        test_results.json  # E8 output
        ci_results.json    # E9 output
        verification.json  # E10 output
  decisions/
    deferred.json          # Cross-run: all deferred items across all controllers
    rejected.json          # Cross-run: all rejected items across all controllers
```

**Resume on restart:** On discovery, the pipeline scans both `.harden/` and `.enhance/` sidecar directories. For each controller, it determines the last completed phase by checking which output files exist and sets the workflow status accordingly.

Resume rules:
- If `.harden/verification.json` exists → status is `hardening_complete` (ready for enhance).
- If `.enhance/analysis.json` exists but `research/` is incomplete → status is `researching`.
- If `.enhance/decisions.json` exists but `batches.json` does not → status is `planning_batches`.
- If a batch's `apply.json` exists but `test_results.json` does not → that batch resumes at testing.
- Deferred and rejected items in `.enhance/decisions/` are loaded at startup for the audit phase.

**Cross-run persistence:** `decisions/deferred.json` and `decisions/rejected.json` persist across runs. Each entry includes item description, controller name, decision, timestamp, and optional operator notes.

### Pipeline Configuration

`Pipeline.new` accepts keyword arguments to customize both modes:

```ruby
Pipeline.new(
  # Shared options
  rails_root: ".",
  discovery_glob: "app/controllers/**/*_controller.rb",
  discovery_excludes: ["application_controller"],
  test_path_resolver: nil,

  # Hardening mode options
  sidecar_dir: ".harden",
  allowed_write_paths: ["app/controllers"],

  # Enhance mode options
  enhance_sidecar_dir: ".enhance",
  enhance_allowed_write_paths: ["app/controllers", "app/views", "app/models",
                                "app/services", "test/"],
  lock_manager: LockManager.new,
  scheduler: Scheduler.new(lock_manager:, claude_semaphore:),
  api_key: ENV["ANTHROPIC_API_KEY"]
)
```

## Failure Modes and Recovery

### Hardening Mode

- **Agent crash**: `safe_thread` catches exceptions and sets workflow status to `error`. Retry button in UI re-runs analysis.
- **Test/CI fix loop exhaustion**: Workflow enters `tests_failed` or `ci_failed`. Retry button available.

### Enhance Mode

- **Agent crash mid-batch**: `safe_thread` catches exceptions and sets workflow to `error`. Grant is released via `ensure` block. Retry button re-runs the batch from apply.
- **Lock leak (grant not released)**: Grant TTL (30 minutes) expires. Background reaper releases it. Safety net only — normal operation releases explicitly.
- **Deadlock prevention**: All-or-nothing acquisition eliminates hold-and-wait. Starvation handled by priority escalation after 10 minutes.
- **Incomplete write targets**: `safe_write` rejects writes to unlocked files with `LockViolationError`. Surfaces batch planning deficiencies — fix is to refine prompts.
- **Research phase failure**: API call failure reverts the topic to "pending". Operator can retry (API) or paste manually. Research does not block other controllers.
- **Sidecar corruption**: Malformed sidecar file on resume → phase treated as incomplete and re-run. Phase outputs are idempotent.

## Non-Goals

- **Distributed or multi-user operation**: Single-process, single-operator tool. No Redis, database, or multi-server coordination.
- **Persistent lock state or work queues**: All state beyond sidecar files is in-memory. Pipeline restarts clear workflows, threads, and locks. On restart, no agents are running, so no locks are needed.
- **Sub-file locking or automatic dependency inference**: Locks operate at file level. Write targets come from batch planning output. Manual declaration is intentional.
- **Lock escalation**: Once dispatched, an agent's lock set is fixed.
- **Prompt template content**: This spec describes the pipeline infrastructure. Prompt design is a separate concern in `prompts.rb`.
- **UI layout details**: This spec describes what data the UI consumes (workflow state, lock state, queue depth, queries, errors) and how it renders (morphdom, SSE). Visual design and component structure are implementation details of `index.html`.
- **Screen-level scheduling**: All scheduling operates at controller (or batch) granularity.
