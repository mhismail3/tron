# gateway/settings

## Purpose

Declared settings, resolution/request pins, typed writes and permanent change/Undo
history. Canonical settings stores remain value truth; the audit never computes a
setting and is not an approval queue.

## Owns

- `settings-schema.ts`: key bindings, value validation/formatting, writers, timing,
  effect and native-tap classification. Composition supplies Home tool names,
  compaction limits and security validation without upward imports.
- `settings-resolver.ts`: qualifiers, store reads, composition, clamping and state badges. Which layer's value
  a setting resolves to, which layers are shown, which is not applied and what lies below a layer are decided by
  proof block `settings/precedence` ([`gateway/core`](../../core/settings/precedence/facade.ts), generated from
  `packages/core`): the resolver gives it each layer's facts with a token per value and turns its answer back
  into values, and holds no copy of the fold (`settings-resolver.test.ts` pins the rows and values around it). `settings-project-diagnostics.ts` owns bounded Project diagnostics.
- `settings-model.ts`: target resolution and fixed-direction request pins.
- `settings-change.ts`: planning, expected-before fences, target stripes, ordered
  store application/reverse rollback, outside-write brackets, Home companion effects,
  audit and history-consumed Undo. A store that refuses its compensating write is
  audited as not rolled back, naming the store, never as rolled back. Store I/O and provider admission enter through
  owner ports. `SettingsReadOwner.admitModelChoice` uses the active SDK runtime,
  including borrowed views; it captures no eligibility snapshot.
- `settings-record.ts`: durable, byte/row-bounded segments, index recovery and
  paged history. Indexed immutable segments must retain their indexed row count;
  a grouped Undo requires exactly its unique, consistently sized members.
- `tool-contract.ts`: layer, qualifier, model-reference/queue and typed tool/result
  vocabulary. `settings-types.ts` owns value formatting/composition and immutable,
  disclosed before/after reviews whose digest binds identity and every shown field. How a tool selection's
  entries compose, and the form a chosen selection is stored in, are decided by proof block
  `settings/tool-selection` ([`gateway/core`](../../core/settings/tool-selection/facade.ts), generated from
  `packages/core`): `settings-types.ts` names each tool of a call with a token and writes the block's answer back
  as names, and holds no copy of the merge (`settings-types.test.ts` pins the names and failures around it).
- `scope-resolution.ts`: declared binding admission, canonical targets and sorted
  qualifier identities. `settings-admission.ts` owns operational model/thinking
  selection and synchronous compaction validation.
- `settings-sdk-manager.ts`: declared Project projection, validation and locked
  raw-document merging through Pi's public storage seam. Ignored repository fields
  stay with their canonical document and survive SDK writes.

Home keeps Profile content, provenance, revision checks, restoration and durable
profile publication. `auditSubject` holds validation, grouped successful audit and
awaited observer/projection under the Home stripe; failed diffs remain ungrouped.
No Profile DTO or domain inverse is invented by the settings kernel.

## Contract

`SettingsToolAccess` resolves and changes the current session or Home's delegated
worker. Routine reversible changes, tool selection included, apply, log and can be undone.
Widening trust/executable authority, privacy access or spend, and any install or
irreversible effect, require an exact native tap; narrowing them is routine. Writer
grants and scope admission apply first.
There are no settings tiers, floor overrides, pending-request stores, outcome outbox,
risk-model calls or settings decision RPCs. The one approval primitive is the native
`change` card: it blocks the requesting turn, applies once on its tap, and expires
unanswered after a day (`CHANGE_REVIEW_TTL_MS`) with nothing applied. Settings, Home
profile edits, project lifecycle and Home task grants all use it.

A required review alone has no effects. The model tool supplies no digest argument.
The built-in host's dedicated `change` interaction binds a server-owned typed callback,
not a generic form. A paired-native response checks identity, epoch, revision, answer
shape and exact digest, then consumes the interaction before awaiting that callback.
Its canonical `extension.respond` receipt owns effects through settlement. Stop and
host retirement can cancel only before acceptance; afterwards they cannot falsely
turn accepted work into a decline or replay it. The callback reacquires the actual
target stripe and recomputes the reviewed diff before effects. Local generic RPC
cannot confirm a native review. The maintainer's own (`ui`) change/Undo/Apply again
apply directly, optionally bound to a shown review's digest; only other actors get
the review. Project lifecycle binds its typed intent to the card and revalidates
canonical filesystem, Git, trust and occupancy state.

Unknown, changed or uncertain accepted effects require inspection, never blind
retry under another command ID. Project actions do not invent a generic inverse.
A running tool targeting its own project still fails the lifecycle busy guard.

## Snapshot reload effects

Shell path/prefix, codemode mode/budget, image auto-resize, cache warming and
resource sources declare `reload`. Typed writes mark the affected live sessions
stale through the registry's resource freshness owner; outside settings-file edits
reach the same digest through its file watcher. Reload remains idle-only, and
unchanged effective values do not reload. `model.thinkingBudgets` remains
`new-chat`.

The native slot refreshes inherited reload-fixed values while preserving explicit
Session/delegate choices. The SDK settings adapter re-applies resolved reload
values after its disk read and before the SDK rebuilds tools, so a Session image
setting does not disappear behind Global on reload. These are runtime projections,
not another stored schema. The same-chat shell-prefix and Session image-snapshot
proofs live in `settings-three-layer.e2e.test.ts`.

## Undo and audit durability

Expected-before checks, including Session-owned fields, run inside the target stripe.
Undo checks both the original entry's history-derived consumption and its expected
current-after value under that same stripe. Undo of Undo names the new fact, not the
original operation. Redacted/action facts are not generically undoable. Key declarations
contain no credentials or redaction mode; credential-bearing record subjects retain their
digest-only outside audit and redaction-aware history and Undo guards.

Segment replacement precedes index publication. Recovery adopts only complete,
unambiguous bounded published bytes and never replays effects. Corrupt history
refuses writes/history; startup reports it without failing unrelated settings reads.
Post-effect audit, observation, notification or result-publication failure is an uncertain
outcome: canonical command receipts retain the replay fence rather than admitting the
effect again. An unindexed identity-addressed Profile group is not adopted by generic
recovery: only its domain owner can prove commit and publish it through `appendOnce`.

Home calls `validateSubjectAudit` before accepting its body-free domain intent.
`prepareSubjectAudit` durably appends original ordered writes/context/time as a
started group, distinct from applied identities; `readPreparedSubjectAudit` verifies
its stored digest and reconstructs those facts. Preparation never takes the Home
stripe. After domain commit, `publishSubjectAudit` takes that stripe and lets the
domain hold its current proof lock only across the journal append, not observers.
This orders Forget invalidation without lock reversal or domain replay. Command ID
is the identity; changed inputs and duplicate write IDs refuse.
The record publishes one identity-addressed closed group through one durable index
cut, bounded to 1 MiB. Retry proves file/directory/index durability. This interface
creates no backup, migration journal, domain recovery engine or second settings store.

## Signals

| Signal | One-step diagnosis |
| --- | --- |
| `settings.target-stripe` request stage | A settings write is queued on its actual target stripe; inspect the owning request span before diagnosing a stale read or replay. |
| `TRON_SETTINGS_HISTORY_UNAVAILABLE` | Startup audit recovery refused. Inspect the bounded index/segments; history and writes must fail closed, without effect replay. |

Persistence errors propagate to their caller. No background expiry/retry timer exists.

## Verify

```bash
scripts/tron test gateway src/e2e/admin/native-change.e2e.test.ts \
  src/e2e/admin/settings-worker-fences.e2e.test.ts \
  src/e2e/admin/settings-three-layer.e2e.test.ts \
  src/e2e/admin/settings-change.integration.test.ts \
  src/e2e/admin/settings-subject-audit.e2e.test.ts
```

Concrete store/catalog I/O and presentation belong to [admin](../../admin/README.md);
Home profile effects remain with their typed domain owner.
