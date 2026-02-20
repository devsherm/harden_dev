# CLAUDE.md — Harden Controller

## What This Is

A standalone Sinatra app that orchestrates parallel `claude -p` calls to analyze, evaluate, and modify Rails controllers. It provides a browser UI for a single operator to review findings, approve/reject changes, and monitor progress. **This is NOT a Claude Code skill** — it's an independent tool with its own HTTP server, threading model, and browser UI.

The current pipeline is configured for **security hardening** (the prompts in `prompts.rb` are security-focused), but the architecture is task-agnostic. The same discover → analyze → decide → apply → test → verify pipeline can be repurposed for feature evaluation, code review, refactoring, or any task where you want Claude to propose changes to controllers with human approval and automated verification. To change the task, swap the prompt templates in `prompts.rb` and adjust the sidecar filenames/UI labels as needed.

Designed for exposure over ngrok to a single user at a time.

## Running

```bash
cd tools/harden-controller
RAILS_ROOT=/path/to/rails/app bundle exec ruby server.rb

# With ngrok (auto-generates passcode if HARDEN_PASSCODE is unset):
RAILS_ROOT=../.. bundle exec ruby server.rb
ngrok http 4567
```

Environment variables: `RAILS_ROOT` (target Rails app, default `.`), `HARDEN_PASSCODE` (login passcode, auto-generated if unset when binding non-localhost), `PORT` (default 4567), `SESSION_SECRET`, `CORS_ORIGIN`.

## Architecture Overview

### Pipeline phases (per controller)

```
discover → analyze → awaiting_decisions → apply → test → fix_tests (loop) →
ci_check → fix_ci (loop) → verify → complete
```

Each phase is a `claude -p` call or shell command. Phases run in `safe_thread` — a thread wrapper that catches exceptions and sets workflow status to `error`. The phase names in code still use "harden" terminology (e.g., `run_hardening`, `hardened`), reflecting the current security-hardening task. The pipeline structure itself is task-agnostic — what each phase *does* is determined by the prompts in `prompts.rb`.

### File layout

| File | Purpose |
|---|---|
| `server.rb` | Sinatra routes, auth, SSE, CORS, CSRF |
| `pipeline.rb` | Pipeline class, state management, constants, `try_transition` |
| `pipeline/orchestration.rb` | Phase logic: discover, analyze, apply, test, ci_check, verify |
| `pipeline/claude_client.rb` | `claude_call`, concurrency semaphore, JSON response parsing |
| `pipeline/process_management.rb` | `safe_thread`, `spawn_with_timeout`, `shutdown`, CI check runner |
| `pipeline/sidecar.rb` | Read/write sidecar files (default `.harden/`) next to targets |
| `prompts.rb` | All `claude -p` prompt templates |
| `index.html` | Single-file SPA (all CSS, JS, HTML inline) |

### Concurrency model

- One global `Pipeline` instance (`$pipeline`) with a single `@mutex` guarding `@state`
- `safe_thread` wraps `Thread.new` with error handling — sets workflow to `error` on exception
- `@claude_semaphore` + `ConditionVariable` limit concurrent `claude -p` calls to `MAX_CLAUDE_CONCURRENCY` (12)
- `spawn_with_timeout` runs subprocesses in their own process group, kills on timeout or cancellation
- Thread pool is cleaned on each `safe_thread` call (dead threads pruned)

### State management

All state lives in `@state` (a Hash), accessed only through `@mutex.synchronize`. Key fields:

- `phase`: global — `"idle"` | `"discovering"` | `"ready"`
- `controllers`: discovery list (immutable after discovery)
- `workflows`: keyed by controller name, each with `status`, `analysis`, `decision`, `hardened`, `test_results`, `ci_results`, `verification`, `error`
- `queries`: ad-hoc question/explanation results (capped at `MAX_QUERIES`)

`try_transition` is the state machine gate — atomically checks a guard condition and transitions. Routes call `try_transition` before spawning work threads to prevent double-starts.

### Frontend (index.html)

Single-file SPA. No build tools. CDN dependencies: marked (Markdown), DOMPurify (sanitization), morphdom (DOM diffing).

- **Rendering**: `render()` builds the full UI as an HTML string, then uses `morphdom` to diff/patch only what changed. This preserves scroll positions, focus state, and input values automatically — no manual save/restore needed. The `onBeforeElUpdated` callback skips focused `INPUT`/`TEXTAREA` elements to preserve cursor position.
- **SSE**: `EventSource` on `/events` receives pipeline state every 500ms (only on change). Each message triggers `render()`.
- **Client state**: `perController` tracks per-controller UI state (finding decisions, dismissed blockers, open/closed sections). This state is NOT in the SSE payload — it's client-only.
- **API calls**: All POSTs go through `apiFetch()` which adds `X-Requested-With: XMLHttpRequest` (required by CSRF check) and handles 401 → reload.

## Implementation Nuances

### Things that look wrong but aren't

- **`shutdownServer()` uses `innerHTML`**: This is intentional. It's a terminal state — no further renders happen after it. Using `innerHTML` here is correct and clear. Don't convert it to `morphdom`.
- **`escapeHtml()` uses `innerHTML`**: This is a utility function operating on a detached div. Not part of the render pipeline.
- **`cancel!` / `cancelled?` have no mutex**: These read/write a boolean, which is atomic under CRuby's GVL. This is documented in the code.
- **`AUTH_ATTEMPTS` is guarded by `AUTH_MUTEX`**: All reads and writes are wrapped in `AUTH_MUTEX.synchronize` blocks to ensure thread-safe access under Puma's multi-threaded worker pool.
- **No CSRF token**: CSRF protection uses the `X-Requested-With: XMLHttpRequest` header check instead of tokens. This works because the SPA makes all state-changing requests via `fetch()` which attaches the header, and the Same-Origin Policy prevents cross-origin `fetch` from setting custom headers.

### Server hardening (already applied)

The server is hardened for ngrok exposure:
- Passcode authentication with session-based login (auto-generated if unset)
- Session fixation prevention (session ID regenerated on login)
- Rate limiting on `/auth` (5 attempts per IP per 15 minutes)
- CSRF via `X-Requested-With` header check on all POSTs
- Request body size limit (1MB)
- Security headers: CSP, HSTS, X-Frame-Options DENY, no-referrer
- SSE connection limit (4 max)
- SSE timeout (20 minutes)
- `safe_write` validates paths stay within `allowed_write_paths` (default: `app/controllers`)
- Process groups for subprocess management (no orphans)
- Error messages sanitized to strip `RAILS_ROOT` paths

### Adding a new pipeline phase

1. Add the status string(s) to `ACTIVE_STATUSES` in `pipeline.rb` if the phase does async work
2. Add the orchestration method in `pipeline/orchestration.rb` following the existing pattern: read state under mutex, do work outside mutex, write results under mutex, catch exceptions and set `error`
3. Add a prompt template in `prompts.rb`
4. Add a route in `server.rb` with `try_transition` guard
5. Add a sidecar filename in the `discover_controllers` method if the phase produces persistent output
6. Update `renderWorkflowDetail()` in `index.html` to display the new phase's results
7. Add CSS classes for the new status dot colors

### Adding UI state that must persist across renders

morphdom handles this automatically for most cases. Scroll positions, focus, and input values are preserved because morphdom patches elements in-place rather than replacing them. For focused inputs specifically, the `onBeforeElUpdated` callback returns `false` to skip the update entirely.

If you need client-only state (like toggle open/closed), add it to `perController` via `getCtrlState()` — this state persists across SSE-triggered re-renders because it lives in JavaScript, not the DOM.

### Pipeline configuration

`Pipeline.new` accepts keyword arguments to customize discovery, sidecar storage, write permissions, and test path resolution. Defaults preserve the current hardening behavior:

| Option | Default | Purpose |
|---|---|---|
| `rails_root` | `"."` | Path to the target Rails app |
| `sidecar_dir` | `".harden"` | Directory name for sidecar files (created next to each target) |
| `allowed_write_paths` | `["app/controllers"]` | Directories (relative to `rails_root`) that `safe_write` and `write_sidecar` permit writes to |
| `discovery_glob` | `"app/controllers/**/*_controller.rb"` | Glob pattern (relative to `rails_root`) for target discovery |
| `discovery_excludes` | `["application_controller"]` | Basenames (without `.rb`) to skip during discovery |
| `test_path_resolver` | Default controller→test mapping | Lambda `(target_path, rails_root) → test_path or nil` for deriving test file paths |

Example for a workflow targeting views:

```ruby
Pipeline.new(
  rails_root: "/path/to/app",
  sidecar_dir: ".review",
  allowed_write_paths: ["app/controllers", "app/views"],
  discovery_glob: "app/views/**/*.html.erb",
  discovery_excludes: ["application"],
  test_path_resolver: ->(path, root) { ... }
)
```

### Testing

```bash
cd tools/harden-controller
bundle exec rake test
```

Tests use Minitest + rack-test. Pipeline methods that call `claude -p` are tested by stubbing `spawn_with_timeout`. The test helper is in `test/`.

## Common Commands

```bash
bundle install                      # Install dependencies
bundle exec ruby server.rb          # Start server (port 4567)
bundle exec rake test               # Run tests
RAILS_ROOT=../.. bundle exec ruby server.rb  # Point at parent Rails app
```
