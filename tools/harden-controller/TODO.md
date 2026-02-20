# Harden Controller — TODO

## Bugs

- [x] **Fix stale source used in verification after test/CI fixes** [LOW]
  `pipeline/orchestration.rb:463` — Verification reads `hardened_source` from the workflow hash (set during initial hardening), but fix-tests and fix-ci cycles write updated source to disk. Verifier compares analysis against a version that may have been revised 2-4 times. Should read from disk instead.

- [x] **Return proper error status from ask/explain routes** [LOW]
  `server.rb:386-389`, `pipeline/orchestration.rb:499` — `ask_question` and `explain_finding` return `{ error: "..." }` hashes when there's no workflow, but the route returns them with HTTP 202. Should check for `result[:error]` and return 404/422.

- [x] **Remove dead `select_controller` method** [LOW]
  `pipeline/orchestration.rb:92-99` — No route calls this. `/pipeline/analyze` uses `try_transition` + `run_analysis` directly.

## Concurrency

- [x] **Add synchronization to `AUTH_ATTEMPTS`** [LOW]
  `server.rb:48` — Plain Hash accessed from multiple Puma threads with read-check-write patterns in `POST /auth`. Wrap in a Mutex or use `Concurrent::Hash`. Practical impact is low (slightly off rate-limit counters) but architecturally incorrect.

## Security

- [x] **Whitelist phase parameter in prompt route** [LOW]
  `server.rb:308` — `params[:phase].to_sym` converts arbitrary user input to symbols. Use a string key or whitelist against known phases (`analyze`, `harden`, `fix_tests`, `fix_ci`, `verify`).

- [x] **Document SSE thread starvation margin** [LOW]
  `server.rb:315-316` — `SSE_MAX_CONNECTIONS = 4` with Puma's default 5 threads means 80% capacity consumed by SSE. Passcode auth mitigates this. Add a comment noting that bumping `SSE_MAX_CONNECTIONS` requires bumping Puma threads too.

## API Design

- [x] **Add path validation to `write_sidecar`** [LOW]
  `pipeline/sidecar.rb:16-19` — `safe_write` validates paths stay within `app/controllers/`, but `write_sidecar` does not. Both take controller paths from discovered files so it's safe in practice, but the asymmetry is surprising.

## Frontend

- [x] **Add try/catch around SSE JSON parsing** [LOW]
  `index.html:618` — `JSON.parse(e.data)` with no error handling. If the server sends malformed data (e.g., during shutdown), the SSE handler silently breaks.
