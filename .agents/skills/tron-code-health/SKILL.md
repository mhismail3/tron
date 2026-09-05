---
name: tron-code-health
description: Audit, simplify, and harden Tron code by tracing real ownership and removing unnecessary mechanisms. Use for architecture reviews, exhaustive investigations, cleanup, and root-cause fixes.
---

# Code health

Apply [project rules](../../../AGENTS.md). An investigation is read-only unless
repairs are requested; the breadth of an audit does not grant mutation authority.
Use the following procedure at the requested scope, not as a mandatory repository
survey for every small fix.

## Establish honest coverage

Read the current Git state and owning docs. Identify the behavior to preserve,
its entrypoints, and the evidence needed to evaluate it. Keep unrelated work out
of the change.

For a comprehensive investigation, inventory all first-party source, services,
scripts, configuration, tests, and documentation. Maintain a run-owned file ledger:
**Not reviewed / Sampled / Fully reviewed / Excluded with reason**. Fully reviewed
means inspecting substantive types, functions, state, branches, failure paths,
callers, and cross-file/process effects—not merely opening the file or running a
search. Review generated-code inputs and consumers; justify excluding generated
output and vendored dependencies. Report partial coverage explicitly. Delegated
reports must identify their actual coverage; verify findings before acting on them.

### Close behavior slices across batches

A batch limits work, not dependencies. Scope each slice around a real operation
from entrypoint through state ownership, observable result, and retirement, even
when it crosses packages or processes. Use the file inventory to catch remaining
helpers, configuration, resources, tests, and docs; following popular flows alone
is not exhaustive coverage. Split large files by substantive mechanisms, but do
not mark the whole file fully reviewed until all its parts are inspected.

In the run-owned ledger, link each slice to its files/revisions, material
functions and decisions, and cross-file boundaries. For each boundary record the
producer/caller, consumer/owner, required contract, inspection/test evidence, and
unresolved work. Follow related files outside a batch rather than assuming a
later reviewer will cover them. Unresolved dependencies stay explicit and prevent
boundary closure; another lane's summary alone is not evidence. One integrating
owner reconciles overlapping reviews and cross-owner changes.

Close a slice only after its relevant ends and failure paths are traced and its
evidence is checked. File coverage and finding resolution are separate: a fully
reviewed file may have a known unfixed defect. Every finding needs a disposition,
evidence, and either a complete authorized change or an explicit remaining action,
blocker, or user-approved deferral. Do not call hardening complete while unresolved
work is merely parked. Report cumulative coverage and unresolved boundaries after
each batch, not just files opened or bugs fixed.

Record the revision or content hash underlying each assessment. When an owner,
contract, registration, configuration, or behavior changes, reopen affected
reviews and cross-file boundaries, including unchanged consumers. Rerun the
relevant contract checks; a previously green file is not permanently certified.

## Follow the mechanism, not the folder

For each capability, trace a real operation from admission to its observable
result and retirement. Ask:

- What requirement needs this mechanism? What breaks if it is removed? Is the
  caller real, dynamically registered, generated, external, or only a test?
- Who owns truth, mutation, operation identity, completion, cancellation, and
  cleanup? Can delayed work affect a successor agent, session, connection, or view?
- What happens on duplicate delivery, disconnect/reconnect, partial success,
  crash/restart, timeout, and repeated cleanup? Where are work and storage bounded?
- At trust and persistence boundaries, do authorization, path handling, input
  limits, transactions, error reporting, and recovery protect the actual operation?
  Trace destructive cleanup as carefully as successful reads and writes.
- Is a wrapper, flag, cache, retry, compatibility path, dependency, or custom
  abstraction solving a current problem, duplicating policy, or hiding bad ownership?
- Do documentation and comments describe the executed contract? Check command,
  version, configuration, and recovery claims against their authoritative owners.

Record **KEEP / DELETE / SIMPLIFY / FIX / INVESTIGATE** for material decisions.
A finding needs an exact path, reachable mechanism, concrete consequence, and
supporting evidence. Complexity or size alone is not a defect. Explain why a
non-obvious safeguard stays; a missing reproduction remains an evidence limit.

## Make the smallest complete authorized change

Prove the failure or unnecessary mechanism before replacing it. Prefer removing
the cause or using the existing owner/platform API over adding a second path.
Update affected callers, registration, configuration, tests, and owning docs in
one coherent change; search again for superseded consumers and interfaces.
For dependency changes, check exact-version official migration guidance and use
the repository's package/generation workflow rather than editing generated output.

Use [test confidence](../tron-test-confidence/SKILL.md) when assessing an oracle,
removing tests, or validating a disputed mechanism. Use
[performance](../tron-performance/SKILL.md) for cost claims or comparisons.
Validate the changed boundary first, then the relevant broader checkpoint. Inspect
the final diff for unintended behavior changes and displaced complexity.

## Turn verified lessons into maintained contracts

Finish each authorized improvement with the evidence that makes it safe to keep:

- Put the behavioral regression at the owning boundary. Show it fails for the
  reproduced defect or justified known-bad control, not merely that a new helper
  returns its own expected value. Inspect test-runner/CI registration; a test
  outside normal validation does not protect later changes.
- Update the nearest owner documentation with the current requirement, authority,
  ordering, failure/recovery contract, and focused regression reference where useful.
  Add a concise adjacent comment only where the reason or rejected alternative
  would otherwise be easy to lose. Apply the shared breadcrumb rule, not a comment
  quota or a permanent defense of today's implementation.
- Put genuinely cross-cutting rules in AGENTS.md and recurring review procedures
  in this skill; do not duplicate subsystem facts across instructions. Keep raw
  experiments, coverage logs, and investigation history in run-owned audit artifacts.
- Remove superseded code, callers, tests, docs, and misleading comments together.
  A future replacement may change the mechanism, but must account for the protected
  requirement and update its evidence and rationale rather than silently erasing
  them. Tests/checks enforce observable contracts; prose explains the why. Neither
  alone guarantees that a future change is safe.

Deliver the coverage ledger when applicable, evidence-backed findings and KEEP
reasons, changes and surviving risks, and actual validation results. Distinguish
baseline review from review of the final patch. No finding or no change is a valid
outcome; neither implies an unreviewed repository is clean.
