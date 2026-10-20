# gateway/notifications

## Purpose

Push notification admission and the user-facing notification inbox: endpoint-scoped
push grants, durable intents, relay delivery and read state. Producers are
RuntimeSlot's automatic terminal and input-required alerts, the model's `notify`
tool and the settings approval push.

## Owns

`notification-service.ts` (`NotificationService`), `grant-store.ts`, `relay-client.ts`,
`tron-notify-extension.ts`. Store: `gateway/notifications.json`, one exact 1 MiB
owner-only document holding grants (at most 64 active devices), 256 pending intents,
512 receipts, 192 revocation tombstones and the 512-row inbox. It never stores raw
APNs tokens; secrets and message content stay out of RPC projections, logs and JSONL.
A version-1 document migrates on read (its ask choice kept, its envelope-less pending
deliveries retired as failed with one `schema_upgrade` signal).

## Contract

- **`notify({message})`** is the reserved first-party tool. The extension gets only a
  narrow enqueue closure: the model cannot choose a device, token, environment,
  topic, relay, request ID, priority, badge, payload or presentation policy.
- **Admission** is persisted before dispatch, expires after 15 minutes and returns
  `queued`, `suppressed`, `rate_limited` or `unavailable`; APNs acceptance is never
  called delivery. Capacity refusals create no intent or inbox row. Failure is
  diagnostic only and never fails canonical settlement.
- **Automatic kinds** (all on by default, per-kind policy round-trips through
  registration): `ask` (Time Sensitive, input needed), `agent_finished` (a neutral
  terminal category, sent only when no session-owned subagent or workflow is still
  live) and `waiting` (once per unchanged set of live background identities).
- **Terminal alerts** fire only at Pi's final `agent_settled` at idle, never for
  retries, compaction, queued follow-ups or extension continuations
  (`agent_before_settle` is the last actionable boundary). RuntimeSlot matches the
  exact final run's canonical assistant and queues fixed outcome-specific copy; exact
  Gateway abort ownership wins. The dedup source is the assistant entry ID, else the
  invocation terminal receipt ID, else the operation identity. Admission follows the
  canonical terminal receipt: a receipt that exists only in memory after a failed
  append is never announced. Orderly shutdown of foreground work records
  `outcomeUnknown` and attempts one interruption alert. Best effort: process or Mac
  loss can drop an alert and restart never replays one.
- **Input required.** Every admitted semantic interaction (`select`, `confirm`, `input`,
  `editor`, form, including the `pi-ask-user` adapter's) emits one alert from
  `SemanticUIBroker` while pending, keyed by the interaction ID; it never delays the
  interaction. `notifyWhenAskPresented` keeps its wire name but governs all of them.
- **Presence.** A mobile subscription or local connection may publish
  `session.presentation.set` after sync: token-bound, revisioned, one per connection,
  visible leases expiring after 45 s. Visible at observation (latched before receipt
  I/O) means a durable `suppressed` receipt with no intent, inbox row or quota charge.
- **Copy.** Terminal alerts carry the session title and the exact machine/session
  route. Preview-disabled grants replace model `notify` text with fixed copy, in APNs
  and the inbox alike.
- **Inbox.** `notification.inbox.list {filter: all|unread, cursor, limit 1–50}` orders by
  `createdAt` desc then `id`, with a keyset cursor `<createdAtEpochMs>.<id>`, the
  whole-inbox `revision` and total `unreadCount`. `notification.inbox.read` (one inbox
  or APNs request ID) is idempotent; `notification.inbox.readAll {through}` reads only
  rows at or before the cut. Retention evicts read rows before unread. Committed
  changes coalesce into one `notification.inbox.changed {revision, unreadCount}` within
  about 250 ms. A `queued` row proves durable admission only.
- **Opening reads.** A fresh visible presentation (not `session.open`, hidden or
  provisional) reads every unread row of that chat; for Home, of every chapter the
  Home ledger owns. Selection linearizes with admission under the store mutex; only
  captured IDs are retried on write failure. An explicit `notify` from a chat the user
  is viewing is delivered with its row already read. A migrated identity takes its
  rows; a fork or new session does not. Removing delivered iOS notifications is native
  work, not proven by an inbox read.
- **Registration.** `push.registration.upsert|remove|status`. Upsert derives `deviceId`
  from the connection and takes an installation ID, endpoint-scoped grant ID/secret,
  the issuing relay origin and preview/policy booleans (preview defaults off); an
  identical registration writes nothing. `hello`/`system.info` carry
  `pushRegistrationRevision` so a phone re-registers after rotation. A grant from
  another origin or rejected by the relay is rotated by iOS through App Attest, never
  reactivated. Upsert, remove and `device.revoke` share one lane per device;
  revocation disables push before removing the bearer and keeps a tombstone.
- **Relay.** The origin comes only from maintainer-owned `config/PushService.xcconfig`
  (exact public HTTPS). One `/v3/notifications` route (and `GET /v3/capabilities`
  before a `settings-approval` push), no redirects, 20 s deadline, 2 KiB request and
  16 KiB response bounds, HMAC over method, path, timestamp, request ID and body hash.
  Transient outcomes retry with the same request ID; ambiguous ones are terminal.
  Relay `invalid_signature`/`installation_unavailable` invalidate the grant. The relay
  owns the per-device backstop (120/hour, 1,000 routine/day; ask and explicit notify
  skip the daily cap); `rate_limited` is terminal. The Gateway adds no quota.

## Invariants

- The inbox is canonical for content, route, delivery outcome and read state; the iOS
  cache is a disposable projection.
- Reads never write the document unless a row actually changed.
- Home task results are delivered by Home's wake inbox, with at most one advisory
  push ([Home tasks](../home/tasks.md)).

## Entry points

`NotificationService` (admission, inbox, registration); `NotificationGrantStore`; `PushRelayClient`; the RuntimeSlot
and `SemanticUIBroker` callbacks in [gateway/run](../sessions/README.md).

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `notification.inbox.read_failed` | warning | Session read state could not be persisted; unread state is kept in memory only |
| `notification.push.refused` | warning | Admission refused at the bounded pending-intent capacity: `kind`, `outcome=refused`, `reason=pending_capacity` |
| `notification.push.failed` | warning | Relay delivery ended non-accepted, or a legacy intent was retired by migration: `kind`, `outcome=failed`, bounded `reason` or `schema_upgrade` |
| `notification.push.rate-limited` | info | The relay refused one request at a device cap: `kind`, `outcome=rate_limited`, `reason` (`daily_limit`, `hourly_limit`); never retried blindly |
| `notification.inbox.list` row `title`, `sessionId`, `isUnread` and whole-inbox `unreadCount` | RPC projection, no log | For a Home row left unread after opening a completion, compare the rows' session identities: two Home chapters can differ. A synchronized opening reads the ledger-owned Home rows in its cut; `notification.inbox.changed` carries the committed count |

## Verify

```bash
scripts/tron verify --module gateway/notifications
scripts/tron test gateway src/notifications/notification-inbox.integration.test.ts \
  src/sessions/runtime-terminal-notifications.integration.test.ts \
  src/sessions/runtime-registry-notification-read.integration.test.ts
```

`runtime-terminal-notifications.integration.test.ts` drives a local fake relay and the
real mobile open/sync/visible journey, writing
`test-results/runtime-terminal-notifications.integration.json` and
`test-results/home-title-payloads-{preview,redacted}.json`. Behavior locks:
`notifications.store.lock.integration.test.ts` and `notifications.push.lock.integration.test.ts`
(terminal and input-required pushes at the relay boundary, presence suppression, the
task-worker skip).

## Not here

- The relay service and App Attest: the relay package and iOS.
- Settings approval pushes' decision flow: [settings contract](../../docs/settings-contract.md).
