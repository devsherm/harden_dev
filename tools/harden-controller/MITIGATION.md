# Execution Risk Mitigations

Items that the plan audit flagged as high-risk for Sonnet execution but cannot be further decomposed. Each entry describes why the risk exists and how to mitigate it.

## Item 19 — Batch execution phases (E7-E10)

**Risk**: Not inherent complexity — the item delegates to shared phases (item 10a-10d) with enhance-specific parameters. The real risk is upstream bugs surfacing here. If LockManager grant lifecycle, shared phase parameterization, or enhance prompts have latent issues, they'll manifest as batch execution failures that look like item 19 bugs but aren't.

**Mitigation**:

- Stub all upstream dependencies in tests: LockManager (`try_acquire` returns a mock grant, `renew` is a no-op, `release` is a no-op), shared phases (`shared_apply`/`shared_test`/`shared_ci_check`/`shared_verify` are stubbed to set expected workflow state), and prompts (not called directly — shared phases handle that).
- Test only the batch execution logic itself: sequential batch ordering, `current_batch_id` tracking, grant acquire/renew/release lifecycle, `e_enhance_complete` on last batch, `e_tests_failed`/`e_ci_failed` with grant release.
- If tests pass but integration fails, the bug is in an upstream item (likely item 10a-10d parameterization or item 5 LockManager), not in the batch execution orchestration.

## Items 22-23 — Frontend (status rendering + interactive panels)

**Risk**: No automated test coverage. `index.html` is a single-file SPA tested manually. Bugs in morphdom diffing, status label mappings, or SSE-driven re-renders won't be caught by `bundle exec rake test`.

**Mitigation — manual verification checklist**:

### Item 22 (status rendering)

- [ ] Load UI with a mix of hardening and enhance workflows in different states
- [ ] Verify all `e_`-prefixed statuses show correct dot colors (not default/missing)
- [ ] Verify status labels object maps every enhance status to a human-readable name
- [ ] Verify mode indicator (hardening vs enhance) appears in sidebar for each controller
- [ ] Verify "Start Enhance" button appears only for `h_complete` controllers
- [ ] Verify header summary counts include enhance active statuses
- [ ] Open browser console — no JS errors on render

### Item 23 (interactive panels)

- [ ] Research panel: "USE API" button triggers POST, manual paste textarea submits, "Reject" button works, completion indicator updates
- [ ] Item review panel: items sorted correctly, prior-decision defaults applied (new→TODO, deferred→DEFER, rejected→REJECT), submit sends correct payload
- [ ] Batch plan panel: "Approve" and "Reject with Notes" buttons trigger correct POSTs, write targets displayed
- [ ] Batch progress panel: current batch status visible, phase progress indicator updates, retry buttons appear for `e_tests_failed`/`e_ci_failed`
- [ ] Lock visualization: active grants list, queue depth, contention indicators render
- [ ] morphdom focus preservation: type in a textarea, wait for SSE re-render, verify cursor position and text preserved
- [ ] Open browser console — no JS errors during any panel interaction

### Optional smoke test

Consider adding a minimal JS test that verifies `render()` doesn't throw when fed mock SSE data containing enhance workflow states. This can be a standalone HTML file that imports the render function with mock data and asserts no exceptions. Not required for the plan items, but reduces risk of silent rendering failures.
