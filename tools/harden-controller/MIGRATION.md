# Migration Notes — Prepare for Enhance Mode

## Overview

The proposed spec introduces a dual-mode pipeline (hardening + enhance) with universal status prefixes, a staging→copy write pattern, and extended state machine guards. This migration prepares the existing hardening pipeline for enhance mode by making four changes:

1. **Status prefix rename** — All hardening statuses gain an `h_` prefix for global uniqueness.
2. **Staging→copy write pattern** — Agents write to a staging directory instead of returning file contents in JSON. The pipeline copies from staging to real paths via `safe_write`.
3. **Prompt phase prefixing** — `@prompt_store` keys and `VALID_PROMPT_PHASES` gain `h_` prefixes.
4. **Compound guard in `try_transition`** — Support Array guards for multi-status entry points.

This migration must be completed and verified (all tests pass) before any enhance mode code is added. Existing sidecar files on disk are not migrated — they become incompatible and should be deleted or ignored.

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
| `idle` | Global pipeline phase (`@state[:phase]`), not per-workflow |
| `discovering` | Global pipeline phase |
| `ready` | Global pipeline phase |
| `pending` | Initial workflow status before any mode-specific phase |
| `error` | Shared between modes — `mode` field disambiguates |

### Statuses that are NOT workflow statuses (do NOT rename)

These appear in the codebase but are **not** workflow status strings:

| String | Context | Why it stays |
|---|---|---|
| `"analyzed"` | JSON response from `claude -p` in analysis fixture (`orchestration_test_helper.rb`) | This is the agent's response status, not a workflow status. Workflow transitions to `awaiting_decisions`, not `analyzed`. |
| `"hardened"` | JSON response from `claude -p` in harden fixture | Agent response status. Workflow transitions to `hardened` (now `h_hardened`) but the response JSON field `"status": "hardened"` is the agent's self-report. |
| `"fixed"` | JSON response from fix_tests/fix_ci fixtures | Agent response status. Never used as a workflow status. |
| `"verified"` | JSON response from verification fixture | Agent response status. |
| `"pending"` / `"complete"` / `"error"` | Query subsystem (`@queries`) | Query statuses, not workflow statuses. |

**Gotcha**: An overzealous find-and-replace that renames `"hardened"` everywhere will break fixture assertions. Only rename workflow status assignments and comparisons — not JSON response fixture values.

### Affected Locations — Detailed

**`pipeline.rb`**:
- `ACTIVE_STATUSES` constant — rename all 7 entries
- `try_transition` — no hardcoded status strings to change (guards are passed by callers)
- `build_workflow` — add `mode: "hardening"` to the returned hash (this is a **new** field; there is no existing `mode` field)

**`pipeline/orchestration.rb`** (all status assignments and comparisons in phase methods):
- `run_analysis`: sets `awaiting_decisions` → `h_awaiting_decisions`
- `run_hardening`: checks/sets `awaiting_decisions`, `hardened`, `skipped` → `h_awaiting_decisions`, `h_hardened`, `h_skipped`
- `run_testing`: checks/sets `hardened`, `testing`, `fixing_tests`, `tested`, `tests_failed` → prefixed versions
- `run_ci_checks`: checks/sets `tested`, `ci_checking`, `fixing_ci`, `ci_passed`, `ci_failed` → prefixed versions
- `run_verification`: checks/sets `ci_passed`, `verifying`, `complete` → prefixed versions

**`server.rb`** (route guards in `try_transition` calls):
- `/decisions` route: guard `"awaiting_decisions"` → `"h_awaiting_decisions"`
- `/pipeline/retry-tests` route: guard `"tests_failed"` → `"h_tests_failed"`
- `/pipeline/retry-ci` route: guard `"ci_failed"` → `"h_ci_failed"`
- `/pipeline/retry` route: guard `"error"` → stays `"error"` (unchanged)

**`index.html`** — CSS classes:
- `.workflow-dot.analyzing` → `.workflow-dot.h_analyzing` (and all 15 renamed statuses)
- `.status-analyzing` → `.status-h_analyzing` (and all 15 renamed statuses)
- `.workflow-dot.pending`, `.workflow-dot.error`, `.workflow-dot.none` — unchanged

**`index.html`** — JS status comparisons:
- Active phase array: `['analyzing', 'hardening', 'testing', 'fixing_tests', 'ci_checking', 'fixing_ci', 'verifying']` → all prefixed
- Decision gate: `workflow.status === 'awaiting_decisions'` → `'h_awaiting_decisions'`
- Retry gates: `workflow.status === 'tests_failed'` → `'h_tests_failed'`, `'ci_failed'` → `'h_ci_failed'`
- Complete check: any comparison against `'complete'` → `'h_complete'`
- Skipped check: any comparison against `'skipped'` → `'h_skipped'`

**`index.html`** — JS status label mappings:
```javascript
// Before:
const labels = {
  'awaiting_decisions': 'awaiting decisions',
  'fixing_tests': 'fixing tests',
  'tests_failed': 'tests failed',
  'ci_checking': 'CI checking',
  'fixing_ci': 'fixing CI',
  'ci_passed': 'CI passed',
  'ci_failed': 'CI failed',
};

// After:
const labels = {
  'h_awaiting_decisions': 'awaiting decisions',
  'h_fixing_tests': 'fixing tests',
  'h_tests_failed': 'tests failed',
  'h_ci_checking': 'CI checking',
  'h_fixing_ci': 'fixing CI',
  'h_ci_passed': 'CI passed',
  'h_ci_failed': 'CI failed',
};
```

**`index.html`** — Header summary count keys (if the JS counts workflows by status, those keys change).

**Test files** — every status assertion and workflow seed:
- `orchestration_test_helper.rb`: `seed_workflow` default `status: "pending"` (unchanged), but any test that seeds with a specific status like `status: "awaiting_decisions"` or `status: "hardened"` must be renamed
- `pipeline_analysis_test.rb`: `assert_equal "awaiting_decisions"` → `"h_awaiting_decisions"`
- `pipeline_hardening_test.rb`: seeds `status: "awaiting_decisions"`, asserts `"hardened"`, `"skipped"` → all prefixed
- `pipeline_testing_test.rb`: seeds `status: "hardened"`, asserts `"tested"`, `"tests_failed"` → all prefixed
- `pipeline_ci_checks_test.rb`: seeds `status: "tested"`, asserts `"ci_passed"`, `"ci_failed"` → all prefixed
- `pipeline_verification_test.rb`: seeds `status: "ci_passed"`, asserts `"complete"` → all prefixed
- `try_transition_test.rb`: `"analyzing"`, `"complete"`, `"error"`, `"hardening"`, `"awaiting_decisions"` → all except `"error"` prefixed

### Implementation Notes

- Add `mode: "hardening"` to `build_workflow` return hash. This is a **new field** — no existing `mode` field to modify.
- This step is a mechanical find-and-replace — no behavioral changes.
- All existing tests should pass after the rename with updated status strings.
- Use the Appendix A inventory to verify completeness after the rename.

## Step 2: Staging→Copy Write Pattern

### What Changes

Currently, `claude -p` agents return file contents in the JSON response (`parsed["hardened_source"]`), and the pipeline writes via `safe_write(path, content)`. The staging→copy pattern replaces this:

1. Pipeline creates a staging directory: `.harden/<controller_name>/staging/`
2. The prompt instructs the agent to write modified files to the staging directory (mirroring app directory structure)
3. The agent uses `--dangerously-skip-permissions` to read app code and write to staging
4. The agent returns a JSON summary (metadata only — no file contents)
5. The pipeline walks the staging directory and copies each file to its real path via `safe_write`

### `--dangerously-skip-permissions` Flag

Add `--dangerously-skip-permissions` to the `claude -p` spawn command **unconditionally** in `claude_call`. All `claude -p` calls run in a controlled context. This is needed so agents can write files to the staging directory.

### Staging Lifecycle

- **Created** by the orchestration method before calling `claude_call`.
- **Cleaned** (rm -rf + recreate) before each fix attempt within a phase chain. This prevents stale files from a prior attempt being copied to real paths.
- **Copied** to real paths via `copy_from_staging` after each `claude_call` returns.
- Staging directories persist in the sidecar until the next pipeline reset or re-run.

### New Methods in `pipeline/sidecar.rb`

```ruby
# Construct the staging directory path within the sidecar.
# Returns: /path/to/.harden/<controller_name>/staging/
def staging_path(target_path)
  File.join(File.dirname(sidecar_path(target_path, "")), "staging")
end

# Walk the staging directory and copy each file to its real path via safe_write.
# staging_dir mirrors the app directory structure:
#   staging/app/controllers/posts_controller.rb → app/controllers/posts_controller.rb
def copy_from_staging(staging_dir)
  Dir.glob(File.join(staging_dir, "**", "*")).each do |staged_file|
    next if File.directory?(staged_file)
    relative = staged_file.sub("#{staging_dir}/", "")
    real_path = File.join(@rails_root, relative)
    FileUtils.mkdir_p(File.dirname(real_path))
    safe_write(real_path, File.read(staged_file))
  end
end
```

### Affected Locations

**`pipeline/orchestration.rb`**:
- `run_hardening`: Remove `parsed["hardened_source"]` extraction and direct `safe_write`. Replace with: create staging dir → pass staging path to prompt → call `claude_call` → call `copy_from_staging`. Capture `original_source` before `copy_from_staging` (same timing as current `safe_write`).
- `run_testing` (fix loop): Same pattern. Clean staging dir before each fix attempt.
- `run_ci_checks` (fix loop): Same pattern. Clean staging dir before each fix attempt.

**`pipeline/sidecar.rb`**:
- Add `staging_path(target_path)` helper.
- Add `copy_from_staging(staging_dir)` helper.

**`pipeline/claude_client.rb`**:
- Add `--dangerously-skip-permissions` to the `claude -p` spawn command in `claude_call`.

**`prompts.rb`**:
- `Prompts.harden`: Remove "return `hardened_source` in JSON response" instruction. Add "write modified files to staging directory at `<staging_dir>`" instruction. Add `staging_dir` parameter. JSON output schema changes to metadata-only.
- `Prompts.fix_tests`: Same changes. Add `staging_dir` parameter.
- `Prompts.fix_ci`: Same changes. Add `staging_dir` parameter.
- `Prompts.analyze` and `Prompts.verify`: No changes (read-only phases, no file writes).

**`index.html`**:
- Remove the inline source viewer code that reads `workflow.hardened?.hardened_source` and `workflow?.hardened?.hardened_source`. This code no longer has data to display.
- No replacement UI — the source viewer is removed entirely.

**No new routes.** The `GET /pipeline/:name/source` route is not needed — the operator does not need an in-browser source viewer.

### New `hardened.json` Sidecar Schema

Before (current):
```json
{
  "status": "hardened",
  "hardened_source": "class PostsController < ApplicationController\n  ...",
  "changes_made": ["Added before_action :authenticate_user!", "..."]
}
```

After (migration):
```json
{
  "status": "hardened",
  "summary": "Added authorization checks and input validation",
  "files_modified": [
    { "path": "app/controllers/posts_controller.rb", "action": "modified" }
  ],
  "changes_made": [
    "Added before_action :authenticate_user!",
    "Added params.permit filtering"
  ]
}
```

The `"status"` field is the agent's JSON response status (not a workflow status — see Step 1 gotcha). `hardened_source` is removed; `files_modified` and `summary` replace it.

### Test Strategy

**Key insight**: Orchestration tests stub `claude_call` and `copy_from_staging` separately. The staging→copy mechanism has its own unit test.

- **`orchestration_test_helper.rb`**: Remove `"hardened_source"` from `hardened_fixture`, `fix_tests_fixture`, and `fix_ci_fixture`. These return metadata-only hashes. Add `staging_dir` to fixture signatures if needed for prompt verification.
- **Orchestration tests** (`pipeline_hardening_test.rb`, `pipeline_testing_test.rb`, `pipeline_ci_checks_test.rb`): Stub `copy_from_staging` to write the expected content to the real controller path (same effect as the current `safe_write` from `hardened_source`). Stub `claude_call` to return metadata-only JSON. Assertions on `File.read(@ctrl_path)` still work because `copy_from_staging` is stubbed to produce the expected file.
- **New `copy_from_staging` unit test** (in `sidecar_test.rb`): Create a real staging directory with files in tmpdir. Call `copy_from_staging`. Assert files are copied to correct real paths via `safe_write`. Test that `safe_write` rejects paths outside `allowed_write_paths` during copy.
- **`HARDENED_SOURCE` constant**: Still used in tests — the stub for `copy_from_staging` writes it to the controller path.

### What Does NOT Change

- **`safe_write` signature** — stays `safe_write(path, content)`. The `grant_id:` parameter is deferred until LockManager is implemented.
- **`safe_write` validation logic** — path allowlist check unchanged.
- **`original_source` capture** — still captured before the copy step, same as today.

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

**`pipeline/orchestration.rb`** (this is where prompt_store assignments live, not pipeline.rb):
- `run_analysis`: `@prompt_store[name][:analyze]` → `@prompt_store[name][:h_analyze]`
- `run_hardening`: `@prompt_store[name][:harden]` → `@prompt_store[name][:h_harden]`
- `run_testing` (fix loop): `@prompt_store[name][:fix_tests]` → `@prompt_store[name][:h_fix_tests]`
- `run_ci_checks` (fix loop): `@prompt_store[name][:fix_ci]` → `@prompt_store[name][:h_fix_ci]`
- `run_verification`: `@prompt_store[name][:verify]` → `@prompt_store[name][:h_verify]`

**`pipeline.rb`**:
- `get_prompt` method (if it exists) — update any default keys
- `@prompt_store = {}` initialization — unchanged (just an empty hash)

**`server.rb`**:
- `VALID_PROMPT_PHASES` constant: `["analyze", "harden", "fix_tests", "fix_ci", "verify"]` → `["h_analyze", "h_harden", "h_fix_tests", "h_fix_ci", "h_verify"]`
- `GET /pipeline/:name/prompts/:phase` route — no logic changes, just validates against the updated constant

**`to_json` in `pipeline.rb`**:
- The enriched `prompts` hash keys change. Frontend sees `{ h_analyze: true, h_harden: true, ... }` instead of `{ analyze: true, harden: true, ... }`.

**`index.html`**:
- Prompt copy button URLs: JS `fetch` calls to `/pipeline/${name}/prompts/analyze` → `/pipeline/${name}/prompts/h_analyze`, etc.
- Any JS that reads the `prompts` field from SSE data to render "Copy Prompt" buttons must use the new keys.

**Test files**:
- `pipeline_analysis_test.rb`: `get_prompt(@ctrl_name, :analyze)` → `:h_analyze`
- `pipeline_verification_test.rb`: `get_prompt(@ctrl_name, :verify)` → `:h_verify`
- Any other test that reads from `@prompt_store` with the old keys.

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

**Why this order matters**: Step 1 touches almost every file. If Step 4 (staging→copy) were done first, the merge conflicts from Step 1's rename would be painful. Getting all the mechanical renames done first means the staging→copy diff is smaller and focused on behavioral changes.

## Gotchas

### Find-and-replace scope (Step 1)

The string `"hardened"` appears in three contexts:
1. **Workflow status** (`wf[:status] = "hardened"`) — rename to `"h_hardened"`
2. **JSON response field** (`parsed["hardened_source"]`, fixture `"status" => "hardened"`) — do NOT rename
3. **Sidecar filename** (`"hardened.json"`) — do NOT rename

Use targeted replacements, not global find-and-replace. The Appendix inventory distinguishes these contexts.

### Query statuses are not workflow statuses (Step 1)

The `@queries` subsystem uses `"pending"`, `"complete"`, and `"error"` for query status tracking. These are **not** workflow statuses and must not be renamed. They live in `@queries` (a separate Array), not in `@state[:workflows]`.

### `original_source` capture timing (Step 2)

Currently, `original_source` is captured before `safe_write` rewrites the controller file. After migration, it must be captured before `copy_from_staging` — same logical position. Verify the capture still happens before the copy step.

### Existing sidecar files on disk (Steps 1 & 2)

After deploying the migration, any `.harden/` directories from previous runs contain old-format sidecar files (unprefixed statuses, `hardened_source` in `hardened.json`). **These are not migrated.** The `load_existing_analysis` path may fail to parse them correctly. Operators should delete old `.harden/` directories before running the migrated pipeline. Document this in the commit message.

### `build_workflow` has no existing `mode` field (Step 1)

The current `build_workflow` does not include a `mode` field. Adding `mode: "hardening"` is a new field addition, not a rename. An executor searching for an existing `mode` assignment will find nothing — this is expected.

### `--dangerously-skip-permissions` is new (Step 2)

The current `claude_call` does not use `--dangerously-skip-permissions`. Adding it unconditionally is correct — all `claude -p` calls run in a controlled context and the flag is needed for staging writes.

## Review Decisions

The following decisions were made during the SPEC.proposed.md review:

- **`error` status stays unprefixed**: Shared between hardening and enhance modes. The `mode` field on the workflow disambiguates which mode the error occurred in.
- **Thin wrappers for shared phases**: When `shared_phases.rb` is extracted (enhance mode work, not this migration), existing method names (`run_hardening`, `run_testing`, etc.) remain as thin wrappers that delegate to shared helpers. Routes and tests don't change their call sites.
- **`safe_write` changes deferred to LockManager**: The `grant_id:` parameter, dual-allowlist logic, and grant validity/coverage checks ship with LockManager implementation. Rationale: (1) staging→copy is already a behavioral change to callers, (2) dual-allowlist is meaningless without a grant provider, (3) grant checks are tightly coupled to LockManager, (4) the migration already has enough scope.
- **Source viewer removed**: After staging→copy, there is no inline source viewer in the UI. The operator does not need to view hardened source in the browser — they can inspect the file on disk. No `GET /pipeline/:name/source` route is added.
- **Routes already match target format**: All existing routes already use JSON body params. No route normalization needed.
- **Compound guard added now**: The Array guard in `try_transition` is included in this migration despite being used only by enhance mode entry. It's small, additive, and independently testable.
- **Prompt phases prefixed now**: `VALID_PROMPT_PHASES` and `@prompt_store` keys gain `h_` prefixes during this migration for consistency with the status prefix convention.
- **Staging cleanup between fix attempts**: The staging directory is rm -rf'd and recreated before each fix agent runs, preventing stale files from a prior attempt.
- **`copy_from_staging` lives in `sidecar.rb`**: The staging walk+copy logic is added to `pipeline/sidecar.rb` alongside `safe_write` and other path helpers. Orchestration tests stub `copy_from_staging` independently from `claude_call`.
- **Existing sidecars not migrated**: Old `.harden/` directories from pre-migration runs are incompatible. Operators delete them before running the migrated pipeline.

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

## Appendix A: Status String Inventory

Every status string literal in the codebase, grouped by file. Use this to verify completeness after Step 1.

### `pipeline.rb`

| Location | String | Context | Rename? |
|---|---|---|---|
| `ACTIVE_STATUSES` | `"analyzing"`, `"hardening"`, `"testing"`, `"fixing_tests"`, `"ci_checking"`, `"fixing_ci"`, `"verifying"` | Active workflow statuses | Yes — all 7 |
| `build_workflow` | `"pending"` | Initial workflow status | No |
| `try_transition` | `"error"` | Error status set on guard failure | No |

### `pipeline/orchestration.rb`

| Method | Status strings used | Rename? |
|---|---|---|
| `run_analysis` | Sets `"awaiting_decisions"` | Yes |
| `run_hardening` | Reads `"awaiting_decisions"`, sets `"hardened"`, `"skipped"` | Yes |
| `run_testing` | Reads `"hardened"`, sets `"testing"`, `"fixing_tests"`, `"tested"`, `"tests_failed"` | Yes |
| `run_ci_checks` | Reads `"tested"`, sets `"ci_checking"`, `"fixing_ci"`, `"ci_passed"`, `"ci_failed"` | Yes |
| `run_verification` | Reads `"ci_passed"`, sets `"verifying"`, `"complete"` | Yes |
| All error handlers | Set `"error"` | No |

### `server.rb`

| Location | String | Context | Rename? |
|---|---|---|---|
| `POST /decisions` | `"awaiting_decisions"` | `try_transition` guard | Yes |
| `POST /pipeline/retry-tests` | `"tests_failed"` | `try_transition` guard | Yes |
| `POST /pipeline/retry-ci` | `"ci_failed"` | `try_transition` guard | Yes |
| `POST /pipeline/retry` | `"error"` | `try_transition` guard | No |
| `POST /pipeline/analyze` | `:not_active` | `try_transition` guard | No (symbol, not string) |

### `index.html` — CSS

| Selector pattern | Statuses used | Rename? |
|---|---|---|
| `.workflow-dot.<status>` | `pending`, `analyzing`, `awaiting_decisions`, `hardening`, `hardened`, `testing`, `fixing_tests`, `tested`, `tests_failed`, `ci_checking`, `fixing_ci`, `ci_passed`, `ci_failed`, `verifying`, `complete`, `skipped`, `error`, `none` | Yes for all except `pending`, `error`, `none` |
| `.status-<status>` | Same set as above (minus `none`) | Yes for all except `pending`, `error` |

### `index.html` — JavaScript

| Location | String(s) | Context | Rename? |
|---|---|---|---|
| Active phase array | `'analyzing'`, `'hardening'`, `'testing'`, `'fixing_tests'`, `'ci_checking'`, `'fixing_ci'`, `'verifying'` | Determines if workflow is active | Yes — all 7 |
| Decision gate | `'awaiting_decisions'` | Shows decision UI | Yes |
| Retry gates | `'tests_failed'`, `'ci_failed'` | Shows retry buttons | Yes |
| Complete check | `'complete'` | Shows completion UI | Yes |
| Skip check | `'skipped'` | Shows skipped UI | Yes |
| Status labels object | Keys: `'awaiting_decisions'`, `'fixing_tests'`, `'tests_failed'`, `'ci_checking'`, `'fixing_ci'`, `'ci_passed'`, `'ci_failed'` | Human-readable labels | Yes (keys only, not values) |
| Header summary counts | Various status strings used as keys for counting workflows | Yes |

### `index.html` — `hardened_source` references (Step 2)

| Location | Code | Action |
|---|---|---|
| Source viewer render | `workflow.hardened?.hardened_source` | Remove |
| Source copy function | `workflow?.hardened?.hardened_source` | Remove |

### Test files

| File | Status strings | Rename? |
|---|---|---|
| `orchestration_test_helper.rb` | `"pending"` (seed default) | No |
| `pipeline_analysis_test.rb` | Asserts `"awaiting_decisions"`, `"error"` | Yes (except `"error"`) |
| `pipeline_hardening_test.rb` | Seeds `"awaiting_decisions"`, asserts `"hardened"`, `"skipped"`, `"error"` | Yes (except `"error"`) |
| `pipeline_testing_test.rb` | Seeds `"hardened"`, asserts `"tested"`, `"tests_failed"`, `"pending"` | Yes (except `"pending"`) |
| `pipeline_ci_checks_test.rb` | Seeds `"tested"`, asserts `"ci_passed"`, `"ci_failed"`, `"pending"` | Yes (except `"pending"`) |
| `pipeline_verification_test.rb` | Seeds `"ci_passed"`, asserts `"complete"`, `"error"`, `"pending"` | Yes (except `"error"`, `"pending"`) |
| `try_transition_test.rb` | `"analyzing"`, `"complete"`, `"error"`, `"hardening"`, `"awaiting_decisions"` | Yes (except `"error"`) |

### Test fixtures (`orchestration_test_helper.rb`) — NOT workflow statuses

| Fixture | Field | Value | Rename? |
|---|---|---|---|
| `analysis_fixture` | `"status"` | `"analyzed"` | No — agent response |
| `hardened_fixture` | `"status"` | `"hardened"` | No — agent response |
| `hardened_fixture` | `"hardened_source"` | source content | Remove in Step 2 |
| `fix_tests_fixture` | `"status"` | `"fixed"` | No — agent response |
| `fix_tests_fixture` | `"hardened_source"` | source content | Remove in Step 2 |
| `fix_ci_fixture` | `"status"` | `"fixed"` | No — agent response |
| `fix_ci_fixture` | `"hardened_source"` | source content | Remove in Step 2 |
| `verification_fixture` | `"status"` | `"verified"` | No — agent response |
