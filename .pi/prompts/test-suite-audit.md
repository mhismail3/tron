---
description: Aggressively audit Tron tests for unique, consequential signal
argument-hint: "[scope]"
---

Perform an aggressive test-signal audit of `${ARGUMENTS:-the entire Tron test suite}`.

## Objective

Produce the smallest test suite that provides strong confidence against plausible,
consequential regressions. Optimize for signal—not coverage percentage, test count,
historical intent, or process ceremony.

Every test must earn its maintenance cost by catching a plausible, consequential
regression that would otherwise escape detection. Tests are not documentation,
inventory, architecture theater, or proof that code was written.

For every test, require concrete answers to all of these questions:

1. What specific regression does this catch?
2. Would that regression materially affect users, security, canonical data,
   reliability, resource safety, or operability?
3. Could compilation, typechecking, static validation, or another retained test catch
   it just as well?
4. Does it assert behavior Tron owns rather than incidental implementation details,
   current UI composition, or a third party's current shape?
5. Would a legitimate refactor or vendor change leave the test meaningful?
6. Is there a credible mechanism by which this failure could occur?

If the answers are vague, duplicated, or amount to “this confirms the feature exists,”
delete the test. A contract is not sufficient justification by itself. Retain a
contract test only when breaking that boundary causes a concrete consequential failure
and the break cannot be detected more cheaply elsewhere.

## Delete aggressively

Delete tests that primarily:

- confirm a symbol, export, route, screen, command, menu item, capability, adapter,
  tool, or feature exists;
- prove command, tool, menu, or route registration;
- repeat guarantees already enforced by Swift or TypeScript compilation/typechecking;
- compare constants or manifests already governed by one canonical build-time owner;
- inspect source text for implementation fragments;
- freeze private decomposition, helper usage, internal call order, or incidental object
  shape without protecting a meaningful outcome;
- assert exact UI copy, icons, colors, fonts, spacing, geometry, animation, menu order,
  sheet/route presence, screenshots, or other UX composition;
- simulate undocumented provider behavior or freeze a provider's current payload shape;
- test a fake more thoroughly than Tron's production behavior;
- enumerate structurally equivalent cases without distinct failure modes;
- duplicate a narrower or more authoritative retained test;
- exist mainly as documentation, architecture enforcement, or historical evidence.

Do not preserve a test merely because it is named “accessibility,” “guard,” “contract,”
“smoke,” or “integration.”

## External providers and adapters

Do not emulate Discord, inference providers, APNs, OAuth providers, or other vendors in
detail. Test only behavior Tron owns at the boundary: consequential request
construction, authentication/signing, normalization, bounds, timeout behavior, retry
classification, idempotency, ambiguity handling, and safe failure. Prefer a few
representative response classes over replicas of a provider API.

An adapter test should prove Tron's translation or failure policy—not that a vendor
currently exposes particular fields, commands, exports, or UI concepts. Test an exact
vendor detail only when it is a documented requirement of a supported workflow and
violating it would cause a real product or security failure.

## UI and UX

Cull UI, theme, layout, copy, navigation-presence, screenshot, source-guard, and
command-registration tests heavily. Prefer testing consequential state transitions
below SwiftUI/AppKit. Retain UI automation only when it is the only practical way to
catch a critical end-to-end failure, and keep the minimum number of such journeys.
Accessibility coverage must protect functional usability rather than label presence.
Destructive-action authorization and cross-runtime safety may remain when the real
gating behavior is exercised.

Do not classify by directory alone: some files under `packages/ios-app/Tests/UI`
exercise real state ownership, cancellation, or mutation behavior.

## Strong retain candidates

Tests may justify their cost when they uniquely protect against:

- canonical session/state loss, corruption, or incorrect ownership;
- authentication, authorization, trust, credential leakage, or redaction;
- command-ID idempotency, uncertain outcomes, and accidental replay;
- concurrency, per-session serialization, cancellation, stale publication, and
  lifecycle-generation races;
- reconnect/resynchronization failures that lose, duplicate, or misattribute work;
- persistence, migration, crash recovery, and malformed durable state;
- path traversal, symlink escape, file permissions, quotas, and resource exhaustion;
- retry behavior that duplicates operations or creates retry storms;
- independently shipped Tron-component incompatibility that creates a real runtime
  failure;
- packaging, signing, or runtime boundaries compilation cannot exercise.

These categories do not automatically justify retention. Every individual case still
needs a unique, credible failure mode.

## Process

1. Read `AGENTS.md` and the owning subsystem documentation before classifying tests.
2. Inventory individual test cases—not only files—in the selected scope.
3. Classify each case as:
   - **DELETE** — no unique consequential signal;
   - **MERGE** — useful signal duplicated or spread across too many cases;
   - **REWRITE** — valuable failure mode coupled to implementation, provider, or UI
     shape;
   - **KEEP** — uniquely protects a credible consequential failure.
4. Default to deletion when justification remains uncertain. Do not preserve tests
   merely because removal feels risky.
5. Consolidate repetitive matrices into the smallest representative set that
   distinguishes materially different failures.
6. Do not add replacement tests unless deletion reveals one specific consequential
   behavior with no remaining owner.
7. Do not change production behavior merely to preserve or simplify a test.
8. Remove unused fixtures, fakes, helpers, and test-only production exposure created by
   deleted tests.
9. Update documentation that names deleted suites, fixtures, commands, or obsolete test
   claims. Remove stale claims instead of adding a deletion ledger.
10. Preserve all unrelated worktree changes.

Start with a short audit table:

| Test/group | Decision | Concrete failure caught | Why compiler/other test is insufficient |
|---|---|---|---|

`KEEP` and `REWRITE` require specific answers in both justification columns. `DELETE`
needs only a concise reason. Present the proposed audit and wait for approval before
editing unless the invocation explicitly asks for immediate implementation.

After approval, perform the cull in bounded subsystem passes. Use the narrowest owning
validation per `AGENTS.md`; do not repeatedly run broad suites. Never deploy, promote,
replace, or restart Stable Gateway. Run `scripts/personal-info-guard.sh` before final
completion.

For each implemented pass, report:

- test files, cases, and approximate lines removed;
- tests merged or rewritten;
- the small set retained and each one's concrete reason;
- validation commands and outcomes;
- residual uncertainty without inventing replacement ceremony.

Success is not “all tests pass.” Success is a materially smaller suite where every
remaining test has a clear, unique, consequential reason to exist.

Final review rule: **If a test fails, would we confidently say production is meaningfully
broken rather than merely changed? If not, delete it.**
