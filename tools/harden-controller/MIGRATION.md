# Migration Notes — Prepare for Enhance Mode

## Overview

The proposed spec introduces a dual-mode pipeline (hardening + enhance) with universal status prefixes, a staging→copy write pattern, and extended state machine guards. This migration prepares the existing hardening pipeline for enhance mode by making four changes:

1. **Status prefix rename** — All hardening statuses gain an `h_` prefix for global uniqueness.
2. **Staging→copy write pattern** — Agents write to a staging directory instead of returning file contents in JSON. The pipeline copies from staging to real paths via `safe_write`.
3. **Prompt phase prefixing** — `@prompt_store` keys and `VALID_PROMPT_PHASES` gain `h_` prefixes.
4. **Compound guard in `try_transition`** — Support Array guards for multi-status entry points.

This migration must be completed and verified (all tests pass) before any enhance mode code is added.

## Step 1: Status Prefix Rename

### Rename Map

| Current (unprefixed) | New (`h_`-prefixed) |
|---|---|
| `analyzing` | `h_analyzing` |
| `awaiting_decisions` | `h_awaiting_decisions` |
| `hardening` | `h_hardening` |
| `hardened` | `h_hardened` |
| `testing` | `h_testing` |
| `fixing_tests` | `h_fixing_tests` |
| `tested` | `h_tested` |
| `ci_checking` | `h_ci_checking` |
| `fixing_ci` | `h_fixing_ci` |
| `ci_passed` | `h_ci_passed` |
| `ci_failed` | `h_ci_failed` |
| `verifying` | `h_verifying` |
| `complete` | `h_complete` |
| `tests_failed` | `h_tests_failed` |
| `skipped` | `h_skipped` |

### Statuses that do NOT change

| Status | Reason |
|---|---|
| `idle` | Global pipeline phase, not per-workflow |
| `discovering` | Global pipeline phase |
| `ready` | Global pipeline phase |
| `pending` | Initial workflow status before any mode-specific phase |
| `error` | Shared between modes — `mode` field disambiguates |

### Affected Locations

- **`pipeline.rb`**: `ACTIVE_STATUSES` constant, `try_transition` guard strings, `build_workflow` (add `mode: "hardening"`)
- **`pipeline/orchestration.rb`**: All status assignments and checks in phase methods (~30 occurrences)
- **`server.rb`**: Route guards in `try_transition` calls (e.g., `"awaiting_decisions"` → `"h_awaiting_decisions"`, `"tests_failed"` → `"h_tests_failed"`)
- **`index.html`**: CSS class names (`.workflow-dot.analyzing` → `.workflow-dot.h_analyzing`), status string comparisons in JS, status label mappings, header summary count keys
- **All test files**: Status assertions, workflow seeding in `orchestration_test_helper.rb`, fixture factories

### Implementation Notes

- Add `mode: "hardening"` to `build_workflow` return hash.
- This step is a mechanical find-and-replace — no behavioral changes.
- All existing tests should pass after the rename with updated status strings.

## Step 2: Staging→Copy Write Pattern

### What Changes

Currently, `claude -p` agents return file contents in the JSON response (`parsed["hardened_source"]`), and the pipeline writes via `safe_write(path, content)`. The staging→copy pattern replaces this:

1. Pipeline creates a staging directory: `.harden/<controller_name>/staging/`
2. The prompt instructs the agent to write modified files to the staging directory (mirroring app directory structure)
3. The agent uses `--dangerously-skip-permissions` to read app code and write to staging
4. The agent returns a JSON summary (metadata only — no file contents)
5. The pipeline walks the staging directory and copies each file to its real path via `safe_write`

### Affected Locations

- **`pipeline/orchestration.rb`**:
  - `run_hardening`: Remove `parsed["hardened_source"]` handling. Instead, create staging dir, pass staging path to prompt, walk staging dir after `claude_call`, copy via `safe_write`.
  - `run_testing` (fix loop): Same pattern — fix agent writes to staging, pipeline copies.
  - `run_ci_checks` (fix loop): Same pattern.
- **`pipeline/sidecar.rb`**: Add `staging_path(source_path)` helper to construct `.harden/<ctrl>/staging/`. Add `copy_from_staging(staging_dir, grant_id: nil)` to walk and copy.
- **`prompts.rb`**: Update `harden`, `fix_tests`, `fix_ci` prompts from "return `hardened_source` in JSON" to "write files to staging directory at `<path>`". Prompts gain a `staging_dir` parameter.
- **`index.html`**: Remove inline source viewer (`renderSourceViewer`) that relied on `workflow.hardened.hardened_source`. Replace with an on-demand source route (see below).
- **`server.rb`**: Add `GET /pipeline/:name/source` route that reads the current controller file from disk and returns it. The frontend fetches this when the user clicks "View source".
- **Test fixtures** (`orchestration_test_helper.rb`): Remove `"hardened_source"` from fixture hashes. Tests need to create staging directories with files instead of returning content in JSON mocks.

### Surprises

- **Frontend source viewer disappears from the SSE payload.** The current UI shows hardened source inline because it's part of the workflow state broadcast. After this change, source is fetched on-demand via a new route. The source viewer still works, but it requires a click instead of being always-visible.
- **`workflow[:hardened]` no longer contains `hardened_source`.** Any code that reads `workflow[:hardened]["hardened_source"]` breaks. The `hardened` field becomes a metadata summary (changes made, files modified) rather than a source dump.
- **Fix loops change behavior.** Currently, fix agents return `parsed["hardened_source"]` and the pipeline writes it directly. After staging→copy, fix agents write to the same staging directory, and the pipeline re-copies. The staging directory is reused across fix attempts within a phase chain.
- **Test changes are substantial.** Every test that stubs `claude_call` to return `{"hardened_source": "..."}` needs reworking. The stubs must instead write files to the staging directory. This is the largest test change in the migration.

### What Does NOT Change

- **`safe_write` signature** — stays `safe_write(path, content)`. The `grant_id:` parameter is deferred until LockManager is implemented. Rationale: staging→copy is already a behavioral change to `safe_write`'s callers; adding a dead parameter conflates two concerns. The dual-allowlist logic and grant checks are tightly coupled to LockManager and have no caller until enhance mode exists.
- **`safe_write` validation logic** — path allowlist check unchanged.
- **Sidecar output files** — `hardened.json` still written, but its contents change from `{hardened_source: "...", ...}` to `{files_modified: [...], summary: "...", ...}`.

## Step 3: Prompt Phase Prefixing

### What Changes

`@prompt_store` keys and `VALID_PROMPT_PHASES` gain `h_` prefixes:

| Current | New |
|---|---|
| `:analyze` | `:h_analyze` |
| `:harden` | `:h_harden` |
| `:fix_tests` | `:h_fix_tests` |
| `:fix_ci` | `:h_fix_ci` |
| `:verify` | `:h_verify` |

### Affected Locations

- **`pipeline.rb`**: `@prompt_store` key assignments in `run_analysis`, `run_hardening`, `run_testing`, `run_ci_checks`, `run_verification`
- **`server.rb`**: `VALID_PROMPT_PHASES` constant, `GET /pipeline/:name/prompts/:phase` route
- **`index.html`**: Prompt copy button URLs (JS `fetch` calls to the prompts route)
- **`pipeline/orchestration.rb`**: `@prompt_store[name][:analyze]` → `@prompt_store[name][:h_analyze]`, etc.
- **`to_json`**: The enriched `prompts` hash keys change (frontend sees `h_analyze: true` instead of `analyze: true`)

## Step 4: Compound Guard in `try_transition`

### What Changes

Add Array guard support to `try_transition`. When `guard` is an Array, the transition succeeds if the workflow's current status matches any string in the array.

```ruby
case guard
when :not_active
  # ... existing logic ...
when Array
  return [false, "No workflow for #{name}"] unless wf
  return [false, "#{name} is #{status}, expected one of #{guard.join(', ')}"] unless guard.map(&:to_s).include?(status)
  wf[:status] = to
  wf[:error] = nil
else
  # ... existing named guard logic ...
end
```

### Affected Locations

- **`pipeline.rb`**: `try_transition` method (add `when Array` branch)
- **`test/try_transition_test.rb`**: Add tests for compound guard (success when matching any, failure when matching none)

### Notes

This is a small, additive change with no dependencies on enhance mode code. Adding it now makes the state machine fully spec-compliant before enhance work begins. The only caller during migration is for enhance mode entry (`["h_complete", "e_enhance_complete"]`), but the guard type is generic and testable independently.

## Sequencing

All four steps can be done in a single pass or as sequential commits. Recommended order:

1. **Status prefix rename** — Mechanical, high-confidence. Run tests to verify.
2. **Compound guard** — Small, additive. Run tests.
3. **Prompt phase prefixing** — Mechanical, low-risk. Run tests.
4. **Staging→copy refactor** — Behavioral change, largest diff. Run tests.

Steps 1-3 are purely mechanical (rename + small additions). Step 4 is the only behavioral change and should be a separate commit for reviewability.

## Review Decisions

The following decisions were made during the SPEC.proposed.md review:

- **`error` status stays unprefixed**: Shared between hardening and enhance modes. The `mode` field on the workflow disambiguates which mode the error occurred in.
- **Thin wrappers for shared phases**: When `shared_phases.rb` is extracted (enhance mode work, not this migration), existing method names (`run_hardening`, `run_testing`, etc.) remain as thin wrappers that delegate to shared helpers. Routes and tests don't change their call sites.
- **`safe_write` changes deferred to LockManager**: The `grant_id:` parameter, dual-allowlist logic, and grant validity/coverage checks ship with LockManager implementation. Rationale: (1) staging→copy is already a behavioral change to callers, (2) dual-allowlist is meaningless without a grant provider, (3) grant checks are tightly coupled to LockManager, (4) the migration already has enough scope.
- **Source viewer becomes on-demand**: After staging→copy, the frontend fetches source via `GET /pipeline/:name/source` instead of reading it from the SSE state payload. The source viewer still works but requires a user action instead of being always-visible.
- **Routes already match target format**: All existing routes already use JSON body params. No route normalization needed.
- **Compound guard added now**: The Array guard in `try_transition` is included in this migration despite being used only by enhance mode entry. It's small, additive, and independently testable.
- **Prompt phases prefixed now**: `VALID_PROMPT_PHASES` and `@prompt_store` keys gain `h_` prefixes during this migration for consistency with the status prefix convention.

## Deferred to Enhance Mode Implementation

The following are explicitly **not** part of this migration:

- `pipeline/shared_phases.rb` extraction (thin wrappers are the migration boundary)
- `pipeline/enhance_orchestration.rb`
- `pipeline/lock_manager.rb` and `pipeline/scheduler.rb`
- `safe_write` grant_id parameter and dual-allowlist logic
- `enhance_sidecar_dir` and `enhance_allowed_write_paths` kwargs in `Pipeline.new`
- `api_call` method and `@api_semaphore`/`@api_slots` for Claude Messages API
- Discovery scanning of `.enhance/` sidecar directories
- All enhance mode UI (research topics, item review, batch planning, lock visualization)
- All enhance mode routes (`/enhance/*`)
- All enhance mode test files
