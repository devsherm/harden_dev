# Harden Controller

A browser-based orchestrator that uses Claude to analyze, evaluate, and modify Rails controllers — with human-in-the-loop approval and automated verification. Currently configured for security hardening, but the pipeline is task-agnostic: swap the prompts and it works for feature evaluation, code review, refactoring, or any controller-scoped task.

Designed for a single operator over ngrok.

## How It Works

Point the tool at a Rails project. It discovers all controllers, then for each one you select, it runs a multi-phase pipeline:

1. **Analyze** — Claude reads the controller source and produces a structured JSON report of findings. (Currently: security issues — authorization gaps, missing validations, input sanitization, rate limiting, etc.)
2. **Decide** — You review findings in the browser. Toggle individual findings on/off, dismiss out-of-scope blockers (findings that span beyond the controller file), ask clarifying questions.
3. **Apply** — Claude rewrites the controller to address approved findings. The modified source is written directly to disk.
4. **Test** — Runs the controller's test file (or full test suite). If tests fail, Claude attempts automated fixes (up to 2 rounds).
5. **CI Check** — Runs RuboCop, Brakeman, bundler-audit, and importmap audit. Claude attempts automated fixes for RuboCop/Brakeman failures (up to 2 rounds).
6. **Verify** — Claude compares original vs modified source against the analysis to confirm findings were addressed and no regressions introduced.

Each phase produces a sidecar JSON file next to the controller (in a `.harden/` directory) so results persist across restarts. The task behavior is driven by prompt templates in `prompts.rb` — the pipeline infrastructure is reusable across different tasks.

## Quick Start

```bash
cd tools/harden-controller
bundle install

# Start the server pointed at your Rails project
RAILS_ROOT=/path/to/your/rails/app bundle exec ruby server.rb
```

Open the printed URL in your browser. If exposed over ngrok, a passcode is auto-generated and printed to stderr.

### With ngrok

```bash
# Terminal 1
RAILS_ROOT=../.. bundle exec ruby server.rb

# Terminal 2
ngrok http 4567
```

Use the ngrok URL and the printed passcode to log in.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `RAILS_ROOT` | `.` | Path to the target Rails project |
| `HARDEN_PASSCODE` | auto-generated | Login passcode (required when binding non-localhost) |
| `PORT` | `4567` | Server port (falls back to random if in use) |
| `SESSION_SECRET` | auto-generated | Session encryption key |
| `CORS_ORIGIN` | none | Enable CORS for a specific origin (local dev only) |

## Requirements

- Ruby 3.x
- `claude` CLI installed and authenticated (used via `claude -p`)
- Bundler (`gem install bundler`)

## Testing

```bash
bundle exec rake test
```
