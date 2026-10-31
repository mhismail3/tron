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
prove it. Bugs need fail-before/pass-after. Name a retired check's surviving oracle
or file a gap. Mark boundaries not crossed; whole AX-tree equality is not interaction.

## Diagnose and change

Preserve the first failure, seed/order, configuration and log. Separate scheduling
assumptions from product races using bounded owner-event waits. Confirm cleanup on
success, failure, timeout and cancellation; isolate files, ports, processes and lanes.
Reproduce on unchanged base before claiming a base red; quarantine only exact cases
with owner, signature and expiry. No retry/skip/tolerance change to manufacture green.

Intended-behavior golden/assertion/fixture/timeout edits need cause and delta evidence,
not a maintainer tap. Get non-author ACCEPT naming surviving oracles; subjective
visual choices go to the maintainer. Report counts, skips, quarantines and untested
boundaries honestly; a green subset is not complete coverage.
