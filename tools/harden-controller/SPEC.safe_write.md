# Safe-Write Locking Spec

A locking system that enables parallel `claude -p` agents to work on the same codebase without file collisions. Agents declare needed paths upfront; the orchestrator dispatches only when locks are available.

This spec covers intent, concepts, and interfaces. It does not cover UI changes or prompt modifications.

---

## 1. Intent

The harden-controller pipeline currently runs one `claude -p` agent at a time per phase. This works but leaves parallelism on the table — analysis of `Blog::PostsController` is independent of analysis of `Blog::CommentsController`, yet they run sequentially.

The goal: run many agents in parallel against the same codebase, with a locking system that prevents file collisions. Agents are queued, not executed, until the paths they need are available. The codebase is organized into lockable directory units at the screen level (see `docs/app-organization.md`), and the locking system respects this hierarchy.

---

## 2. Core Concepts

### Screen-level agents are read-only

Screen-level agents analyze app code and produce documentation (JSON or Markdown) in a screen-scoped doc directory (e.g., `.analysis/blog/posts/show/`). They only **read** app code. Multiple screen agents can run in parallel without conflicting — they each write to their own isolated doc directory.

### Controller-level agents merge screen docs into code changes

This is the write phase. It reads screen-level documentation and produces actual code modifications. This phase needs write locks on the app code paths it will modify.

### Locks are acquired before dispatch

The orchestrator computes the lock set from dependency analysis + `.lockspec.json` manifests, acquires all locks atomically, and only then spawns the agent. This prevents partial-execution waste — expensive Claude calls that fail mid-way due to conflicts.

### Lock granularity matches directory hierarchy

A lock on `app/views/blog/posts/show/` covers all files in that directory. A lock on `app/views/blog/` covers the entire blog view subtree. Parent locks conflict with child locks and vice versa.

---

## 3. Lock Types

| Lock | Semantics | Used by |
|---|---|---|
| **Read** | Multiple readers allowed | Screen-level analysis agents reading app code |
| **Write** | Exclusive | Controller-level merge agents modifying app code |
| **Doc-write** | Write lock on a screen's doc directory | Screen-level agents writing analysis output |

Doc-write locks are exclusive per screen but inherently non-conflicting across screens since each screen has its own directory. This provides free parallelism — the constraint is Claude API slots, not lock contention.

---

## 4. Conflict Rules

### Compatibility matrix

| Held \ Requested | Read | Write |
|---|---|---|
| **Read** | OK | BLOCKED |
| **Write** | BLOCKED | BLOCKED |

### Hierarchical conflicts

Locks propagate through the directory hierarchy:

- Locking `app/views/blog/` conflicts with any lock on a path within it (e.g., `app/views/blog/posts/show/show.html.erb`). A parent lock encompasses all children.
- Locking a child path conflicts with any existing lock on an ancestor path. A child is within the parent's scope.

### Regex pattern conflicts

A pattern lock like `app/views/blog/.*` matches the literal path `app/views/blog/posts/show/show.html.erb`. Two regex patterns are conservatively assumed to conflict — regex intersection is undecidable in general, and false positives (unnecessary blocking) are preferable to false negatives (missed conflicts).

---

## 5. Two-Phase Execution Model

```
Phase 1: Screen Analysis (read-only, massively parallel)
┌─────────────────────────────────────────────────────────────────┐
│  For each screen:                                               │
│    1. Acquire read locks on app code paths (from .lockspec.json │
│       + controller scope)                                       │
│    2. Acquire doc-write lock on screen doc directory             │
│    3. Run claude -p to analyze the screen                       │
│    4. Output: JSON/Markdown in screen doc dir                   │
│    5. Release all locks                                         │
└─────────────────────────────────────────────────────────────────┘

Phase 2: Controller Merge (write, sequential per controller)
┌─────────────────────────────────────────────────────────────────┐
│  For each controller:                                           │
│    1. Acquire write locks on controller file + associated views │
│       + test files                                              │
│    2. Read screen-level docs produced by Phase 1                │
│    3. Run claude -p to produce code changes                     │
│    4. Apply changes via safe_write (verifies lock is held)      │
│    5. Release all locks                                         │
└─────────────────────────────────────────────────────────────────┘
```

Phase 1 is embarrassingly parallel — the only contention is on Claude API slots (capped at `MAX_CLAUDE_CONCURRENCY`). Phase 2 agents contend on shared files (e.g., `shared/_form.html.erb`) but the scope is much narrower.

---

## 6. Orchestrator Workflow

### Step 1: Discover

Scan directory structure and `.lockspec.json` files to build a screen inventory. Each screen entry includes:
- Screen name and primary action
- Owning controller
- Read dependencies (from `.lockspec.json` or inferred from controller scope)
- Doc output directory

### Step 2: Build dependency graph

Compute which screens depend on which paths. Group screens by controller. Identify shared paths that will require broader locks in Phase 2.

### Step 3: Enqueue Phase 1 work items

Create a work item per screen with its computed lock set:
- Read locks: controller file, view directory, model files, declared `reads_from` paths
- Doc-write lock: screen doc directory (e.g., `.analysis/blog/posts/show/`)

### Step 4: Dispatch loop

Poll for two conditions:
1. **Lock availability**: All locks in the work item's lock set can be acquired atomically
2. **Claude slot availability**: A `claude -p` concurrency slot is free

When both are satisfied, acquire locks and dispatch the agent. When either is unavailable, skip and check the next queued item.

### Step 5: Phase transition

When all Phase 1 work items for a controller complete, enqueue the Phase 2 (merge) work item for that controller. Phase 2 does not wait for all controllers' Phase 1 to complete — it fires as soon as a controller's screens are all analyzed.

### Step 6: Dispatch Phase 2

Same dispatch loop, but with write locks:
- Write locks: controller file, view directories (including `shared/`), test files
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
3. **Grant coverage**: The grant covers the target path via literal match, hierarchical containment, or regex pattern match.

If any check fails, the write is rejected with a `LockViolationError`. This is the enforcement point — even a bug in the scheduler or dependency analyzer cannot produce an unprotected write.

---

## 8. Lock Acquisition Semantics

### All-or-nothing

Request all paths at once. Either all locks are granted or none are. This prevents deadlocks — there is no hold-and-wait condition. If any path in the set is unavailable, the entire request is rejected (not blocked — the work item stays queued for retry).

### Timeout-bounded blocking

Work items wait in the queue for up to N seconds (configurable, default 300s). If the timeout expires without acquiring locks, the item remains queued with an incremented retry count. Items exceeding max retries are moved to an error state and surfaced to the operator.

### No lock escalation during screen-level work

Screen agents are read-only and their lock set is fully computed before dispatch. If the analysis reveals an unexpected dependency, it is recorded in the screen doc as a finding — not resolved by grabbing more locks mid-execution. This keeps the locking model simple: once dispatched, a screen agent's lock footprint never grows.

### Controller-level escalation

Merge agents may discover they need an additional path (e.g., a shared partial that wasn't in the pre-computed set). They can request escalation:

1. Request additional lock(s) with a short timeout (30s default)
2. On success, the grant is extended to cover the new path(s)
3. On failure, the agent records the unresolvable dependency, completes what it can, and surfaces the gap to the operator

Escalation is a fallback, not a routine path. Well-computed dependency graphs from `.lockspec.json` should make escalation rare.

---

## 9. LockManager Interface

The `LockManager` is a thread-safe object that tracks all active grants and resolves conflicts.

### Methods

```ruby
# Non-blocking. Returns a LockGrant if all paths can be locked, nil otherwise.
try_acquire(holder:, paths:, patterns: [], mode:) → LockGrant | nil

# Blocking up to timeout. Returns a LockGrant or raises LockTimeoutError.
acquire(holder:, paths:, patterns: [], mode:, timeout: 300) → LockGrant

# Release a grant. Idempotent.
release(grant_id:)

# Extend an existing grant with additional paths. Returns true on success.
escalate(grant_id:, additional_paths:, timeout: 30) → bool

# Check what would conflict without acquiring. For diagnostics and UI.
check_conflicts(paths:, patterns: [], mode:) → [ConflictInfo]

# Snapshot of all active grants. For SSE state broadcast.
active_grants → [GrantSnapshot]
```

### LockGrant fields

| Field | Type | Description |
|---|---|---|
| `id` | String | Unique grant identifier (UUID) |
| `holder` | String | Identifier of the agent/work-item holding the grant |
| `paths` | Array\<String\> | Literal paths covered |
| `patterns` | Array\<Regexp\> | Regex patterns covered |
| `mode` | Symbol | `:read` or `:write` |
| `acquired_at` | Time | When the grant was issued |
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

### WorkItem fields

| Field | Type | Description |
|---|---|---|
| `id` | String | Unique work item identifier |
| `workflow` | String | Controller/screen name |
| `phase` | Symbol | `:analyze`, `:merge`, etc. |
| `lock_request` | LockRequest | Paths, patterns, and mode needed |
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
      paths: item.lock_request.paths,
      patterns: item.lock_request.patterns,
      mode: item.lock_request.mode
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

`Pipeline.new` gains two new collaborators:

```ruby
Pipeline.new(
  # ... existing options ...
  lock_manager: LockManager.new,
  scheduler: Scheduler.new(lock_manager:, claude_semaphore:)
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

All-or-nothing acquisition eliminates hold-and-wait. There is no lock ordering requirement because agents never hold partial lock sets. The only theoretical deadlock is starvation (an agent perpetually unable to acquire its full set), which is handled by priority escalation after 10 minutes.

### Scheduler crash

The scheduler runs in its own thread within the Pipeline process. If it crashes, `safe_thread` catches the exception and sets a global error state. Work items in the queue are preserved (they're in-memory data structures) and the scheduler can be restarted.

---

## 13. Non-Goals

- **Distributed locking.** This is a single-process tool running on one machine. No need for Redis, etcd, or file-based locks.
- **Persistent lock state.** Locks live in memory. If the process restarts, all locks are gone — which is correct because all agents are also gone.
- **Automatic dependency inference.** The locking system does not parse Ruby code to discover dependencies. Dependencies come from `.lockspec.json` declarations and directory conventions. Manual declaration is intentional — it forces the operator to think about boundaries.
- **Sub-file locking.** Locks operate at the file/directory level, not at the method or line level. If two agents need to modify different methods in the same file, they must coordinate at the file level.
- **UI for lock management.** The existing SSE-based UI displays lock state (active grants, queue depth, blocked items) but does not provide manual lock override controls. Lock release is automatic.
