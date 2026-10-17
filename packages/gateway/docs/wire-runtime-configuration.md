# Runtime configuration and administration wire contract

[Gateway wire index](../README.md#transport)

Models, compaction settings, provider authentication and package administration. [Settings model](settings-model.md) owns the change/resolution design; [connections](connections.md) owns provider account envelopes; [MCP](mcp.md) owns MCP administration.

Command and plain-text source paths retain their original repository/Gateway-root context; Markdown links are document-relative.

## Model context windows

`context-window.v1` exposes a model-qualified context budget in Agent Defaults
and Manage Session. `model.list` retains the SDK's configured `contextWindow` and
adds optional `contextWindowLimits` (`minimum`, `maximum`, `default`, and an optional
`longContextThreshold`). The catalog minimum uses standard compaction headroom;
`settings.options` for `model.contextWindow` serves the target's actual bounds.
Session policy bounds use that live session's compaction settings. Capacity is
declared by the provider/catalog, not inferred
from a display name or copied from a different endpoint. The pinned catalog lacks a
separate supported-maximum field: one endpoint-qualified adapter supplies OpenAI's
documented 1,050,000-token maximum for `gpt-6-astra`, `gpt-5.6-sol`, `gpt-5.6-terra`,
and `gpt-5.6-luna` on the official OpenAI and OpenAI Codex routes. Other models,
including custom and extension models, use their declared catalog window. Proxy
routes do not inherit OpenAI's extra capacity. Account entitlement, remote acceptance,
and long-context billing remain provider-controlled; the catalog is not a live
million-token request probe.

The first-party `modelContextWindows` preference lives in canonical global or
trusted-project SDK `settings.json`, keyed by `provider/modelId`. It is the
`model.contextWindow` key qualified by model: `settings.change` sets one model's
integer token count, bounded by that model's catalog limits, or unsets it; other
models and unrelated settings are preserved. Each scope is bounded to 500
preferences. New or cold-resumed sessions and explicit resource reloads read
these defaults. Saving defaults never changes an in-flight request or silently
reconfigures an already-live session. It does not restart the Gateway or rewrite
`models.json`. This is a Tron-owned preference interpreted by its embedded runtime
adapter, not a new native SDK setting consumed by independent runtime clients.

A chat's own window is the Chat layer of `model.contextWindow`: a `settings.change`
for the session target with the model qualifier, an integer value (or `unset` to
inherit), and `fence: { runtimeGeneration, revision }` from the displayed snapshot. It uses the exact open subscription,
command receipts, and the session's idle-only serialized mutation lane. Revision
and runtime generation are checked inside that lane, preventing same-model stale
saves, A → B → A model switches, and delayed requests after cold reopen. A stale
model identity, unavailable capacity, invalid integer, insufficient
compaction headroom, or a reduction below current usage plus response reserve is
rejected. The user must compact before an unsafe reduction; no messages are silently
truncated. A successful change applies to the existing session without restart or
new-session creation and leaves reasoning level, output ceiling, costs, and other
sessions unchanged. Larger context never restores previously compacted history.

One non-message `tron.context-window.v1` custom entry records each session override
or reset in canonical JSONL. Its active branch is authoritative across fork, tree
navigation, reload, import, and cold resume. The selected SDK model is a copy with
the effective budget; the shared provider catalog is not mutated. Model-selection,
resource-lifecycle, turn, and public model-lookup boundaries reapply that policy,
including the SDK's silent provider-registration refresh. `contextWindowPolicy` in
the session snapshot reports the model identity, bounds, configured default,
effective budget, explicit override, scope source, and optional adjustment/cost
warning; `contextUsage.contextWindow` uses the same effective runtime value.
Existing saved preferences that no longer fit a model's current capacity or
compaction headroom are bounded with an explicit warning, not treated as proof of
unsupported capacity. As with other native session choices, a brand-new session
is only durable after the SDK's first-assistant persistence boundary; the snapshot
and Manage Session explicitly warn when the override is not yet saved to disk;
Pi persists it with the first user or assistant message. Already-materialized
sessions persist idle changes without needing another turn.
No direct JSONL writer or separate preference journal bypasses the SDK. If native
append stages an entry but disk persistence fails, the RPC reports an uncertain
outcome and publishes the actual live projection rather than fabricating rollback
or blindly replaying the command. An explicitly issued new command always records
its desired value, even when it matches a previously staged in-memory value. Parent
Chat-layer model, thinking and context-window changes share
one parent-configuration admission policy in RuntimeSlot. Streaming, pending
parent operations/queues/interactions, terminal persistence and concurrent
session mutations remain fenced. Only the initiating RPC token is excluded.
Independent detached child activity alone does not block a parent configuration
change; it still blocks deletion, eviction and administrative drain.

Protocol 7 snapshots require `configurationBlocker` (null when ready; otherwise
`running`, `queued`, `settling`, `mutation`, `interaction` or `unavailable`).
The sequenced `session.configuration` event republishes this derived fact when
work admission or retirement changes eligibility, including final assistant
completion-queue retirement, without changing canonical `revision`: otherwise
the context-window request would invalidate its own CAS.
Snapshots re-state the event; stale events/snapshots cannot roll it back. Stop
acknowledges foreground settlement, not detached children or every persistence
owner. iOS shows the remaining settling reason and enables all three controls
only from this authority, with exact pending-choice ownership.

Model and thinking RPCs require `expectedRuntimeGeneration` and `expectedModel`
(provider/id, or explicit null for no model). The slot checks this original
intent inside its mutation lane. All three configuration replies include the
exact applied `revision`, captured inside that same lane and retained in the
command receipt. iOS retires a confirmed pending choice when its value is
projected or authoritative state reaches that revision, even if another client
has superseded the value. An earlier snapshot cannot retire a different pending
command. Context changes retain their existing exact runtime/model/revision checks. iOS rechecks original synchronization/runtime/model
admission at actual transmission, including a definitely-not-sent retry; accepted
results remain with the confirmed mutation receipt owner and are not discarded
when the view retires. No fixed delay or automatic new-command replay makes a
session ready. `rpc-idle-admission.integration.test.ts` retains a JSON report for
post-Stop configuration with detached work, genuine terminal/concurrent work,
original model/runtime intent and revision-preserving retirement.

Other idle-checked mutations (`session.bash`, tools, labels, fork, navigation,
resource reload) still use broader administrative admission and exclude only
their initiating RPC token. Delete retains its independent child protection.
`rpc.error` reasons `session_configuration_*` name the rejecting configuration
category; `session_operation_busy` remains the archive/delete blocker signal.

## Compaction configuration

`compaction-policy.v1` exposes compaction configuration in the dedicated iOS Settings
page. The pinned Pi SDK still owns preparation, generation, auth, retry callbacks, split ordering,
summary validation, canonical checkpointing and continuation. The public
`session_before_compact` hook captures the exact operation signal; the request adapter
changes only matching-signal, matching-conversation-model requests. It never generates a
replacement result, copies SDK prompts, or launches fallback summaries. Standard behavior
is an argument-for-argument pass-through of the built-in generator.

Canonical global/project `compaction` settings add `thinkingLevel` (`inherit`, `off`,
`minimal`, `low`, `medium`, `high`, `xhigh`, `max`) and `instructions` (at most 4,000 UTF-16
units). Defaults remain inherited conversation thinking and empty focus; Low is opt-in
pending real-provider quality evaluation. The SDK clamps requested thinking to model
capabilities; the projection describes the SDK request level, not measured provider
reasoning use or a provider guarantee. In particular, an effective `off` request may
be represented by omitted reasoning fields and leave the provider's own default behavior
in control. Focus is appended to a cloned summary system context for both history and
split-prefix passes. One-off manual instructions retain the SDK's history-only behavior.
Chat and branch-summary requests are untouched. Concision is an instruction, not a hard
combined output limit, and no provider latency/quality improvement is claimed by fixture tests.

Thinking/focus are captured once at each compaction, including its retries and split calls.
Enabled/reserve/recent controls are narrowly applied at the next idle prompt or manual
compaction admission, never inside an active run. No broad settings/resource reload occurs.
Settings writes refresh live projections without mutating prepared work. `SessionSnapshot`
contains `compactionPolicy.next`, `currentBudgets`, and optional `active` configuration;
terminal events clear the captured policy before the owner publishes the end snapshot.
Sources are chat/global/project/default: an ordinary chat's explicit `tron.settings.v1`
compaction values (enabled, reserve, keep-recent, focus) overlay the global and project
policy for that chat only, follow fork and resume, and are unset by Follow the default.
Home has no Chat compaction layer (its SDK compaction stays off). Global Settings never
invents a session model.
Absent project fields inherit; null patches delete overrides; explicit inherit/empty restore
standard generation without changing budgets. Project editors can instead delete
thinking/focus overrides with null patches to resume global inheritance. Malformed initial
configuration rejects runtime creation. A failed read in an existing runtime preserves the last valid policy with
a bounded warning; idle admission rejects until settings are valid again.

Other extensions may merely observe compaction (including subagents). Their registration
must not prevent loading the session. `extensionMayOverride` warns that an extension can
supply its own summary; independent extension generation is not claimed as controlled by
Tron's request policy. The pinned SDK can also let an unawaited extension
`sendMessage(..., { triggerTurn: true })` begin an auxiliary run from `session_compact`
before the original pre-prompt request is admitted. Gateway gives that auxiliary turn a
distinct owner and uses the public `preflightResult` callback to reject the displaced,
unadmitted request with a retryable `busy` error. The caller must explicitly retry after
settlement; Gateway neither starts a second overlapping Agent prompt nor replays the input.
This remains true if the auxiliary turn finishes before the compaction hook returns; the
still-live compaction owner is restored until its own terminal event. The callback cannot
prevent the extension's trigger turn itself or cancel the SDK's earlier auth wait.
SDK cancellation/custom-result ordering remains authoritative.
`compaction-policy.integration.test.ts` compares real SDK baseline/adapted requests and checkpoints,
including split summaries, retries, branch summaries, reload and failures.
`runtime-compaction.integration.test.ts` exercises real preflight/between-turn Stop,
early manual cancellation, overflow continuation, saved/active settings and durable receipts.
It also covers uncancellable auth through Stop grace expiry and a public `session_compact`
extension's fire-and-forget successor through manual cleanup, Stop, and marker retirement,
plus preflight displacement with both running and already-settled auxiliary turns.

## Settings document projection

Settings projections include
scope-owned documents and effective values, but write-only proxy credentials are removed
from both; clients receive only `httpProxyConfigured` and can set or explicitly clear the
canonical value. Persisted settings documents and their responses fail closed before generic JSON
projection if their depth, members, nodes, strings, or encoded size would be truncated or exceed
the mobile frame; rejected updates leave the prior document intact.

## Trust changes

Trust changes reload
idle live runtimes before acknowledgement; project resources therefore cannot stay
loaded from an obsolete decision.

## Provider authentication and callback relay

Provider authentication admits at most eight operations globally and two per
authenticated device identity. Each operation has a 15-minute Gateway-owned lifetime, so providers that
ignore abort cannot retain broker capacity; completion, failure, explicit cancellation,
device revocation, Gateway shutdown, and timeout retire exactly once. Each login is drain work of
category `provider-login`. Accepting `gateway.restart` cancels every login that is waiting on the user
(prompt, browser, or device code) and sends it a failed `auth.completed`; a login whose answer or callback
was already submitted keeps its work entry, so the drain waits only for credential completion. Start, recovery,
and each ending (with provider ID, method, age, and reason, never prompt values) are logged under source
`auth` with `auth.login.*` events. MCP relay lifecycle outcomes use
`mcp.auth-url.routed`, `mcp.callback-relay.succeeded` and
`mcp.callback-relay.failed`. A WebSocket disconnect
only detaches event delivery: `auth.resume` rebinds the same stable-device-owned operation to a
replacement connection and replays its latest bounded event/prompt or terminal tombstone. Current
clients send a `commandId` with `auth.begin`; a bounded in-memory admission receipt returns the
same operation for an uncertain duplicate without claiming that login completed. At most one operation is
active per owner/provider/auth-method/target key: a fresh `auth.begin` with a new command ID recovers that
operation before capacity is enforced, rebinds delivery, replays its bounded event/prompt, and answers
`{ operationId, recovered: true }`, so a client that lost its operation ID never consumes another slot.
Restart is explicit: `auth.begin` with `replaceOperationId` naming that exact active operation retires it and
admits a successor (`recovered: false`). A stale replacement ID recovers or admits normally; one naming another
owner is `not_found` and another key is `conflict`. The receipt includes the replacement ID, so an uncertain
restart retry returns the same successor. Admission stays synchronous under device admission, but a successor
starts its provider login only after the previous login for its key settles in Pi; if that takes longer than
30 seconds the successor completes with a retryable failure while the predecessor keeps its drain work.
A callback capture whose loopback host/port another active operation already owns is withheld, so a fixed-port
callback cannot be relayed into the wrong login's listener; that login continues through manual code entry.
Pi resolves a login only after its credential mutation began, so a success arriving after cancellation or
timeout is projected truthfully: the tombstone becomes a successful completion, `auth.completed` is emitted,
and `providers.changed` is broadcast. Provider prompt/event projections
are limited to 128 KiB before broadcast, and late callbacks from retired operations
are inert. Cancellation aborts the exact SDK login signal, but Pi's `ModelRuntime.login` races an abort against the provider promise; it can therefore settle and release Gateway work while an abort-ignoring provider call is still running. Credential storage is separately fenced by Pi's abort-aware credential mutation, but broker retirement or drain release does not prove the underlying provider settled or its resources closed. Pi's legacy OAuth adapter routes provider `onPrompt`/manual-code requests to the broker-owned prompt, and retirement rejects that exact prompt; a provider awaiting its pasted code therefore settles on cancellation even when it ignores the signal. Provider work after an accepted code (for example a token exchange) is outside that boundary. Bounded 15-minute tombstones make duplicate or reordered
`auth.respond`, `auth.callback`, `auth.resume`, and `auth.cancel` requests harmless without retaining prompt values.

For phone browser OAuth, the Gateway derives an optional callback descriptor only from Pi's
provider-authored `auth_url` (`redirect_uri` or `callback_url`) and only for explicit HTTP loopback
hosts. iOS may answer Pi's existing `manual_code` prompt with the complete captured redirect. For
providers such as Radius without that prompt, `auth.callback` accepts only the operation/callback ID
and bounded query: the host, port, and path remain Gateway-retained, exactly one authorization code or
provider error plus unambiguous state is required before a fixed no-proxy loopback GET reaches Pi's
already-listening callback server, and neither callback data nor
response bodies are logged, persisted, or returned. Pi remains the sole state/PKCE, token exchange,
refresh, and credential-storage authority.

## Package inventory and updates

Package inventory and update projections reject duplicate stable
identities, more than 256 packages/updates, more than 1,000 resources of any kind, strings above
8 KiB, or encoded responses above 768 KiB before generic JSON projection can truncate them. Package
list and update-check reads share the PackageService mutation lane with install/remove/update so Pi's
npm/git trees and lockfiles are never inspected concurrently with a mutator. Package mutations fail
closed on malformed settings and flush the pinned SDK settings queue before broadcasting successful
completion; persistence errors therefore cannot produce a false success. A scoped update refreshes
only the selected user/project installation through Pi's public install seam, while an omitted source
retains the explicit update-all operation. Package RPCs reject unknown fields.

## Model catalog pagination

Model-list
cursors bind their offset to an exact whole-catalog SHA-256 fingerprint and a 30-second immutable
runtime-local materialization, so changes cannot mix pages and later pages do not rebuild or rehash
the catalog. At most four traversals remain per runtime and eight globally. Each traversal is limited to 25,000 items
and 16 MiB of encoded model entries; each page is additionally capped at 800,000 encoded entry bytes
beneath the socket envelope ceiling. Provider catalogs reject more than 1,000 rows, duplicate IDs,
or 4 MiB of strings before generic projection can truncate them.

## Custom model documents

Custom model documents are validated by a temporary instance of the pinned runtime
before an atomic write. Canonical reads, validation files, redaction traversal, and locked
updates share a 768 KiB file ceiling plus bounded depth, nodes, and collection members.
Read projections redact secret-looking strings; matching redaction placeholders are restored
from canonical state during update so mobile editing cannot erase credentials it was never
allowed to read.

## Model recents and release dates

`model.recent` serves the model picker's Recent rail: one Gateway-wide usage
preference shared by every paired device, newest first, unique by `provider/id`,
and bounded to 12 entries. It is global and session-free (`params` carries no
fields) and returns `{"models":[{"provider","id","lastUsedAt"}]}`. Recency is
recorded only when an admitted `agent_start` begins a run from user input in a
user session, using that session's current model: merely selecting a model,
changing a default, or running a background turn never counts. Delegated
subagent sessions never acquire a Gateway runtime, so they can never report a
model as recently used. The event `models.recentChanged` (empty payload)
publishes a change in the visible order so an open picker can refetch. The
document lives at `gateway/model-recents.json`, is owner-only, and is a
disposable preference: a malformed or oversized document is replaced with an
empty one instead of failing Gateway startup, because no canonical evidence
exists to rebuild it from. Registry shutdown drains admitted recency writes
before releasing its state directory.

`model.list` items also carry an optional `cost` of `{input, output}` in USD per
million tokens, copied from the pinned SDK catalog for the picker's rail cards.
An all-zero SDK price means the price is unset, not that the model is free, so
the field is omitted; cache rates and tiered pricing are not projected. The
`virtual` boolean identifies Pi virtual-model registrations in the picker;
virtual models with unset limits retain unknown limits until a physical response
establishes the SDK's routed limits. Assistant transcript rows continue to name
the physical response's `provider`/`modelId` and now carry optional
`thinkingLevel` from Pi's canonical response. Virtual router state remains an
SDK custom session entry and is excluded from transcript rows.

`model.list` items carry an optional `releaseDate` (`YYYY-MM-DD`) that backs the
picker's Latest rail; models with no known date omit the field and appear only
in provider sections. A Gateway-owned release-date catalog overlays a persisted
fresh `models.dev` snapshot on the vendored baseline in
`packages/gateway/src/providers/model-release-dates.json`; fetched keys win and
missing fetched keys retain their baseline values. Reads use only the in-memory
merged catalog and never perform network I/O. The persisted document lives at
`<tronHome>/gateway/model-release-dates.json`, is atomically replaced, and carries
`fetchedAt` plus conditional-request validators. Invalid or oversized persisted
state is warned about and ignored in favor of the baseline.

After the listener starts, the Gateway makes a non-blocking refresh and retries
on a 12-hour interval; a fresh persisted snapshot suppresses periodic requests.
`models.refresh` also runs the release-date refresh concurrently with Pi's model
refresh under the same 60-second cancellation boundary. Its response keeps the
existing `{aborted, errors}` fields and additively includes
`releaseDates: {updated}` or `releaseDates: {updated, error}`; release-date
failure never changes the successful provider refresh result. A non-forced
request skips release-date fetching while data is younger than 12 hours; the iOS
Model Catalog Refresh action sends `force: true`, so it bypasses freshness. The Gateway
uses conditional ETag/Last-Modified requests, caps response and persisted data at
32 MiB, shares concurrent fetches, and aborts on shutdown. `PI_OFFLINE=1`, `PI_OFFLINE=true`, or `PI_OFFLINE=yes` disables
these network requests. Refresh coverage follows the providers exposed by the
runtime handling the request (global or session-local), plus alias targets; the
background refresh covers global providers. A release-date failure is reported additively as
`releaseDates.error`, never fails the existing refresh result or discards usable
dates. When fetched dates change, `models.catalogChanged` tells connected clients
to reload `model.list`.

The vendored baseline is maintained manually with
`scripts/update-model-release-dates.mjs`, which reads the pinned SDK catalog to
decide provider coverage and uses the same provider/date/alias normalization as
the runtime service. Month-precision releases normalize to the first day of the
month. The script requires installed `packages/gateway/node_modules`; `--check`
verifies the checked-in baseline without writing. Runtime refresh coverage comes from the providers exposed by the active
`ModelRuntime`, including extension providers, plus alias targets. Providers that re-export another vendor's models resolve
through `packages/gateway/src/providers/model-release-date-aliases.json`.
