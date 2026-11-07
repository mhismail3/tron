---
name: tron-test-confidence
description: Judge whether an integration or E2E test proves its behavior, clean up tests that cannot fail for the right reason, and diagnose timing or lifecycle flakes at real boundaries. Use for test cleanup, flaky runs, and coverage claims.
---

# Test confidence

Apply [project rules](../../../AGENTS.md) and the [oracle policy](../../../tools/verify/test-oracles.md).
Use the fewest faithful checks; bounded logic cannot substitute for wiring or rendering.

## Judge the oracle

Trace risk → real entrypoint → owner → action → observable assertion. Explain why
broken shipped behavior fails; mocks, constants, source text and private calls do not
prove it. Bugs need fail-before/pass-after in the test that owns the behaviour; add a
file only when none does. Merge or retire a test once a survivor is shown to catch its fault. Mark boundaries not crossed; whole AX-tree equality is not interaction.

## Diagnose and change

Preserve the first failure, seed/order, configuration and log. Separate scheduling
assumptions from product races using bounded owner-event waits. Confirm cleanup on
success, failure, timeout and cancellation; isolate files, ports, processes and lanes.
An unchanged-base reproduction helps diagnose cause. Fix deterministic reds at the root
or causally revert. A flake unexplained after one ~2h attempt follows the flake policy:
ship logging that captures its next occurrence and delete the case, issue left open.

After two failed fix attempts on the same red/flake, stop patching. Before a third,
re-attack the premise both fixes assumed: record the retained attempts' SHA, test,
order/seed, lane and host load (mark unavailable facts), and an observation that could
falsify that premise. Write the evidence and revised diagnosis in the issue/report.

Intended-behavior golden/assertion/fixture/timeout edits need cause and delta evidence,
not a maintainer tap. Get non-author ACCEPT naming surviving oracles; subjective
visual choices go to the maintainer. Report raw counts, failures, skips and untested
boundaries honestly; a green subset is not complete coverage.
