---
name: tron-test-confidence
description: Evaluate and strengthen Tron tests through behavioral oracles, lifecycle isolation, and negative controls. Use for test cleanup, flaky failures, coverage claims, and mechanism ablation.
---

# Test confidence

Apply [project rules](../../../AGENTS.md). Match test changes and experiments to
the user's authorization; a test audit alone does not authorize source mutation.

## Find what the test actually proves

Map the affected product risk to its production entrypoint, owner, test setup,
action, and assertion. Inspect runner/configuration wiring as well as test bodies.
Ask whether the assertion would fail if the real behavior broke while mocks,
recorders, helper return values, and internal counters remained unchanged.

Prefer an independently observable outcome: durable bytes, admitted/rejected
operations, cancellation of the exact lease, or the actual presented interface.
Follow the [testing policy](../../../AGENTS.md#testing-policy): prefer E2E
coverage, and keep an isolated test only when it targets a written-down failure
mode that catches a real bug the E2E tests miss. Mark gaps between those
boundaries.
For chat layout, use the owning native geometry/identity harness and regressions;
command consumption, projection installation, cached geometry, and lazy estimated
offsets do not prove a rendered frame. Observe settlement after ownership changes.

Choose **KEEP / UPDATE / MERGE / DELETE / ADD** for affected tests. Delete
self-reasserting, obsolete, or redundant checks only after identifying surviving
oracles for still-required behavior. If no trustworthy oracle remains, report the
gap rather than claiming equivalent coverage. A rare critical regression can
justify a test even when it has never failed recently.

## Make a disputed claim falsifiable

When authorized, freeze a bounded mutation or ablation before running it:

1. Name the hypothesis, exact production path, baseline revision, representative
   scenarios, independent oracle, expected failure, and stop/retention rules.
2. Identify run-owned edits, fixtures, processes, and artifacts; establish an exact
   restoration path that cannot overwrite unrelated work.
3. Run the baseline. Change only the challenged mechanism. Include a known-bad
   control that breaks the intended behavior, and verify that path actually runs.
4. Capture results without changing assertions to favor the candidate. Restore
   the baseline and verify restoration; use an A/B/A sequence when environment or
   ordering could explain the result.

A known-bad control passing exposes an oracle gap, not safe production deletion.
Retain only an authorized, behavior-preserving change. Performance comparisons
belong to [performance](../tron-performance/SKILL.md), not pass-count comparisons.

## Diagnose timing and lifecycle failures

Preserve the first failure, selection, seed/order, configuration, and logs.
Distinguish scheduling assumptions from a production race using the owning
observable event. Prefer controlled clocks and bounded registration/completion
waits to fixed sleeps or repeated scheduler yields. Verify cleanup on success,
throw, timeout, cancellation, and partial initialization; isolate files, ports,
processes, global state, and simulator leases.

Start with the failing owner; compare isolated and in-suite behavior only as
needed to test a hypothesis. A narrow pass does not refute a wider failure.
Never loosen a meaningful assertion, update a golden, add retries, or skip a case
merely to obtain green. Separate pre-existing failures through a controlled
baseline rather than assumption.

Report actual executed counts (check selectors did not run zero tests), failures,
skips, experimental controls and restoration, remaining oracles after deletion,
and untested environments. A green suite is not a complete risk assessment.
