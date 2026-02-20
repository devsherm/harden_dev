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
- **`pipeline/shared_phases.rb`**: Status parameters passed to shared helpers
- **`pipeline/process_management.rb`**: Any status checks in `safe_thread` error handling
- **`server.rb`**: Route guards in `try_transition` calls (e.g., `"awaiting_decisions"` → `"h_awaiting_decisions"`)
- **`index.html`**: CSS class mappings for status dot colors, conditional rendering based on status strings, button enable/disable logic
- **`prompts.rb`**: If any prompt templates reference status strings
- **All test files**: Status assertions, workflow seeding, fixture factories

## Implementation Notes

- Add `mode` field (`"hardening"`) to workflow entries during initialization
- This rename is a mechanical find-and-replace — no behavioral changes
- All existing tests should pass after the rename with updated status strings
