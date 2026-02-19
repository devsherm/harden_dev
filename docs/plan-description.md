# Characteristics of a Great Ralph Loop Implementation Plan

A Ralph Loop implementation plan is the operational counterpart to a declarative spec. Where the spec defines *what done looks like*, the plan defines *the sequence of work to get there*. The loop agent picks the highest-priority incomplete item, implements it against the spec, and repeats. Every design decision in the plan should serve that cycle.

---

## 1. Atomic, Self-Contained Items

Each item in the plan should represent a single unit of work that can be implemented, tested, and committed in one loop iteration. If an item requires Claude Code to hold two competing concerns in its head simultaneously — say, building a model and wiring up its UI — it's too big. Split it.

A good litmus test: could the loop agent finish this item, and could someone reviewing the diff understand the entire change without needing context from the next item?

**Too coarse:** "Implement crew scheduling with validations and calendar UI"

**Right size:** "Add `CrewAssignment` model with `crew_id`, `schedule_entry_id`, `start_time`, `end_time` and overlap validation"

## 2. Explicit Priority Ordering

The plan must have an unambiguous priority order — not categories like "high/medium/low" but a strict sequence. The loop agent's decision logic is simple: find the first incomplete item and do it. If priorities are ambiguous, the agent either stalls or makes a bad choice that cascades.

Number items sequentially. If two items are truly independent, their relative order doesn't matter, but pick one anyway. Determinism beats flexibility in an automated loop.

## 3. Dependency Awareness Without Dependency Graphs

Avoid complex dependency DAGs. Instead, encode dependencies through ordering — if item 5 depends on item 3, item 3 appears first. The plan should read top-to-bottom as a viable implementation sequence.

When a dependency is non-obvious, state it inline: "Requires: `CrewAssignment` model from item 3." This gives the loop agent a sanity check without needing to parse a separate dependency structure.

## 4. Clear Completion Criteria Per Item

Each item needs a definition of done that the loop agent can evaluate. This bridges the plan back to the spec. Good completion criteria are:

- **Observable:** "Model exists with these columns and passes validation specs"
- **Testable:** "Endpoint returns 422 with overlap error when double-booking"
- **Bounded:** "Only the model layer — no controller or view changes"

Avoid criteria that require subjective judgment like "works correctly" or "handles edge cases well." The agent has no taste — give it a checklist.

## 5. Scope Boundaries on Every Item

State what each item does NOT include. This is critical in a loop because the agent is incentivized to be thorough, and thoroughness without boundaries means scope creep. If item 4 is "Add crew assignment controller," explicitly note "No authorization logic — that's item 7."

This also protects against a subtle failure mode: the agent implements something from a future item as part of the current one, then when it reaches that future item, it either duplicates work or gets confused by the existing implementation.

## 6. Consistent Reference to Spec Sections

Each plan item should reference the specific section of the spec it implements. This gives the loop agent a focused reading target rather than forcing it to re-read the entire spec each iteration.

Example: "Implements: Spec §3.2 — Crew Assignment Constraints"

This also makes the plan auditable — you can verify every spec section has corresponding plan items and every plan item traces to a spec requirement.

## 7. Incremental Buildability

The plan should produce a working (if incomplete) system at every step. After implementing item 1, the codebase should be green. After item 2, still green. This means:

- Database migrations come before the code that uses them
- Models come before controllers
- Core logic comes before edge case handling
- Backend comes before frontend (in most cases)

If the loop breaks mid-run — and it will sometimes — you want to resume from a coherent state, not a half-built feature that doesn't compile.

## 8. Escape Hatches and Decision Points

Some items involve decisions the agent shouldn't make autonomously — architectural choices with trade-offs, external service configurations, or business logic ambiguities. Mark these explicitly:

"**DECISION POINT:** Choose between STI and polymorphic association for equipment types. Implement whichever approach the spec favors; if the spec is ambiguous, use polymorphic association as the default."

Giving a default prevents the loop from stalling while still flagging the decision for your review.

## 9. File and Location Hints

Tell the agent where things go. In a modular monolith like a Rails engine-based architecture, the difference between `app/models/` and `engines/scheduling/app/models/` matters enormously. Include path hints:

"Create `CrewAssignment` model in `engines/scheduling/app/models/scheduling/`"

This prevents the most common loop failure: correct code in the wrong place, which silently breaks module boundaries and is expensive to fix later.

## 10. Testing Strategy Per Item

Specify the type and scope of tests expected with each item. Don't leave it to the agent's judgment — you'll get inconsistent coverage:

- "Unit tests for model validations"
- "Request spec for the create endpoint, happy path + overlap rejection"
- "No system/integration tests at this layer"

This also controls loop iteration time. If every item triggers the agent to write exhaustive integration tests, your loop runs slowly and tests become brittle.

## 11. Checkpointing and Progress Tracking

The plan should include a mechanism for tracking completion — even something as simple as a markdown checkbox list. The loop agent marks items complete as it finishes them, giving you a clear audit trail and giving the agent an unambiguous "what's next" signal.

```markdown
- [x] 1. Add CrewAssignment model with overlap validation
- [x] 2. Add migration for crew_assignments table
- [ ] 3. Add CrewAssignment controller with create/destroy
- [ ] 4. Add authorization rules for crew assignment management
```

## 12. Recovery Instructions

When something goes wrong — a test fails, a migration conflicts, a gem dependency breaks — the loop agent needs guidance. Include a brief recovery protocol at the top of the plan:

- "If tests fail after an item, fix the failing tests before moving to the next item."
- "If a migration conflict occurs, re-run `rails db:migrate:reset` in the test environment."
- "If an item cannot be completed as described, add a `BLOCKED:` note to the item and move to the next one."

Without this, a single failure can derail the entire loop run.

---

## The Relationship Between Plan and Spec

The spec is the constitution. The plan is the legislative agenda. They must stay synchronized but serve different purposes:

| Concern | Spec | Plan |
|---|---|---|
| Describes | Target state | Path to get there |
| Read by agent | For validation | For task selection |
| Changes when | Requirements change | Approach changes |
| Granularity | Domain concepts | Individual tasks |
| Ordering | Unordered (declarative) | Strictly ordered |

A great plan makes the loop boring — each iteration is a predictable, bounded unit of work that advances the system toward the state described in the spec. If your loop runs are surprising, the plan needs work.