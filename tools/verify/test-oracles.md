# Test-oracle policy

Detect a named surviving regression through shipped logic or its actual boundary.
For bugs, retain fail-before/pass-after evidence: action, outcome and why the broken
implementation fails. Put it in the E2E/integration test that already owns the behaviour; add
nothing when a test already proves it, and a file only when no owner exists. Default to fewer
tests: retire tests that restate code (structure locks, duplicate unit tests, implementation
snapshots) rather than keeping them. Mocks, copied algorithms,
private calls and source-text matches cannot prove wiring, authority, ordering, cleanup or
rendering. Use few faithful oracles.

## Retire and consolidate

A replacement deletes the path it replaces, with the tests that covered only that path, in
the same change. Two tests that catch the same fault are one too many: merge or retire one
once the survivor is shown to catch it (fail-before on the old code, or a mutant both
detect). That is consolidation, not weakening.

A test solely exercising a deliberately retired mechanism may leave with its last
reader. Trace actual consumers first. If user value survives elsewhere, name the
surviving test and show that it still catches the same regression at the right
boundary. If no faithful successor exists, keep the oracle or replace it before
deleting it. A closed issue, renamed file or smaller suite is not a successor.

Weakening includes dropping a surviving outcome, ignoring unexplained fields,
broadening tolerance or timeouts to conceal a fault, or adding retries/skips to
manufacture green. Deleting a flaky case under the flake policy below is not weakening. An event-based bounded wait may
replace a scheduling assumption only while preserving the original outcome and
useful failure bound. Use risk-based known-bad proof, not ritual mutations for
all edits. Preserve the first failure and distinguish a test defect from a product
race using actual evidence.

## Assertions and timeouts

There are no golden, snapshot or recorded-trace oracles. Workers may update intended-behavior
assertions, fixtures and timeouts without maintainer test-text approval, explaining the cause and
intended delta. A non-author reviewer with a shell (not the bash-less builtin `reviewer`) runs the changed
tests, names each surviving oracle, checks for weakening and
explicitly ACCEPTs: what did this change delete or retire, and why does each new test file not
extend its owner? Subjective design goes to the maintainer with inline visuals.

## Reds

Deterministic reds need root fixes or causal reverts. Flaky or unrootable reds follow
the [flake policy](../../docs/PRINCIPLES.md#p6-tests-are-deterministic-and-own-their-resources):
one timeboxed attempt, then shipped logging plus deletion of the case, issue left open.
Preserve the first failure, exact SHA, command and raw logs/counts. A passing retry is
nondeterminism evidence, not resolution. Diagnose an unattributed red before choosing
any revert target; never guess.

The gate is the only admission check ([README](README.md#gate)). Report counts, skips,
failures and untested boundaries honestly. See [test-confidence procedures](../../.agents/skills/tron-test-confidence/SKILL.md).
