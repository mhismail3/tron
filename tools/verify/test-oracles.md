# Test-oracle policy

Detect a named surviving regression through shipped logic or its actual boundary.
For bugs, retain fail-before/pass-after evidence: action, outcome and why the broken
implementation fails. Mocks, copied algorithms, private calls and source-text matches
cannot prove wiring, authority, ordering, cleanup or rendering. Use few faithful oracles.

## Retire a reader, not its protection

A test solely exercising a deliberately retired mechanism may leave with its last
reader. Trace actual consumers first. If user value survives elsewhere, name the
surviving test and show that it still catches the same regression at the right
boundary. If no faithful successor exists, keep the oracle or replace it before
deleting it. A closed issue, renamed file or smaller suite is not a successor.

Weakening includes dropping a surviving outcome, ignoring unexplained fields,
broadening tolerance or timeouts to conceal a fault, removing the failing case,
or adding retries/skips to manufacture green. An event-based bounded wait may
replace a scheduling assumption only while preserving the original outcome and
useful failure bound. Use risk-based known-bad proof, not ritual mutations for
all edits. Preserve the first failure and distinguish a test defect from a product
race using actual evidence.

## Goldens, assertions and timeouts

Workers may update intended-behavior assertions, fixtures, timeouts and goldens
without maintainer test-text approval. Explain the cause and intended delta;
re-record only the affected witness through its owner and run the comparison.
A non-author reviewer names each surviving oracle, checks for weakening and explicitly
ACCEPTs the final change. Never auto-bless unexplained reds or normalize away the
protected distinction. Subjective design goes to the maintainer with inline visuals;
Home owns objective gates. A still image does not prove interaction.

## Reds stay red

[Principles P2/P3](../../docs/PRINCIPLES.md#p2-verification-gates-promotion-not-authorship)
require root fixes or causal reverts: no quarantines, waivers, known-failure exemptions,
qualified greens or base-match excuses. Preserve the first failure, exact SHA, command
and raw logs/counts. A passing retry is nondeterminism evidence, not resolution.
Missing required coverage is not green. Diagnose an unattributed red before choosing
any revert target; never guess. The [batch owner](README.md#asynchronous-full-main-batches-and-causal-revert)
reverts only a culprit proven by fresh controls.

Run affected checks before landing; broad post-land coverage belongs to the
[batch owner](../../docs/PRINCIPLES.md#p2-verification-gates-promotion-not-authorship), not duplicated per-worker suites. Report counts, skips,
failures and untested boundaries honestly. See [test-confidence procedures](../../.agents/skills/tron-test-confidence/SKILL.md).
