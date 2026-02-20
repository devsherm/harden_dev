# Safe-Write Locking Spec

A file-level locking system that enables parallel `claude -p` agents to work on the same codebase without write collisions. Agents declare needed paths upfront; the orchestrator dispatches only when locks are available.

This spec covers intent, concepts, and interfaces. It does not cover UI changes or prompt modifications.

---

## 1. Intent

The harden-controller pipeline currently runs one `claude -p` agent at a time per phase. This works but leaves parallelism on the table — analysis of the Posts Index screen is independent of analysis of the Comments Index screen, yet they run sequentially.

The goal: run many agents in parallel against the same codebase, with a file-level locking system that prevents write collisions. Screen analysis agents run massively parallel (read-only on app code). Controller merge agents acquire file-level write locks before modifying code, with lock sets computed from the preceding analysis output.

The target codebase is large (17+ modules, 100+ controllers). Screen-level analysis parallelism is essential for throughput. Controller-level merge agents must run in parallel across controllers within the same module, which requires file-level — not directory-level — lock granularity.

---

## 2. Core Concepts

### Screen-level agents are read-only

Screen-level agents analyze app code and produce documentation (JSON or Markdown) in a screen-scoped doc directory (e.g., `.analysis/blog/posts/show/`). They only **read** app code. Multiple screen agents can run in parallel without conflicting — they each write to their own isolated doc directory.

### Controller-level agents merge screen docs into code changes

This is the write phase. It reads screen-level documentation and produces actual code modifications to any app file — controllers, views, models, services, concerns, or tests. This phase needs write locks on the specific files it will modify.

### Analysis output declares write targets

Screen analysis agents include a `write_targets` field in their output — a list of specific file paths that the controller merge phase should lock for writing. This is the bridge between read-only analysis and write-locked execution. The orchestrator aggregates write targets from all screen analyses for a controller to compute the merge agent's lock set.

### Locks are file-level and acquired before dispatch

The orchestrator computes the lock set from the screen manifest (for analysis reads) and aggregated analysis output (for merge writes), acquires all locks atomically, and only then spawns the agent. This prevents partial-execution waste — expensive Claude calls that fail mid-way due to conflicts.

### Write locks are held through the lifecycle

Once a controller's merge agent acquires write locks, they are held through the entire write lifecycle: hardening, testing, fix iterations, CI checks, and verification. Locks are released only on completion or error. This is simpler and safer than acquiring/releasing per sub-phase, which would create windows for other agents to introduce inconsistency.

---

## 3. Lock Types

| Lock | Semantics | Used by |
|---|---|---|
| **Read** | Multiple readers allowed; may target files or directories | Screen analysis agents reading app code |
| **Write** | Exclusive; must target individual files (not directories) | Controller merge agents modifying app code |

Read locks on directories are a convenience — they cover all files within the directory for conflict-checking purposes. Write locks must always specify individual files to prevent over-locking.

---

## 4. Conflict Rules

### Compatibility matrix

| Held \ Requested | Read | Write |
|---|---|---|
| **Read** | OK | BLOCKED |
| **Write** | BLOCKED | BLOCKED |

### File-level resolution

Two lock requests conflict when they target **overlapping paths** with incompatible modes.

Path overlap rules:

| Active lock | Requested lock | Overlap? |
|---|---|---|
| File A | File A | Yes — same file |
| File A | File B | No |
| Directory D | File within D | Yes — file is within directory scope |
| File within D | Directory D | Yes — directory encompasses the file |
| Directory D | Directory E | Yes if one contains the other; No if disjoint |

When paths overlap, the compatibility matrix determines whether the request is blocked. When paths don't overlap, no conflict exists regardless of lock mode.

### Over-lock detection

Write lock requests specifying a directory path are rejected with an `OverLockError`. This catches the most common form of over-locking — an agent declaring write access to an entire directory when it should specify individual files.

---

## 5. Two-Phase Execution Model

```
Phase 1: Screen Analysis (read-only, massively parallel)
┌──────────────────────────────────────────────────────────────────┐
│  For each screen (from manifest):                                │
│    1. Acquire read locks on app code paths (from manifest        │
│       reads_from + controller scope)                             │
│    2. Run claude -p to analyze the screen                        │
│    3. Output: JSON/Markdown in screen doc dir, including         │
│       write_targets for Phase 2                                  │
│    4. Release all locks                                          │
└──────────────────────────────────────────────────────────────────┘

Phase 2: Controller Merge (write, file-locked, held through lifecycle)
┌──────────────────────────────────────────────────────────────────┐
│  For each controller:                                            │
│    1. Aggregate write_targets from all screen analyses           │
│    2. Acquire write locks on declared files + read locks on      │
│       screen doc directories                                     │
│    3. Run claude -p to produce code changes                      │
│    4. Apply changes via safe_write (verifies lock is held)       │
│    5. Continue through test → fix → CI → verify (locks held)     │
│    6. Release all locks on completion or error                   │
└──────────────────────────────────────────────────────────────────┘
```

Phase 1 is embarrassingly parallel — the only contention is on Claude API slots (capped at `MAX_CLAUDE_CONCURRENCY`). Phase 2 agents contend on shared files (e.g., `authentication.rb` if two controllers' analyses both declare it as a write target), but contention is minimized by file-level granularity.

---

## 6. Orchestrator Workflow

### Step 1: Load manifest

Read the screen manifest (see `docs/target-app-organization.md` §3) to build the screen inventory. Each screen entry includes:
- Screen name, module, controller
- Primary and secondary actions
- Read dependencies (`reads_from`)

### Step 2: Build dependency graph

Group screens by controller. Compute which screens share read dependencies. Identify files appearing in multiple screens' `reads_from` — these are module-scoped or app-scoped and will have higher contention in Phase 2.

### Step 3: Enqueue Phase 1 work items

Create a work item per screen with its computed read lock set:
- Read locks: controller file, view directory, model files, declared `reads_from` paths

### Step 4: Dispatch loop

Poll for two conditions:
1. **Lock availability**: All locks in the work item's lock set can be acquired atomically
2. **Claude slot availability**: A `claude -p` concurrency slot is free

When both are satisfied, acquire locks and dispatch the agent. When either is unavailable, skip and check the next queued item.

### Step 5: Phase transition

When all Phase 1 work items for a controller complete, aggregate `write_targets` from all screen analysis outputs for that controller. Enqueue the Phase 2 (merge) work item with the aggregated write lock set.

Phase 2 does not wait for all controllers' Phase 1 to complete — it fires as soon as a controller's screens are all analyzed.

### Step 6: Dispatch Phase 2

Same dispatch loop, but with write locks:
- Write locks: specific files from aggregated `write_targets`
- Read locks: screen doc directories (reading Phase 1 output)

### Priority

Near-completion phases first: `verify > test > apply > analyze`, then FIFO within each phase. This prioritizes finishing in-progress work over starting new work, reducing the number of active lock holders at any time.

Starvation prevention: work items waiting longer than 10 minutes receive priority escalation.

---

## 7. Safe-Write Enforcement

`safe_write` is the existing write gate in `pipeline/sidecar.rb`. It currently validates that paths stay within `allowed_write_paths`. The locking system adds a second layer of enforcement.

### Enhanced safe_write signature

```
safe_write(path, content, grant_id:)
```

### Three checks (all must pass)

1. **Path allowlist**: Path is within `allowed_write_paths` (existing behavior — directory membership check).
2. **Grant validity**: A valid `LockGrant` exists for the given `grant_id`. The grant must not be expired or released.
3. **Grant coverage**: The target path appears in the grant's `write_paths` list (exact match).

If any check fails, the write is rejected with a `LockViolationError`. This is the enforcement point — even a bug in the scheduler or dependency analyzer cannot produce an unprotected write.

---

## 8. Lock Acquisition Semantics

### All-or-nothing

Request all paths at once. Either all locks are granted or none are. This prevents deadlocks — there is no hold-and-wait condition. If any path in the set is unavailable, the entire request is rejected (not blocked — the work item stays queued for retry).

### Timeout-bounded queuing

Work items wait in the queue for up to N seconds (configurable, default 300s). If the timeout expires without acquiring locks, the item remains queued with an incremented retry count. Items exceeding max retries are moved to an error state and surfaced to the operator.

### No lock expansion after dispatch

Once dispatched, an agent's lock footprint never grows. If the agent discovers it needs a file it didn't lock, it records the gap as a finding and surfaces it to the operator. The analysis phase is responsible for declaring complete and accurate write targets. If write targets are consistently incomplete, the analysis prompts need refinement — not the locking system.

---

## 9. LockManager Interface

The `LockManager` is a thread-safe object that tracks all active grants and resolves conflicts.

### Methods

```ruby
# Non-blocking. Returns a LockGrant if all paths can be locked, nil otherwise.
# Raises OverLockError if any write path is a directory.
try_acquire(holder:, read_paths: [], write_paths: []) → LockGrant | nil

# Blocking up to timeout. Returns a LockGrant or raises LockTimeoutError.
acquire(holder:, read_paths: [], write_paths: [], timeout: 300) → LockGrant

# Release a grant. Idempotent.
release(grant_id:)

# Check what would conflict without acquiring. For diagnostics and UI.
check_conflicts(read_paths: [], write_paths: []) → [ConflictInfo]

# Snapshot of all active grants. For SSE state broadcast.
active_grants → [GrantSnapshot]
```

### LockGrant fields

| Field | Type | Description |
|---|---|---|
| `id` | String | Unique grant identifier (UUID) |
| `holder` | String | Identifier of the agent/work-item holding the grant |
| `read_paths` | Array\<String\> | File and directory paths with read access |
| `write_paths` | Array\<String\> | File paths with write access (no directories) |
| `acquired_at` | Time | When the grant was issued |
| `expires_at` | Time | TTL expiry (safety net, default 30 minutes) |
| `released` | Boolean | Whether the grant has been released |

### Thread safety

All `LockManager` state is guarded by a single `Mutex`, consistent with the existing `Pipeline` concurrency model. The lock table is a simple in-memory data structure — no external coordination needed for a single-process tool.

---

## 10. Scheduler Interface

The `Scheduler` manages the work queue and dispatch loop.

### Methods

```ruby
# Add a work item to the queue.
enqueue(workflow:, phase:, lock_request:, &callback)

# Start the dispatch loop (runs in its own thread).
start

# Graceful shutdown — wait for active agents to complete, do not dispatch new ones.
stop

# Current queue depth (for UI display).
queue_depth → Integer

# Active work items (for UI display).
active_items → [WorkItem]
```

### LockRequest fields

| Field | Type | Description |
|---|---|---|
| `read_paths` | Array\<String\> | File and directory paths needing read access |
| `write_paths` | Array\<String\> | File paths needing write access (no directories) |

### WorkItem fields

| Field | Type | Description |
|---|---|---|
| `id` | String | Unique work item identifier |
| `workflow` | String | Controller/screen name |
| `phase` | Symbol | `:analyze`, `:merge`, etc. |
| `lock_request` | LockRequest | Read and write paths needed |
| `status` | Symbol | `:queued`, `:dispatched`, `:completed`, `:error` |
| `queued_at` | Time | When the item entered the queue |
| `dispatched_at` | Time | When locks were acquired and the agent was spawned |
| `grant_id` | String | The LockGrant id, once dispatched |

### Dispatch loop pseudocode

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

## 11. Integration with Existing Pipeline

The locking system integrates with the existing `Pipeline` class and its modules. Changes are additive — existing behavior is preserved for single-agent execution.

### Pipeline initialization

`Pipeline.new` gains new collaborators:

```ruby
Pipeline.new(
  # ... existing options ...
  lock_manager: LockManager.new,
  scheduler: Scheduler.new(lock_manager:, claude_semaphore:),
  screen_manifest: ScreenManifest.load("screens.json")
)
```

When `lock_manager` is nil (the default), the pipeline operates in legacy mode — no locking, direct dispatch via `safe_thread` as today.

### New workflow status: "queued"

The status progression gains a new state between user request and agent dispatch:

```
idle → queued → analyzing → awaiting_decisions → ...
```

`try_transition` checks for `"queued"` as a valid source state. The scheduler moves items from `"queued"` to the active phase status when locks are acquired.

### Phase methods gain grant_id

Phase orchestration methods in `pipeline/orchestration.rb` accept an optional `grant_id:` parameter:

```ruby
def run_analysis(controller_name, grant_id: nil)
  # ... existing logic ...
  safe_write(path, content, grant_id: grant_id)
end
```

When `grant_id` is nil, `safe_write` skips the lock check (legacy mode). When present, all three checks (§7) are enforced.

### Analysis output schema

Screen analysis agents must include write targets in their output:

```json
{
  "screen": "Post Detail",
  "findings": [...],
  "write_targets": [
    "app/controllers/blog/posts_controller.rb",
    "app/views/blog/posts/show.html.erb",
    "app/controllers/concerns/authentication.rb"
  ]
}
```

The `write_targets` field lists specific file paths (relative to Rails root) that the controller merge phase will need write access to. Directory paths are rejected by the lock manager's `OverLockError` check.

### State broadcast includes lock info

`to_json` includes lock state for SSE/UI consumption:

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

### HTTP routes use scheduler

Routes that currently spawn work via `safe_thread` gain an alternative path through the scheduler:

```ruby
post '/analyze/:controller' do
  if $pipeline.scheduler
    $pipeline.scheduler.enqueue(
      workflow: params[:controller],
      phase: :analyze,
      lock_request: computed_lock_request(params[:controller])
    )
  else
    # Legacy direct dispatch
    safe_thread { $pipeline.run_analysis(params[:controller]) }
  end
end
```

---

## 12. Failure Modes and Recovery

### Agent crash mid-execution

The `safe_thread` wrapper catches exceptions and sets workflow status to `error`. On any exit path (success, error, or crash), the grant is released. Grants are never orphaned because `safe_thread`'s ensure block calls `@lock_manager.release(grant_id:)`.

### Lock leak (grant not released)

Each grant has a TTL (default: 30 minutes). The `LockManager` runs a background reaper that releases expired grants. This is a safety net — normal operation releases grants explicitly.

### Deadlock prevention

All-or-nothing acquisition eliminates hold-and-wait. There is no lock ordering requirement because agents never hold partial lock sets. The only theoretical issue is starvation (an agent perpetually unable to acquire its full set), which is handled by priority escalation after 10 minutes.

### Scheduler crash

The scheduler runs in its own thread within the Pipeline process. If it crashes, `safe_thread` catches the exception and sets a global error state. Work items in the queue are preserved (they're in-memory data structures) and the scheduler can be restarted.

### Incomplete write targets

If a merge agent attempts to write to a file not covered by its grant, `safe_write` rejects the write with a `LockViolationError`. The agent records the gap and completes what it can. This surfaces analysis prompt deficiencies to the operator — the fix is to improve analysis prompts so they declare complete write targets, not to weaken the lock enforcement.

---

## 13. Non-Goals

- **Distributed locking.** This is a single-process tool running on one machine. No need for Redis, etcd, or file-based locks.
- **Persistent lock state.** Locks live in memory. If the process restarts, all locks are gone — which is correct because all agents are also gone.
- **Automatic dependency inference.** The locking system does not parse Ruby code to discover dependencies. Screen inventories come from a manually maintained manifest. Write targets come from analysis output. Manual declaration is intentional — it forces the operator to think about boundaries.
- **Sub-file locking.** Locks operate at the file level, not at the method or line level. If two agents need to modify different methods in the same file, they must coordinate at the file level.
- **Directory-level write locks.** Write locks must specify individual files. This prevents the most common form of over-locking. Read locks may specify directories for convenience.
- **Lock escalation.** Once dispatched, an agent's lock set is fixed. If the analysis missed a dependency, the gap is surfaced to the operator for prompt refinement.
- **UI for lock management.** The existing SSE-based UI displays lock state (active grants, queue depth, blocked items) but does not provide manual lock override controls. Lock release is automatic.
