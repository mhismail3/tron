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

Deliver the coverage ledger when applicable, evidence-backed findings and KEEP
reasons, changes and surviving risks, and actual validation results. Distinguish
baseline review from review of the final patch. No finding or no change is a valid
outcome; neither implies an unreviewed repository is clean.
