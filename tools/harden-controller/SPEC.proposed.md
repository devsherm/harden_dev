# Pipeline Spec

A controller-level pipeline that orchestrates parallel `claude -p` agents to analyze, research, plan, and implement improvements to a Rails application. File-level locking enables parallel write agents. Persistent phase outputs enable cross-session resumability.

This spec covers the full pipeline flow, locking infrastructure, persistence model, and integration points. It does not cover prompt templates or UI layout.

---

## 1. Intent

The harden-controller pipeline currently runs one `claude -p` agent at a time per phase per controller. The phases are security-focused (analyze, harden, test, verify), but the architecture is task-agnostic.

This spec extends the pipeline in three ways:

1. **Richer phase model.** Analysis alone is insufficient for feature-level work. The pipeline adds research gathering, item extraction, synthesis with impact/effort ratings, audit against prior decisions, human review, and intelligent batch planning before any code changes happen.

2. **Parallel write agents with file-level locking.** Multiple controllers' write phases can run concurrently. A LockManager prevents file collisions. A Scheduler dispatches work items when locks and Claude slots are available.

3. **Persistent phase outputs.** Each phase writes structured output to a sidecar directory. On restart, the pipeline reads existing outputs and resumes from the last completed phase per controller. Deferred and rejected items persist across runs.

---

## 2. Glossary

| Term | Definition |
|---|---|
| **Controller** | A Rails controller file and its associated views, tests, and services. The unit of analysis and scheduling. |
| **Phase** | A discrete step in the pipeline. Each phase has defined inputs, outputs, and lock requirements. |
| **Work item** | A unit of work dispatched to the Scheduler. Maps to one controller (for read-only phases) or one batch (for write phases). |
| **Batch** | A subset of approved TODO items grouped for implementation in a single `claude -p` call. Determined by effort, file overlap, and dependencies. |
| **Grant** | A LockGrant — an active set of read and/or write locks held by a work item. |
| **Sidecar directory** | A directory (default `.pipeline/`) adjacent to each target controller that stores phase outputs as structured files. |
| **Write target** | A specific file path that a batch's `claude -p` agent will modify. Declared during batch planning, enforced by safe_write. |
| **Contention tier** | A classification (app, module, controller) describing how many agents a file's write lock affects. A mental model for operators, not a system concept. |

---

## 3. Pipeline Phases

### Phase summary

```
discover → analyze → research → extract → synthesize → audit →
  decide (human) → batch_plan (human review) →
  apply → test/fix → ci/fix → verify → complete
```

### Phase table

| # | Phase | Granularity | Execution | Write locks | Human | Output |
|---|---|---|---|---|---|---|
| 0 | Discover | Global | Single | No | No | Controller list |
| 1 | Analyze | Controller | Parallel | No | No | Intent analysis |
| 2 | Research | Controller | Mixed | No | Yes (choose method per topic) | Research results |
| 3 | Extract | Controller | Parallel | No | No | Possible items |
| 4 | Synthesize | Controller | Parallel | No | No | READY items + ratings |
| 5 | Audit | Controller | Parallel | No | No | De-duped READY items |
| 6 | Decide | Controller | — | No | Yes (TODO/DEFER/REJECT) | Approved TODOs |
| 7 | Batch plan | Controller | Per-controller | No | Yes (review batches) | Batch definitions + write targets |
| 8 | Apply | Batch | Parallel* | Yes | No | Modified files |
| 9 | Test/fix | Batch | Sequential | Yes (held) | No | Test results |
| 10 | CI/fix | Batch | Sequential | Yes (held) | No | CI results |
| 11 | Verify | Batch | Sequential | Yes (held) | No | Verification report |

\* Parallel across batches whose write targets don't conflict. Sequential within a batch (apply → test → ci → verify).

### Phase details

#### Phase 0: Discover

Enumerate controllers from `discovery_glob`. Existing behavior, unchanged. Initializes the controller list and detects existing sidecar state for resumability.

Status: `idle` → `discovering` → `ready`

#### Phase 1: Analyze

Per controller: read app code and understand the controller's intent, purpose, and current implementation. Uses `claude -p --dangerously-skip-permissions`. Read-only on app code. Parallel across controllers, bounded by `MAX_CLAUDE_CONCURRENCY`.

Input: controller source, views, routes, related models.
Output: structured analysis document — what the controller does, what screens it serves, how it relates to other controllers.

Status per controller: `analyzing`

#### Phase 2: Research

Per controller: the analysis phase produces a list of research topics as prompts (e.g., "What pagination patterns do production Rails blog applications use?"). For each topic, the operator chooses one of:

1. **Claude API** — send the prompt to the Claude Messages API (text completion, no tool use). The pipeline makes the HTTP call and stores the response.
2. **Manual paste** — the operator researches the topic externally (claude.ai, documentation, etc.) and pastes the result into the UI.

Research results are stored per-topic. The phase completes for a controller when all topics have responses.

This phase is not dispatched to `claude -p` — it's a gathering phase. The pipeline presents prompts and collects responses.

Status per controller: `researching`

#### Phase 3: Extract

Per controller: from all research results, generate a list of POSSIBLE actionable items. Uses `claude -p --dangerously-skip-permissions`. Each item is a concrete improvement that could be made to the controller.

Input: analysis document + all research results for the controller.
Output: list of possible items, each with a short description.

Status per controller: `extracting`

#### Phase 4: Synthesize

Per controller: compare the current implementation to the possible items. For each item, determine whether it's applicable and rate its impact (high/medium/low) and effort (high/medium/low). Items that are already implemented or not applicable are filtered out. Remaining items become READY items.

Input: analysis document + possible items list + controller source code.
Output: READY items list, each with description, impact rating, effort rating, and rationale.

Status per controller: `synthesizing`

#### Phase 5: Audit

Per controller: compare READY items against existing deferred and rejected items from prior runs. De-duplicate — if an item was previously rejected, it should not reappear unless the operator explicitly re-enables it. Items previously deferred are flagged but included.

Input: READY items list + persistent deferred/rejected item store.
Output: de-duped READY items list with prior-decision annotations.

Status per controller: `auditing`

#### Phase 6: Decide

Human gate. The operator reviews each READY item and categorizes it:

- **TODO** — approved for implementation.
- **DEFER** — not now, but worth revisiting later. Persists for future audit phases.
- **REJECT** — not wanted. Persists for future audit phases.

The operator can also propose new items not surfaced by analysis/research.

Status per controller: `awaiting_decisions`

#### Phase 7: Batch plan

From approved TODO items, a `claude -p --dangerously-skip-permissions` call proposes execution batches. The batching considers:

- **Effort** — high-effort items get their own batch. Low-effort items can be grouped.
- **File overlap** — items touching the same files should batch together (avoids sequential lock contention on those files).
- **Dependencies** — if item B depends on item A's changes, they go in the same batch or A's batch is ordered first.

Each batch definition includes:
- The TODO items in the batch.
- The `write_targets` — specific file paths the batch will modify.
- Estimated effort.

The operator reviews and can adjust batches (move items between batches, split/merge batches) before execution starts.

Input: approved TODO items + analysis document + controller source code.
Output: ordered list of batch definitions, each with write_targets.

Status per controller: `planning_batches`

#### Phases 8-11: Apply → Test → CI → Verify

Per batch. Write locks are acquired at the start of phase 8 and held through phase 11 completion.

**Apply** (phase 8): `claude -p --dangerously-skip-permissions` implements the batch's TODO items. All file writes go through `safe_write(path, content, grant_id:)` which enforces lock coverage.

**Test** (phase 9): run the controller's test file. If tests fail, a fix loop runs (up to `MAX_FIX_ATTEMPTS`). Locks remain held.

**CI** (phase 10): run CI checks (RuboCop, Brakeman, etc.). If checks fail, a fix loop runs (up to `MAX_CI_FIX_ATTEMPTS`). Locks remain held.

**Verify** (phase 11): compare original and modified code. Produce a verification report.

On completion (success or error), all locks for the batch are released.

Status per batch: `applying` → `testing` / `fixing_tests` → `ci_checking` / `fixing_ci` → `verifying` → `complete`

---

## 4. Contention Model

Every file in the target app belongs at exactly one level in a three-level hierarchy. This is a conceptual model for reasoning about lock contention, not a system concept — the LockManager operates at file granularity.

### Levels

| Level | Scope | Contention | Examples |
|---|---|---|---|
| **App** | Shared across all modules | High — blocks all merge agents needing the same file | `app/controllers/concerns/authentication.rb`, `app/views/layouts/application.html.erb` |
| **Module** | Shared within a module | Moderate — blocks merge agents within the same module | `app/models/blog/post.rb`, module-shared partials and services |
| **Controller** | Private to one controller | Low — only that controller's batches contend | Controller file, its views, its tests, its services |

### Rules

1. **Categorize by most specific consumer.** If only one controller uses a partial, it's controller-scoped. Promote only when a consumer in a different controller appears.
2. **Promotion widens contention.** Moving a file from controller scope to module scope means merge agents for different controllers may contend on it.
3. **Declare narrowly.** Batch planning should identify specific files, not broad directories. The LockManager rejects directory-level write locks (`OverLockError`).
4. **Shared files are read-heavy, write-rare.** Files at higher tiers are read by many agents but modified rarely. Read locks don't conflict with reads, so shared files only cause contention during write phases.

---

## 5. Lock System

### Lock types

| Lock | Semantics | Used by |
|---|---|---|
| **Read** | Multiple readers allowed; may target files or directories | Read-only phases (optional), write phases reading analysis output |
| **Write** | Exclusive; must target individual files (not directories) | Apply/test/CI/verify phases modifying app code |

### Conflict rules

| Held \ Requested | Read | Write |
|---|---|---|
| **Read** | OK | BLOCKED |
| **Write** | BLOCKED | BLOCKED |

### Path overlap

| Active lock | Requested lock | Overlap? |
|---|---|---|
| File A | File A | Yes |
| File A | File B | No |
| Directory D | File within D | Yes |
| File within D | Directory D | Yes |
| Directory D | Directory E | Yes if one contains the other; No if disjoint |

When paths overlap, the compatibility matrix determines whether the request is blocked.

### Over-lock detection

Write lock requests specifying a directory path are rejected with an `OverLockError`. Write locks must always specify individual files.

### Acquisition semantics

**All-or-nothing.** Request all paths at once. Either all locks are granted or none are. This prevents deadlocks — there is no hold-and-wait condition.

**Timeout-bounded queuing.** Work items wait up to `LOCK_TIMEOUT` seconds (default 300). If the timeout expires, the item stays queued with an incremented retry count. Items exceeding `MAX_LOCK_RETRIES` move to error state.

**No lock expansion after dispatch.** Once dispatched, an agent's lock footprint is fixed. If the agent discovers it needs a file it didn't lock, the write is rejected by `safe_write` and the gap is surfaced to the operator. The fix is to refine batch planning prompts, not to weaken enforcement.

### Grant lifecycle

Grants are held through the entire write lifecycle (apply → test → CI → verify). Released on completion or error. Each grant has a TTL (default 30 minutes) as a safety net — a background reaper releases expired grants.

---

## 6. LockManager Interface

Thread-safe object that tracks active grants and resolves conflicts. All state guarded by a single `Mutex`.

### Methods

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

### LockGrant fields

| Field | Type | Description |
|---|---|---|
| `id` | String | Unique grant identifier (UUID) |
| `holder` | String | Identifier of the work item holding the grant |
| `read_paths` | Array\<String\> | File and directory paths with read access |
| `write_paths` | Array\<String\> | File paths with write access (no directories) |
| `acquired_at` | Time | When the grant was issued |
| `expires_at` | Time | TTL expiry (default 30 minutes) |
| `released` | Boolean | Whether the grant has been released |

---

## 7. Scheduler Interface

The Scheduler manages the work queue and dispatch loop.

### Methods

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

### WorkItem fields

| Field | Type | Description |
|---|---|---|
| `id` | String | Unique identifier |
| `workflow` | String | Controller name (phases 1-7) or batch identifier (phases 8-11) |
| `phase` | Symbol | `:analyze`, `:extract`, `:synthesize`, `:audit`, `:apply`, etc. |
| `lock_request` | LockRequest | Read and write paths needed |
| `status` | Symbol | `:queued`, `:dispatched`, `:completed`, `:error` |
| `queued_at` | Time | When the item entered the queue |
| `dispatched_at` | Time | When dispatched |
| `grant_id` | String | The LockGrant id, once dispatched |

### LockRequest fields

| Field | Type | Description |
|---|---|---|
| `read_paths` | Array\<String\> | File and directory paths needing read access |
| `write_paths` | Array\<String\> | File paths needing write access (no directories) |

### Priority ordering

Near-completion work first: `verify > test/ci > apply > extract/synthesize/audit > analyze`. This prioritizes finishing in-progress work over starting new work, reducing the number of active lock holders.

Starvation prevention: work items waiting longer than 10 minutes receive priority escalation.

### Dispatch loop

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

---

## 8. Safe-Write Enforcement

`safe_write` is the write gate. It currently validates paths against `allowed_write_paths`. The locking system adds a second layer.

### Enhanced signature

```ruby
safe_write(path, content, grant_id: nil)
```

### Three checks (all must pass)

1. **Path allowlist.** Path is within `allowed_write_paths` (existing behavior).
2. **Grant validity.** When `grant_id` is provided, a valid, non-expired, non-released `LockGrant` exists for that id.
3. **Grant coverage.** The target path appears in the grant's `write_paths` (exact match).

When `grant_id` is nil, checks 2 and 3 are skipped (legacy mode).

If any check fails, the write is rejected with a `LockViolationError`.

### Default allowed_write_paths

The default expands to cover the full write target surface:

```ruby
["app/controllers", "app/views", "app/models", "app/services", "test/"]
```

The path allowlist is a coarse safety net. Grant coverage is the fine-grained enforcement. Both layers exist because the allowlist catches bugs in grant computation, and grants catch bugs in the allowlist configuration.

---

## 9. Persistence and Resumability

### Phase output storage

Each phase writes structured output to the sidecar directory. Default sidecar directory: `.pipeline/` (configurable via `sidecar_dir`).

```
.pipeline/
  <controller_name>/
    analysis.json          # Phase 1 output
    research/
      <topic_slug>.md      # Phase 2 output (one file per topic)
    extract.json           # Phase 3 output
    synthesize.json        # Phase 4 output
    audit.json             # Phase 5 output
    decisions.json         # Phase 6 output
    batches.json           # Phase 7 output
    batches/
      <batch_id>/
        apply.json         # Phase 8 output
        test_results.json  # Phase 9 output
        ci_results.json    # Phase 10 output
        verification.json  # Phase 11 output
  decisions/
    deferred.json          # Cross-run: all deferred items across all controllers
    rejected.json          # Cross-run: all rejected items across all controllers
```

### Resume on restart

On discovery (phase 0), the pipeline scans sidecar directories for existing outputs. For each controller, it determines the last completed phase by checking which output files exist. The controller's status is set to the next phase after the last completed one.

Rules:
- If `analysis.json` exists but `research/` is incomplete → status is `researching`.
- If `decisions.json` exists but `batches.json` does not → status is `planning_batches`.
- If a batch's `apply.json` exists but `test_results.json` does not → that batch resumes at testing.
- Deferred and rejected items in `.pipeline/decisions/` are loaded at startup for the audit phase.

### Cross-run persistence

The `decisions/deferred.json` and `decisions/rejected.json` files persist across pipeline runs. When the pipeline runs again (e.g., after a code update or new research), the audit phase reads these files to prevent previously rejected items from resurfacing.

Each entry includes:
- Item description (for matching)
- Controller name
- Decision (deferred or rejected)
- Timestamp
- Operator notes (optional)

---

## 10. Research Backend

The research phase uses the Claude Messages API for automated research. This is the only phase that uses the API directly — all other automated phases use `claude -p --dangerously-skip-permissions`.

### Why not `claude -p` for research

`claude -p` triggers tool-use permissions for web access. Research prompts often require web browsing (documentation, best practices, examples). Using `--dangerously-skip-permissions` would bypass all tool permissions, not just web access. The Claude Messages API avoids this — it's a text-completion call with no tool use.

### Integration

The `claude_client` module gains a second method:

```ruby
# Existing: run claude CLI with tool access
claude_call(prompt, skip_permissions: false) -> String

# New: direct API call, text completion only, no tools
api_call(prompt, model: "claude-sonnet-4-6") -> String
```

`api_call` uses the Claude Messages API via HTTP. It respects a separate concurrency limit (`MAX_API_CONCURRENCY`, default 20) since API calls are cheaper and faster than CLI calls.

The `ANTHROPIC_API_KEY` environment variable must be set for research to use the API path. If unset, only manual paste is available.

---

## 11. Integration with Existing Pipeline

### Backward compatibility

When `lock_manager` is nil (the default), the pipeline operates in legacy mode:
- No locking, no scheduler, no grant enforcement.
- `safe_write` skips grant checks (existing behavior).
- Phases dispatch directly via `safe_thread`.

This preserves the current hardening workflow unchanged.

### Pipeline initialization

```ruby
Pipeline.new(
  # Existing options
  rails_root: ".",
  sidecar_dir: ".pipeline",           # Changed default from ".harden"
  allowed_write_paths: ["app/controllers", "app/views", "app/models",
                        "app/services", "test/"],
  discovery_glob: "app/controllers/**/*_controller.rb",
  discovery_excludes: ["application_controller"],
  test_path_resolver: nil,

  # New options
  lock_manager: LockManager.new,       # nil for legacy mode
  scheduler: Scheduler.new(lock_manager:, claude_semaphore:),
  api_key: ENV["ANTHROPIC_API_KEY"]    # nil disables API research path
)
```

### New workflow statuses

The status progression adds new states:

```
idle → discovering → ready →
  analyzing → researching → extracting → synthesizing → auditing →
  awaiting_decisions → planning_batches →
  [per batch: applying → testing/fixing_tests → ci_checking/fixing_ci → verifying] →
  complete
```

`ACTIVE_STATUSES` expands to include the new phase statuses.

### Route structure

Routes that dispatch automated phases use the scheduler when available:

```ruby
post '/pipeline/analyze/:controller' do
  if $pipeline.scheduler
    $pipeline.scheduler.enqueue(
      workflow: params[:controller],
      phase: :analyze,
      lock_request: LockRequest.new(read_paths: [...], write_paths: [])
    )
  else
    safe_thread { $pipeline.run_analysis(params[:controller]) }
  end
end
```

Human-gate phases (decide, batch_plan review) don't use the scheduler — they update state directly on operator action.

### State broadcast

`to_json` includes lock and scheduler state for SSE/UI:

```json
{
  "phase": "ready",
  "controllers": [...],
  "workflows": {...},
  "locks": {
    "active_grants": [...],
    "queue_depth": 5,
    "active_items": [...]
  }
}
```

---

## 12. Failure Modes and Recovery

### Agent crash mid-execution

The `safe_thread` wrapper catches exceptions and sets workflow status to `error`. On any exit path, the grant is released via `ensure` block.

### Lock leak (grant not released)

Each grant has a TTL (default 30 minutes). A background reaper releases expired grants. This is a safety net — normal operation releases grants explicitly.

### Deadlock prevention

All-or-nothing acquisition eliminates hold-and-wait. No lock ordering requirement. Starvation handled by priority escalation after 10 minutes.

### Incomplete write targets

If a batch agent attempts to write to a file not in its grant, `safe_write` rejects the write with `LockViolationError`. The agent records the gap. This surfaces batch planning deficiencies — the fix is to refine batch planning prompts.

### Research phase failure

If an API call fails, the topic reverts to "pending" and the operator can retry (API) or paste manually. Research does not block other controllers.

### Sidecar corruption

If a sidecar file is malformed on resume, the pipeline treats that phase as incomplete and re-runs it. Phase outputs are idempotent — re-running a phase with the same inputs produces equivalent output.

---

## 13. Non-Goals

- **Distributed locking.** Single-process tool. No Redis, etcd, or file-based locks.
- **Screen-level scheduling.** Screens are a prompt technique for scoping analysis, not a scheduling or locking concept. All scheduling operates at controller (or batch) granularity.
- **Sub-file locking.** Locks operate at file level. Two agents modifying different methods in the same file must coordinate at file level.
- **Lock escalation.** Once dispatched, an agent's lock set is fixed.
- **Automatic dependency inference.** The locking system does not parse Ruby code. Write targets come from batch planning output. Manual declaration is intentional.
- **Persistent lock state.** Locks live in memory. Phase outputs persist, but lock grants do not survive restarts. On restart, no agents are running, so no locks are needed.
- **Prompt templates.** This spec defines phases and interfaces. Prompt content is a separate concern in `prompts.rb`.
- **UI layout.** This spec defines what data the UI needs (lock state, queue depth, phase status). How the UI presents it is a separate concern.
