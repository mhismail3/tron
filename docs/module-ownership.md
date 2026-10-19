# Module ownership for parallel changes

Tron's package boundaries stay intact. Restructuring makes existing owners
smaller; it does not introduce a second runtime, state mirror, protocol, or
product. The current package contracts remain authoritative:
[Gateway](../packages/gateway/README.md),
[iOS](../packages/ios-app/docs/architecture.md), and
[Mac](../packages/mac-app/docs/architecture.md).

## Dependency direction

| Area | Owns | May depend on |
|---|---|---|
| Gateway protocol | bounded transport values | value contracts, not runtime owners |
| Gateway capability directories | persistence and operations for that capability | SDK/platform adapters and explicit owner contracts |
| Gateway sessions | canonical-session admission, live slots and projections | capability owners; no duplicate durable session store |
| Gateway transport | authenticated command dispatch and delivery | runtime/capability entrypoints; not their private state |
| iOS `TronMobileCore` | wire values, transport and nonvisual support | system frameworks only |
| iOS `TronSwiftAppEngine` | interpreted Swift app execution | system frameworks, not app state or Core |
| iOS State | disposable client projections, exact lifecycle fences, accepted mutation coordination | Core and narrowly scoped State owners |
| iOS UI | native presentation and surface activity | State, Core and shared presentation components |
| Mac app | onboarding, supervision, pairing and native helper lifecycle | authenticated Gateway contracts and platform adapters |
| scripts | finite build/test/development operations | existing package tools and resource owners |

`RuntimeRegistry`, `RuntimeSlot` and `AppModel` are composition boundaries,
not destinations for unrelated capability implementations. New work belongs
with the operation's existing owner. The push relay remains transport-only;
it never gains session, inbox or agent policy.

## Extraction rules

- Extract a complete cohesive operation: its private helpers, local value
  types and invariant belong together. Move code before changing behavior.
- Keep admission, mutation serialization, completion, cancellation and cleanup
  with their current authority. A stateless projection helper must not acquire
  a timer, cache, persistence store or a second lifecycle.
- Prefer an existing module/directory. Add a compiler target only after matched
  build evidence justifies its dependency and linking costs. A file split alone
  is not a build-speed improvement.
- Give dependencies explicit narrow inputs. Do not pass the whole registry/model
  into a helper, expose private state for convenience, or add forwarding layers
  merely to move lines out of a large file.
- Replace internal imports atomically. Keep no old-path re-export, typealias,
  fallback or compatibility shim without a real external/persisted consumer and
  an explicit exit condition.
- Source ownership includes target membership, dynamic registration, generated
  consumers, tests and the nearest package documentation. A grep with no hits
  does not prove code is dead.

## Parallel work and proof

Choose disjoint operation owners, not arbitrary chunks of a large file. Announce
moves in the coordinating issue before editing, inspect active workers' actual
changed files, and keep parked branches untouched. Land small commits with
ordinary fetch/rebase-or-merge/push; no new test gate, queue or merge service.

Validate through the existing real boundary: Gateway/RuntimeRegistry with a
faux provider, an owned process/socket, or an iOS UI journey. Preserve assertions,
fixtures and behavior through mechanical moves. Remove implementation-only or
duplicate tests only after naming the surviving behavioral oracle. UI structure,
styles, identity, focus and interaction stay unchanged; any visual-risk slice
needs matched before/after evidence rather than an inferred no-change claim.

Record actual build/test commands, revision, cache state, timing and net source
LOC per slice. Existing timing artifacts are historical context, not a new
baseline. Shared-host timings without matched repetitions cannot establish a
speedup. Resource changes belong to the existing build entrypoints; no global
admission system is introduced by this document.

## Rejected structures

A big-bang directory rename creates conflicts without reducing ownership coupling.
One protocol/facade per helper adds indirection without a boundary. A framework
per feature can move work into module emission/linking rather than remove it.
Shared mutable build products or a second canonical-state cache trade correctness
for apparent reuse. None is part of this design.
