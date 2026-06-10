# State Ownership And Lifecycle Inventory

Status: SOL-0 scaffold; SOL-1 full inventory pending.

This inventory classifies stateful Tron surfaces by owner, lifecycle class,
scope, creation path, mutation boundary, hydration or reconstruction path,
retirement or retention path, and concurrency or task guard.

Machine-readable rows live in
[`state-ownership-lifecycle-inventory.tsv`](state-ownership-lifecycle-inventory.tsv).

## Allowed State Classes

| Class | Meaning |
|---|---|
| `canonical_truth` | Durable fact read by agents/operators as source of truth. |
| `durable_substrate` | Low-level persisted backing store owned behind a facade. |
| `projection_cache` | Reconstructable local or derived view over canonical truth. |
| `ephemeral_runtime` | In-memory/task state valid only for a process or view lifetime. |
| `local_device_preference` | Device-local preference or UI setting. |
| `secret` | Credential, token, or sensitive material with a narrow owner. |
| `diagnostic_buffer` | Logs, metrics, health state, or diagnostics retained for observation. |
| `test_fixture` | Test-only state excluded from production lifecycle claims. |

## SOL-0 Seed Findings

| Surface | Current classification | Owner | Lifecycle note | SOL rows |
|---|---|---|---|---|
| `SessionManager::plan_mode` | unowned dead state candidate | none accepted | `DashMap<String, bool>` has only local setter/getter references; delete unless SOL-4 finds a real owner. | SOL-4 |
| Engine compensation records | durable audit substrate | engine authority | Records are appended during invocation and inspectable through the engine host; SOL-5 must prove audit-only status is intentional or add terminal transitions. | SOL-5 |
| iOS `EventStoreManager` session metadata | projection cache | iOS event persistence | Local counts/head/root are reconstructable local projections and must not override canonical server truth. | SOL-8 |
| iOS pairing/token stores | local device preference / secret | iOS support composition | Pairing list is device-local; bearer tokens are Keychain secrets keyed by paired server id. | SOL-8 |
| iOS drafts/history/share/diagnostics | local device preference / projection / diagnostic buffer | iOS support/session | Drafts and pending share are local user workflow state; diagnostics are observation buffers. | SOL-8 |

## Coverage Rules

- SOL-1 must add one TSV row for every tracked production Rust/Swift file that
  contains one of the lifecycle markers enforced by the invariant target.
- SOL-1 must also add rows for script/CI state surfaces and docs-owned state
  claims named by the scorecard.
- SOL-2 must ensure every TSV row uses exactly one allowed state class.
- Later rows may refine broad rows into narrower lifecycle owners, but active
  rows may not describe closed work as open after SOL-10.
