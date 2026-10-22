# Runtime configuration

Models, context windows, compaction policy, provider login and package
administration over the wire. Owners: `gateway/admin` (auth broker, packages, custom
models, settings) with `gateway/providers` (catalog, release dates) and `gateway/run`
(policy application). Settings design: [settings model](../../docs/settings-model.md);
accounts: [connections](../../docs/connections.md); MCP: [MCP](../../docs/mcp.md).

## Context windows

- `context-window.v1`. `model.list` keeps the SDK `contextWindow` and adds
  `contextWindowLimits` (`minimum` with compaction headroom, `maximum`, `default`,
  optional `longContextThreshold`); `settings.options` for `model.contextWindow`
  serves a target's live bounds. Capacity is what the catalog declares; one
  endpoint-qualified adapter supplies OpenAI's 1,050,000-token maximum for
  `gpt-6-astra`, `gpt-5.6-sol`, `gpt-5.6-terra` and `gpt-5.6-luna` on the OpenAI and
  OpenAI Codex routes only. Entitlement and billing stay the provider's.
- Defaults: `modelContextWindows` in global or trusted-project SDK `settings.json`,
  keyed `provider/modelId` (≤ 500 per scope), read by new and cold-resumed sessions and
  explicit reloads; never by a live session or request.
- Session scope: `settings.change` with the model qualifier and
  `fence: {runtimeGeneration, revision}`, checked inside the idle-only lane. Stale
  model, invalid value, insufficient headroom or a cut below usage plus reserve is
  rejected (compact first). It applies without restart and records one
  `tron.context-window.v1` custom entry, authoritative on the active branch; the
  selected model is a copy, the shared catalog is untouched. Snapshots report
  `contextWindowPolicy`; a not-yet-persisted new session says so. A staged append that
  fails to persist reports an uncertain outcome.
- Parent model, thinking and context-window changes share one admission policy:
  streaming, pending operations, queues, interactions, terminal persistence and other
  mutations block; detached children do not. Snapshots carry `configurationBlocker`
  (`running`, `queued`, `settling`, `mutation`, `interaction`, `unavailable` or null),
  republished by `session.configuration` without bumping `revision`. Model and
  thinking RPCs require `expectedRuntimeGeneration` and `expectedModel`; replies carry
  the applied `revision`. Other idle-checked mutations use broader admission.
  `rpc.error` reasons `session_configuration_*` name the blocker.

## Compaction

`compaction-policy.v1`. Pi owns preparation, generation, retries and checkpoints;
Tron's request adapter only adjusts matching requests and is otherwise a pass-through.
Global/project `compaction` adds `thinkingLevel` (`inherit` … `max`) and
`instructions` (≤ 4,000 UTF-16 units); defaults inherit. A chat's
`tron.settings.v1` values (enabled, reserve, keep-recent, focus) overlay global and
project for that chat and follow fork and resume; Home has no Chat compaction layer.
Thinking and focus are captured per compaction; enabled/reserve/recent apply at the
next idle admission. Snapshots carry `compactionPolicy.next`, `currentBudgets` and
`active`. Malformed settings reject runtime creation or idle admission, keeping the
last valid policy. `extensionMayOverride` warns that an extension can supply its own
summary. An extension's `sendMessage({triggerTurn:true})` from `session_compact` gets
its own owner; the displaced unadmitted request is rejected `busy` for explicit retry.

## Settings, trust and custom models

Settings projections drop write-only proxy credentials (`httpProxyConfigured` only)
and fail closed before projection would truncate. Trust changes reload idle runtimes
before acknowledgement. Custom model documents are validated by a temporary pinned
runtime before an atomic write (≤ 768 KiB, bounded depth and nodes); reads redact
secrets and updates restore matching placeholders.

## Provider login

- At most eight operations, two per device; each lives ≤ 15 minutes and is drain work
  (`provider-login`). `gateway.restart` fails logins still waiting on the user;
  submitted ones are waited for. Records: `auth.login.*`.
- `auth.begin` carries `commandId`. One operation per owner/provider/method/target: a
  new begin recovers it (`recovered: true`), `replaceOperationId` replaces it (a
  successor starts after the predecessor settles in Pi, else a retryable failure after
  30 s). `auth.resume` rebinds after a disconnect and replays the latest bounded event
  or tombstone. Tombstones (15 min) make duplicate `auth.respond|callback|resume|
  cancel` harmless. Events ≤ 128 KiB.
- A credential Pi committed stays canonical after cancel or timeout; a
  `CredentialSynchronizationError` caused by that operation's own abort is projected
  as success once. Nothing is retried. Cancellation aborts the SDK signal, but Pi may
  release Gateway work while an abort-ignoring provider call still runs.
- Phone OAuth: a loopback callback descriptor comes only from Pi's `auth_url`; iOS may
  answer `manual_code` with the redirect, or `auth.callback` relays one code or error
  plus state by a fixed no-proxy GET to Pi's listener; nothing is logged. A loopback
  port another operation owns is withheld. Pi owns state, PKCE and tokens.

## Packages

Inventory and update projections reject duplicates, more than 256 packages, 1,000
resources, 8 KiB strings or 768 KiB responses. Reads share the `PackageService` lane
with mutations. Mutations fail closed on malformed settings, flush the SDK settings
queue before success, and fence install/remove/update failures (including partial
batches) as unknown outcomes. A scoped update touches only the selected installation;
unknown fields are rejected.

## Model catalog

- Cursors bind offset to a whole-catalog SHA-256 and a 30 s runtime-local
  materialization; four traversals per runtime, eight global; ≤ 25,000 items and
  16 MiB per traversal, 800,000 entry bytes per page. Provider catalogs: ≤ 1,000
  rows, unique IDs, 4 MiB of strings.
- Items carry optional `cost` (`{input, output}` USD per million tokens; all-zero
  means unknown and is omitted), `virtual` for Pi virtual models, and `releaseDate`.
  Assistant rows name the physical `provider`/`modelId` and `thinkingLevel`.
- `model.recent`: one Gateway-wide list of ≤ 12 `{provider,id,lastUsedAt}`, recorded
  only when user input starts a run in a user session; `models.recentChanged` on
  change; `gateway/model-recents.json` is disposable (bad documents are replaced).
- Release dates overlay a persisted `models.dev` snapshot
  (`<tronHome>/gateway/model-release-dates.json`, ≤ 32 MiB, ETag/Last-Modified) on
  `packages/gateway/src/providers/model-release-dates.json`, with aliases in
  `model-release-date-aliases.json`. Reads never do network I/O. Refresh after listen
  and every 12 h; `models.refresh` (60 s) adds `releaseDates: {updated[, error]}`
  without failing the provider refresh; `force: true` bypasses freshness; `PI_OFFLINE`
  disables fetching; `models.catalogChanged` on change. Baseline:
  `scripts/update-model-release-dates.mjs` (`--check`).

Verify: `auth-broker`, `compaction-policy`, `runtime-compaction` and
`rpc-idle-admission` integration tests.
