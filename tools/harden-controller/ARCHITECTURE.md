# Harden Orchestrator

## Overview

A Sinatra-based orchestration server with a browser UI that coordinates `claude -p` calls for hardening a single Rails controller at a time. No interactive Claude sessions — every Claude call is a stateless one-shot with full context passed in.

## Pipeline: One Controller at a Time

```
Discovery (startup)
  → Scan app/controllers/ for *_controller.rb
  → Populate controllers list
          │
          ▼
Selection (human picks one)
  → "Analyze" or "Use Existing" from the UI
          │
          ▼
Phase 1: ANALYZE (single claude -p call)
  → Analyze the selected controller
  → Write analysis.json sidecar
          │
          ▼
Phase 2: DECIDE (human-in-the-loop)
  → UI shows findings as toggleable cards
  → Human reviews, clicks [Explain] / [Ask] for ad-hoc claude -p
  → Approves/skips individual findings, then submits
          │
          ▼
Phase 3: HARDEN (single claude -p call)
  → Apply approved findings to the controller
  → Write hardened.json + hardened_preview.rb sidecars
          │
          ▼
Phase 4: VERIFY (single claude -p call)
  → Compare original vs hardened source
  → Write verification.json sidecar
          │
          ▼
Complete → Reset to harden another controller
```

## State Shape

```ruby
@state = {
  phase: "idle",            # one of: idle, discovering, awaiting_selection, analyzing,
                            #         awaiting_decisions, hardening, verifying, complete, errored
  controllers: [            # populated during discovery, read-only after
    { name:, path:, full_path:, existing_analysis_at: }
  ],
  screen: {                 # the single active controller, or nil before selection
    name:, path:, full_path:, status:, analysis:, decision:, hardened:, verification:, error:
  } | nil,
  errors: [],
  started_at:, completed_at:
}
```

## Key Architectural Decisions

### One controller at a time

The UI selects a single controller. All pipeline phases operate on that one `screen`. No thread pools, no mutex, no parallel fan-out. The only concurrency is a single background thread (started by server.rb) running the pipeline so SSE can stream progress — MRI's GIL makes hash assignment atomic, so the SSE reader always sees consistent state.

Convention: always assign data fields *before* status fields (e.g., `screen[:analysis] = parsed` before `screen[:status] = "analyzed"`) so any SSE snapshot with a given status always has the corresponding data.

### Claude is never interactive

Every `claude -p` call is one-shot and stateless. Context is passed in via the prompt (analysis JSON, decision, controller file contents). This makes every call independently reproducible and debuggable.

### Sidecar files for per-controller state

Each controller gets its own state directory:
```
app/controllers/blog/posts_controller.rb
app/controllers/blog/.harden/posts_controller/
  ├── analysis.json        # Phase 1 output
  ├── hardened.json         # Phase 3 output
  ├── hardened_preview.rb   # Phase 3 hardened source (preview, not applied)
  └── verification.json     # Phase 4 output
```

### Real-time UI via SSE

The browser subscribes to `/events` (Server-Sent Events). The server pushes state updates as the pipeline progresses. No polling, no websocket complexity.

### Ad-hoc questions during decisions

During Phase 2, the human can click "Explain" or type a free-form question. This fires a one-shot `claude -p` with the analysis context and returns the answer. These are stateless — they don't affect the pipeline state.

## Endpoints

```
GET    /                              → Static UI (index.html)
GET    /events                        → SSE stream of pipeline state
GET    /pipeline/status               → Current state snapshot (non-streaming)
POST   /pipeline/analyze              → Select + analyze a controller
POST   /pipeline/load-analysis        → Select + load cached analysis from sidecar
POST   /pipeline/reset                → Reset to selection (re-discovers controllers)
POST   /pipeline/retry                → Retry analysis on the active controller
POST   /decisions                     → Submit decision, triggers hardening + verification
POST   /ask                           → Free-form question about the active controller
POST   /explain/:finding_id           → Explain a specific finding
POST   /shutdown                      → Stop the server
```

## Running

```bash
cd tools/harden-controller
bundle install
RAILS_ROOT=/path/to/your/rails/app bundle exec ruby server.rb
# Open http://localhost:4567
```

`RAILS_ROOT` defaults to `.` (the current working directory) if not set.
