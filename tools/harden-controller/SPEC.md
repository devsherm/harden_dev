# Harden Controller — Spec

## Intent

A standalone Sinatra application that orchestrates parallel `claude -p` calls to analyze, evaluate, and modify Rails controllers through a browser-based UI with human-in-the-loop approval. The pipeline is currently configured for security hardening (prompt templates focus on authorization, validation, rate limiting, and related concerns), but the architecture is task-agnostic — the same discover-analyze-decide-apply-test-verify pipeline supports any controller-scoped task by swapping prompts. Designed for a single operator exposed over ngrok.

## Terminology

| Term | Definition |
|---|---|
| **Pipeline** | The singleton `Pipeline` instance (`$pipeline`) that manages all state, threading, and phase orchestration. One per server process. |
| **Controller** | A Rails controller file discovered by glob. The unit of analysis, decision-making, and workflow tracking. |
| **Workflow** | Per-controller state machine tracking progress through pipeline phases. Keyed by controller basename (e.g., `posts_controller`). |
| **Phase** | A discrete step in the pipeline: discover, analyze, decide, harden, test, ci_check, verify. Each phase either calls `claude -p`, runs shell commands, or awaits human input. |
| **Finding** | A structured analysis result identifying a hardening opportunity. Has severity (high/medium/low), category, scope (controller/module/app), and suggested fix. |
| **Blocker** | A finding with scope `module` or `app` — requires changes beyond the controller file. Displayed separately in the UI; must be dismissed before hardening proceeds. |
| **Sidecar** | A JSON file stored in a `.harden/` (configurable) directory adjacent to the target controller. Persists phase outputs across restarts. |
| **Decision** | The operator's response to analysis findings: `approve` (apply all suggested fixes), `selective` (apply specific findings only), `modify` (apply fixes with operator-provided modifications via a notes field), or `skip` (bypass hardening entirely). |
| **Query** | An ad-hoc question or finding explanation request. Dispatched to `claude -p` in a background thread; results delivered via SSE. |
| **Safe write** | Path-validated file write. Rejects writes outside `allowed_write_paths` and resolves symlinks to prevent traversal. |
| **Try transition** | Atomic state machine gate. Checks a guard condition under mutex and transitions workflow status, preventing double-starts. |

## Architecture

### Pipeline Phases

```
discover → analyze → awaiting_decisions
  → skip ─────────────────────────────────────────────────────→ skipped
  → harden → hardened → test → fix_tests (loop)
      → tested → ci_check → fix_ci (loop)
          → ci_passed → verify → complete
      │                   └──→ ci_failed (retry available)
      └──→ tests_failed (retry available)
```

Discovery is global (one pass over the entire `discovery_glob`). All subsequent phases operate per-controller. The phase chain from `harden` through `verify` executes sequentially within a single thread per controller — `run_hardening` calls `run_testing`, which calls `run_ci_checks`, which calls `run_verification`. The `awaiting_decisions` phase is a human gate that breaks this chain.

Intermediate gate statuses control phase sequencing:

| Status | Set by | Guards entry to |
|---|---|---|
| `hardened` | `run_hardening` on success | `run_testing` |
| `tested` | `run_testing` on test pass | `run_ci_checks` |
| `ci_passed` | `run_ci_checks` on CI pass | `run_verification` |

Terminal/retry statuses:

| Status | Meaning | Recovery |
|---|---|---|
| `skipped` | Operator chose `skip` decision | Re-analyze |
| `tests_failed` | Fix loop exhausted `MAX_FIX_ATTEMPTS` | Retry button in UI |
| `ci_failed` | Fix loop exhausted `MAX_CI_FIX_ATTEMPTS` | Retry button in UI |

### State Model

All state lives in `@state` (a Hash), accessed exclusively through `@mutex.synchronize`. Key structure:

| Field | Type | Description |
|---|---|---|
| `phase` | String | Global pipeline phase: `"idle"`, `"discovering"`, `"ready"` |
| `controllers` | Array | Discovery results (immutable after discovery completes) |
| `workflows` | Hash | Per-controller workflow state, keyed by controller name |
| `errors` | Array | Global error log with timestamps |

Workflow entries contain: `name`, `path`, `full_path`, `status`, `analysis`, `decision`, `hardened`, `test_results`, `ci_results`, `verification`, `error`, `started_at`, `completed_at`, `original_source`.

#### Queries Subsystem

Ad-hoc questions and finding explanations are tracked in a separate `@queries` instance variable (an Array), outside `@state` but guarded by the same `@mutex`. Each query entry records the question, the response from `claude -p`, and metadata (controller name, timestamp, type). The `ask_question` and `explain_finding` orchestration methods append to `@queries`.

`MAX_QUERIES` (50) caps the array size. `prune_queries` removes the oldest entries when the cap is exceeded. The `to_json` method merges `@queries` into the serialized output alongside `@state`, so the frontend receives queries via the SSE stream.

### Concurrency Model

- One global `Pipeline` instance with a single `@mutex` guarding `@state`.
- `safe_thread` wraps `Thread.new` with exception handling — sets workflow to `error` on unhandled exception. Dead threads are pruned on each `safe_thread` call.
- `@claude_semaphore` (Mutex) + `@claude_slots` (ConditionVariable) limit concurrent `claude -p` calls to `MAX_CLAUDE_CONCURRENCY` (12).
- `spawn_with_timeout` runs subprocesses in their own process group (`pgroup: true`), sends TERM then KILL on timeout or cancellation.
- `cancel!` and `cancelled?` read/write a boolean without mutex — atomic under CRuby's GVL.

### Server Layer

Sinatra application (`server.rb`) with Puma. Routes dispatch work by calling `try_transition` (to prevent double-starts) then spawning a `safe_thread` for the phase method. State is broadcast to the frontend via SSE (polling `to_json` every 500ms, sending only on change).

### Frontend

Single-file SPA (`index.html`). No build tools. CDN dependencies: marked (Markdown rendering), DOMPurify (sanitization), morphdom (DOM diffing). The `render()` function builds the full UI as an HTML string, then `morphdom` diffs and patches only what changed — preserving scroll positions, focus state, and input values. Per-controller client-side state (`perController`) tracks finding decisions, dismissed blockers, and open/closed sections; this state is not in the SSE payload.

## Code Organization

| File | Purpose |
|---|---|
| `server.rb` | Sinatra routes, authentication, SSE streaming, CORS, CSRF protection, signal handling, startup |
| `pipeline.rb` | `Pipeline` class definition, constants, `try_transition`, `initialize`, `reset!`, `to_json`, state accessors |
| `pipeline/orchestration.rb` | Phase logic: `discover_controllers`, `run_analysis`, `load_existing_analysis`, `submit_decision`, `run_hardening`, `run_testing`, `run_ci_checks`, `run_verification`, `ask_question`, `explain_finding` |
| `pipeline/claude_client.rb` | `claude_call` (acquire slot, spawn CLI, release slot), `parse_json_response` (strips markdown fences, extracts JSON from prose) |
| `pipeline/process_management.rb` | `safe_thread`, `cancel!`, `cancelled?`, `shutdown`, `spawn_with_timeout`, `run_all_ci_checks` |
| `pipeline/sidecar.rb` | `sidecar_path`, `ensure_sidecar_dir`, `write_sidecar`, `safe_write`, `derive_test_path`, `default_derive_test_path` |
| `prompts.rb` | All `claude -p` prompt templates: `analyze`, `harden`, `fix_tests`, `fix_ci`, `verify`, `ask`, `explain` |
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

## Design Decisions

- **Global singleton pipeline**: A single `$pipeline` instance with one mutex simplifies reasoning about concurrency. All state access goes through `@mutex.synchronize`. This is sufficient for a single-operator tool; distributed locking is a non-goal.

- **Sequential phase chaining within a thread**: `run_hardening` directly calls `run_testing`, which calls `run_ci_checks`, which calls `run_verification`. This eliminates coordination overhead between phases and ensures the controller file is not modified between phases. The thread holds the workflow from hardening through verification.

- **`try_transition` as the concurrency gate**: Routes call `try_transition` before spawning threads. The guard-and-transition is atomic under mutex, so concurrent requests for the same controller cannot both succeed. The `:not_active` guard checks against `ACTIVE_STATUSES` — any status representing async work in progress.

- **`cancel!`/`cancelled?` without mutex**: These read/write a single boolean, which is atomic under CRuby's GVL. The `cancelled?` check is polled in `spawn_with_timeout` and `acquire_claude_slot` loops to enable responsive cancellation without mutex contention.

- **Process groups for subprocess management**: `spawn_with_timeout` creates subprocesses with `pgroup: true` and kills via `-TERM`/`-KILL` on the process group. This prevents orphaned child processes (e.g., if `claude -p` spawns sub-processes).

- **Prompt store for debugging**: Prompts sent to `claude -p` are stored in `@prompt_store` (keyed by controller name and phase) and exposed via GET `/pipeline/:name/prompts/:phase`. The route validates the phase against `VALID_PROMPT_PHASES` (`analyze`, `harden`, `fix_tests`, `fix_ci`, `verify`) and returns 404 for unrecognized phases. The `to_json` method enriches each workflow entry with a `prompts` key — a hash mapping stored prompt phases to `true`, indicating which phases have stored prompts available. The frontend uses this to render "Copy Prompt" buttons so the operator can reproduce or debug any phase's claude call.

- **SSE with change detection**: The `/events` endpoint polls `to_json` every 500ms and sends only when the JSON differs from the last sent value. `to_json` itself is cached for 100ms to avoid redundant serialization under concurrent SSE connections.

- **Morphdom for efficient DOM updates**: The frontend renders the entire UI as a string on every state change, then uses morphdom to diff against the live DOM. The `onBeforeElUpdated` callback skips focused `INPUT`/`TEXTAREA` elements to preserve cursor position. This eliminates manual DOM manipulation while preserving user interaction state.

- **Blockers as a UI concept, not a pipeline concept**: Findings with scope `module` or `app` are displayed as "out-of-scope blockers" in the UI. The pipeline itself does not enforce blocker dismissal — this is a client-side gate. All undismissed blockers must be dismissed before the "Harden" button is enabled, but this logic lives entirely in `index.html`.

- **Path-validated writes via `safe_write`**: All file writes go through `safe_write` which resolves paths via `File.realpath` and checks against `allowed_write_paths`. This prevents directory traversal and symlink escapes. Sidecar writes use `write_sidecar` which applies the same validation.

- **Configurable pipeline**: `Pipeline.new` accepts keyword arguments for `rails_root`, `sidecar_dir`, `allowed_write_paths`, `discovery_glob`, `discovery_excludes`, and `test_path_resolver`. Defaults are security-hardening-focused but can be overridden for other workflows (e.g., targeting views instead of controllers).

- **CSRF via `X-Requested-With` header**: Instead of token-based CSRF, all POST routes (except `/auth`) require the `X-Requested-With: XMLHttpRequest` header. This works because the SPA makes all state-changing requests via `fetch()` which attaches the header, and the Same-Origin Policy prevents cross-origin `fetch` from setting custom headers.

- **Rate limiting on `/auth`**: Failed authentication attempts are tracked per IP (using rightmost `X-Forwarded-For` entry for ngrok). After `AUTH_MAX_ATTEMPTS` (5) failures within `AUTH_WINDOW` (900s), further attempts receive 429. Successful login resets the counter. The tracking map is pruned to prevent unbounded growth (`AUTH_MAX_TRACKED_IPS` = 10,000).

- **Session fixation prevention**: The session ID is regenerated on successful authentication via `env["rack.session.options"][:renew] = true`.

- **Error sanitization**: `sanitize_error` replaces `@rails_root` and its `File.realpath` with `<project>` in all error messages, preventing path disclosure to the browser.

- **CI checks run in parallel threads**: `run_all_ci_checks` spawns one thread per CI check (rubocop, brakeman, bundler-audit, importmap-audit) and joins all. If any thread raises, the others are killed and joined before re-raising.

- **Fix loops are bounded**: Test fixes and CI fixes each have a maximum retry count (`MAX_FIX_ATTEMPTS` = 2, `MAX_CI_FIX_ATTEMPTS` = 2). If fixes do not resolve failures within the limit, the workflow enters `tests_failed` or `ci_failed` status with a retry button in the UI.

- **Sidecar files enable resumability**: Discovery scans for existing sidecar files (analysis.json, hardened.json, test_results.json, ci_results.json, verification.json) and exposes their presence and timestamps. The frontend offers "Use Existing" to load a prior analysis without re-running claude.

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

### State Machine Guards

`try_transition` enforces two guard types:

- **`:not_active`** — succeeds if no workflow exists for the controller, or if the existing workflow's status is not in `ACTIVE_STATUSES`. Creates or resets the workflow. Prevents double-starts.
- **Named guard** (e.g., `"awaiting_decisions"`) — succeeds only if the workflow's current status exactly matches the guard string. Used for phase-specific transitions (e.g., decisions can only be submitted when status is `awaiting_decisions`).

Both guards operate atomically under `@mutex`. On success, the status is updated and error is cleared. On failure, a descriptive error string is returned.

## Integration

### External Dependencies

- **`claude` CLI**: All automated phases invoke `claude -p <prompt>` via `spawn_with_timeout`. The CLI must be installed and authenticated. Concurrent calls are bounded by `MAX_CLAUDE_CONCURRENCY` (12).
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

### HTTP Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/` | Serve `index.html` (or login page if auth enabled and not authenticated) |
| POST | `/auth` | Authenticate with passcode |
| POST | `/auth/logout` | Clear session |
| GET | `/pipeline/status` | JSON state snapshot |
| POST | `/pipeline/analyze` | Start analysis for a controller |
| POST | `/pipeline/load-analysis` | Load existing analysis from sidecar |
| POST | `/pipeline/reset` | Reset pipeline and re-discover |
| POST | `/decisions` | Submit finding decisions for a controller |
| POST | `/ask` | Ad-hoc question about a controller |
| POST | `/explain/:finding_id` | Explain a specific finding |
| POST | `/pipeline/retry-tests` | Retry testing from `tests_failed` |
| POST | `/pipeline/retry-ci` | Retry CI from `ci_failed` |
| POST | `/pipeline/retry` | Retry from `error` (re-runs analysis) |
| POST | `/shutdown` | Graceful server shutdown |
| GET | `/events` | SSE stream of pipeline state |
| GET | `/pipeline/:name/prompts/:phase` | Retrieve stored prompt for debugging (phase must be in `VALID_PROMPT_PHASES`) |

## Non-Goals

- **Distributed or multi-user operation**: Single-process, single-operator tool. No Redis, database, or multi-server coordination.
- **File-level locking or parallel write agents**: The current implementation runs one workflow per controller at a time. `SPEC.proposed.md` and `SPEC.safe_write.md` describe a planned LockManager and Scheduler for parallel write phases — these are not implemented.
- **Persistent lock state or work queues**: All state beyond sidecar files is in-memory. Pipeline restarts clear workflows and threads.
- **Prompt template content**: This spec describes the pipeline infrastructure. Prompt design is a separate concern in `prompts.rb`.
- **UI layout details**: This spec describes what data the UI consumes (workflow state, queries, errors) and how it renders (morphdom, SSE). Visual design and component structure are implementation details of `index.html`.
- **Sub-file locking or automatic dependency inference**: Not implemented. Write targets are not declared or tracked.
- **Claude Messages API integration**: All automated phases use the `claude -p` CLI. Direct API calls (described in `SPEC.proposed.md` for a research phase) are not implemented.
