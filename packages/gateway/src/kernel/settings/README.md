# gateway/settings

## Purpose

Declared settings, resolution/request pins, typed writes and permanent change/Undo
history. Canonical settings stores remain value truth; the audit never computes a
setting and is not an approval queue.

## Owns

- `settings-schema.ts`: key bindings, value validation/formatting, writers, timing,
  effect and native-tap classification. Composition supplies Home tool names,
  compaction limits and security validation without upward imports.
- `settings-resolver.ts`: layer precedence, qualifiers, composition, clamping and
  state badges. `settings-project-diagnostics.ts` owns bounded Project diagnostics.
- `settings-model.ts`: target resolution and fixed-direction request pins.
- `settings-change.ts`: planning, expected-before fences, target stripes, ordered
  store application/reverse rollback, outside-write brackets, Home companion effects,
  audit and history-consumed Undo. Store I/O and provider admission enter through
  owner ports. `SettingsReadOwner.admitModelChoice` uses the active SDK runtime,
  including borrowed views; it captures no eligibility snapshot.
- `settings-record.ts`: durable, byte/row-bounded segments, index recovery and
  paged history. Indexed immutable segments must retain their indexed row count;
  a grouped Undo requires exactly its unique, consistently sized members.
- `tool-contract.ts`: layer, qualifier, model-reference/queue and typed tool/result
  vocabulary. `settings-types.ts` owns value formatting/composition and immutable,
  disclosed before/after reviews whose digest binds identity and every shown field.
- `scope-resolution.ts`: declared binding admission, canonical targets and sorted
  qualifier identities. `settings-admission.ts` owns operational model/thinking
  selection and synchronous compaction validation.
- `settings-sdk-manager.ts`: declared Project projection, validation and locked
  raw-document merging through Pi's public storage seam. Ignored repository fields
  stay with their canonical document and survive SDK writes.

Home keeps Knowledge content, provenance, revision checks, restoration and durable
profile publication. `auditSubject` holds validation, grouped successful audit and
awaited observer/projection under the Home stripe; failed diffs remain ungrouped.
No Knowledge DTO or profile inverse is invented by the settings kernel.

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

## Undo and audit durability

Expected-before checks, including Session-owned fields, run inside the target stripe.
Undo checks both the original entry's history-derived consumption and its expected
current-after value under that same stripe. Undo of Undo names the new fact, not the
original operation. Redacted/action facts are not generically undoable.

Segment replacement precedes index publication. Recovery adopts only complete,
unambiguous bounded published bytes and never replays effects. Corrupt history
refuses writes/history; startup reports it without failing unrelated settings reads.
Post-effect audit, observation, notification or result-publication failure is an uncertain
outcome: canonical command receipts retain the replay fence rather than admitting the
effect again. An unindexed identity-addressed Profile group is not adopted by generic
recovery: only its domain owner can prove commit and publish it through `appendOnce`.

Home calls `validateSubjectAudit` before its own effects and freezes the original
ordered writes/context/timestamp in its existing domain envelope. After proving its
domain committed, `publishSubjectAudit` publishes or recovers only that audit. Command
ID is the operation identity; changed replay inputs and duplicate write IDs refuse.
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
scripts/tron test gateway src/admin/native-change.e2e.test.ts \
  src/admin/settings-worker-fences.e2e.test.ts \
  src/admin/settings-three-layer.e2e.test.ts \
  src/admin/settings-change.integration.test.ts \
  src/admin/settings-subject-audit.e2e.test.ts
```

Concrete store/catalog I/O and presentation belong to [admin](../../admin/README.md);
Home profile effects remain with their typed domain owner.
