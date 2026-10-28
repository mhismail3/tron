---
name: tron-test-confidence
description: Judge whether an integration or E2E test proves its behavior, clean up tests that cannot fail for the right reason, and diagnose timing or lifecycle flakes at real boundaries. Use for test cleanup, flaky runs, and coverage claims.
---

# Test confidence

Apply [project rules](../../../AGENTS.md): keep the fewest faithful oracles.
The four bounded production-logic groups named in the charter are allowed;
actual wiring, I/O, authority, ordering and rendering still need real boundaries.

## Judge a test

Trace the product risk to the real entrypoint, its owner, the setup, the action,
and the assertion. Ask whether the test would fail if the real behavior broke.
A test that only reasserts a mock, fixture constant, source text or private call
proves nothing. Observe a public result: durable bytes, admission, projection
identity or the presented interface. Rendered text, targets and chrome need
rendered witnesses; whole-tree equality is not an interaction oracle. Mark any boundary the suite does not cross as a gap, and do not
claim coverage for it.

## Diagnose a flake

Preserve the first failure, its seed or ordering, its configuration, and its log.
Separate a scheduling assumption from a production race using the owning event.
Prefer bounded waits on that event to fixed sleeps. Confirm cleanup on success,
failure, timeout, and cancellation. Isolate files, ports, processes, global state,
and simulator lanes. Never loosen an assertion, update a golden, add a retry, or
skip a case to obtain green. Compare against the unchanged base before calling a
failure pre-existing.

## Report

State the tests that ran with their counts, the failures and skips, and the
boundaries that remain untested. A green run is not a complete risk assessment.
