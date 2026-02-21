# Migration Notes — Hardening Status Prefix Rename

## Overview

The proposed spec introduces universal status prefixes (`h_` for hardening, `e_` for enhance) to make every status string globally unique and self-documenting. This requires renaming all existing unprefixed hardening statuses to `h_`-prefixed equivalents.

This is a **foundational change** that must be completed before enhance mode features are added, as enhance mode depends on the prefix convention.

## Status Rename Map

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
| `error` | Shared between modes — `mode` field disambiguates |

## Affected Locations

The rename touches every file that references status strings:

- **`pipeline.rb`**: `ACTIVE_STATUSES` constant, `try_transition` guard strings, `to_json` serialization
- **`pipeline/orchestration.rb`**: All status assignments and checks in phase methods
- **`pipeline/process_management.rb`**: Any status checks in `safe_thread` error handling
- **`server.rb`**: Route guards in `try_transition` calls (e.g., `"awaiting_decisions"` → `"h_awaiting_decisions"`)
- **`index.html`**: CSS class mappings for status dot colors, conditional rendering based on status strings, button enable/disable logic
- **`prompts.rb`**: If any prompt templates reference status strings
- **All test files**: Status assertions, workflow seeding, fixture factories

**Not affected** (does not exist yet — part of enhance mode, not this migration):
- `pipeline/shared_phases.rb`
- `pipeline/enhance_orchestration.rb`
- `pipeline/lock_manager.rb`
- `pipeline/scheduler.rb`

## Implementation Notes

- Add `mode` field (`"hardening"`) to workflow entries during initialization
- This rename is a mechanical find-and-replace — no behavioral changes
- All existing tests should pass after the rename with updated status strings
- `VALID_PROMPT_PHASES` should also be prefixed (e.g., `"analyze"` → `"h_analyze"`) for consistency, though this is less critical since prompt phases are internal identifiers

## Sequencing

This migration is **Step 0** — it must be completed and verified (all tests pass) before any enhance mode code is added. The enhance mode implementation assumes all hardening statuses are already `h_`-prefixed.

Rationale: Doing the rename as a standalone change keeps the diff reviewable and ensures the existing test suite validates the mechanical rename independently of new feature code.

## Review Decisions (from spec review)

The following decisions were made during the SPEC.proposed.md review and affect this migration:

- **`error` status stays unprefixed**: Shared between hardening and enhance modes. The `mode` field on the workflow disambiguates which mode the error occurred in.
- **`try_transition` compound guard support**: After this migration, `try_transition` will need a new guard type (Array of status strings) for enhance mode entry. This is part of the enhance implementation, not this migration — but `try_transition` should be structured to make this easy to add.
