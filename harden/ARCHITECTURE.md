# Harden Orchestrator

## Overview

A Sinatra-based orchestration server with a browser UI that coordinates parallel `claude -p` workers for hardening Rails controllers. No interactive Claude sessions — every Claude call is a stateless one-shot with full context passed in.

## Core Pattern: Fan-Out / Gather / Fan-Out

```
Phase 1: ANALYZE (parallel, autonomous)
  ┌─ claude -p → analyze projects_controller
  ├─ claude -p → analyze estimates_controller
  ├─ claude -p → analyze invoices_controller
  ├─ claude -p → analyze payments_controller
  └─ claude -p → analyze schedules_controller
          │
          ▼
Phase 2: DECIDE (human-in-the-loop, convergence)
  Browser UI shows all findings as cards.
  Human reviews, clicks [Explain] for ad-hoc claude -p,
  then approves/modifies/skips each screen.
          │
          ▼
Phase 3: HARDEN (parallel, autonomous)
  ┌─ claude -p → harden projects_controller (approved)
  ├─ claude -p → harden estimates_controller (modified)
  ├─ (skipped invoices_controller)
  ├─ claude -p → harden payments_controller (approved)
  └─ claude -p → harden schedules_controller (approved)
          │
          ▼
Phase 4: VERIFY (parallel, autonomous)
  Each completed screen gets a verification pass.
```

## Key Architectural Decisions

### Claude is never interactive
Every `claude -p` call is one-shot and stateless. Context is passed in via the prompt (analysis JSON, decision, controller file contents). This makes every call independently reproducible and debuggable.

### Sidecar files for per-screen state
Each screen gets its own notes/state directory next to the controller:
```
app/controllers/projects_controller.rb
app/controllers/.harden/projects_controller/
  ├── analysis.json      # Phase 1 output
  ├── notes.md           # Detailed findings log
  ├── decision.json      # Phase 2 human decision
  ├── hardened.json       # Phase 3 output
  └── verification.json   # Phase 4 output
```
No shared files = no collisions when running in parallel.

### Sub-agents can't spawn sub-agents, so we don't use them
Orchestration lives in Ruby, not in the LLM. Ruby handles parallelism, sequencing, and file I/O. Claude handles reasoning about code. Each stays in its lane.

### Real-time UI via SSE
The browser subscribes to `/events` (Server-Sent Events). The server pushes state updates as screens progress. No polling, no websocket complexity.

### Ad-hoc questions during convergence
During Phase 2, the human can click "Explain" or type a free-form question about any finding. This fires a one-shot `claude -p` with the analysis context and returns the answer. These are stateless — they don't affect the pipeline state.

## Endpoints

```
POST   /pipeline/start                    → Kick off Phase 1
GET    /events                            → SSE stream of pipeline state
POST   /decisions                         → Submit Phase 2 decisions, triggers Phase 3
POST   /screens/:screen/ask               → Ad-hoc question about a screen
POST   /screens/:screen/explain/:finding  → Pre-canned "explain this finding"
POST   /pipeline/retry/:screen            → Retry a failed screen
GET    /pipeline/status                   → Current state snapshot (non-streaming)
```

## Running

```bash
bundle install
ruby server.rb
# Open http://localhost:4567
```

## Integration with Claude Code

This orchestrator is designed to be launched from within a Rails project. It expects to find controllers in the standard Rails layout (`app/controllers/`). The `.harden/` sidecar directories are created next to the controllers being hardened.

Bring this into your project and adapt the prompts in `lib/prompts.rb` to match your hardening conventions.
