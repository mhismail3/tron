---
name: tron-test-confidence
description: Judge whether an integration or E2E test proves its behavior, clean up tests that cannot fail for the right reason, and diagnose timing or lifecycle flakes at real boundaries. Use for test cleanup, flaky runs, and coverage claims.
---

# Test confidence

Apply [project rules](../../../AGENTS.md). Tron validates with integration and E2E
tests at real boundaries; unit tests are not kept
([testing policy](../../../AGENTS.md#testing-policy)).

## Judge a test

Trace the product risk to the real entrypoint, its owner, the setup, the action,
and the assertion. Ask whether the test would fail if the real behavior broke.
A test that only reasserts a mock, a fixture constant, a literal, source text, or
a presentation detail proves nothing: delete it, or replace it with an observable
outcome (durable bytes, an admitted or rejected operation, the presented
interface). Mark any boundary the suite does not cross as a gap, and do not
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
