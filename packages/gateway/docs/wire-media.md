# Media and live-view wire contract

[Gateway wire index](../README.md#transport)

Display, browser observation, immutable attachments and exports share bounded resource ownership. Native/agent capability qualification remains with [native tool settlement](native-tool-settlement.md).

Command and plain-text source paths retain their original repository/Gateway-root context; Markdown links are document-relative.

## Display artifacts

The first-party reserved `display` tool advertises `display-artifacts.v1` and persists one ordinary `tron.display.v1` tool result in canonical Pi JSONL. The result carries bounded title, caption, alt/fallback text, semantic content kind, requested `sheet`/`inline`/`floating` surface, and an opaque artifact or public HTTPS URL reference—never workspace paths, bytes, credentials, cookies, dimensions, or screen coordinates. Gateway validates the closed shape into a typed transcript field before mobile rendering; malformed or non-`display` lookalikes remain ordinary tool output. Project sources are visible paths relative to the trusted session workspace, reject hidden/private components, traversal, and symlinks, open with no-follow semantics, are copied while hashing, and must preserve descriptor identity through publication. Magic/container signatures and UTF-8 validation fail closed for recognized types. Public URL display is credential-free HTTPS, rejects query/fragment persistence, local DNS suffixes, and local, private, reserved, link-local, or multicast IP literals; Gateway does not fetch or proxy it.

The display tool's model-facing guidance calls for proactive visual results when they help
users understand or judge the work: screenshots, UI/design previews, comparisons, charts,
and diagrams should not require a separate request. Bounded image previews prefer explicit
`presentation.surface=inline`; this is a relevance-based agent rule, not a change to the
transport's default surface. Decorative/redundant images are omitted. Captures and mockups
are labeled honestly, with concise alt text and no secrets; still images do not establish
animation, interaction, or physical-device validation.

Display bytes live under a separate durable Gateway store owned by `RuntimeRegistry`, not transient `BlobStore`. Random logical IDs reference immutable SHA-256 objects; logical session-owner links survive restart and are granted to a fork before its identity commit. Canonical display-result handoff and runtime binding reconcile session ownership against the complete JSONL tree, removing cancelled/provisional publications without deleting artifacts retained on reversible abandoned branches. Session deletion and catalog maintenance remove owner links, while shared objects remain until the last owner and active reader release them. The store bounds item/type bytes, logical bytes/count, concurrent ingestion/readers, owner fan-out, and a 1 GiB filesystem floor. Retention ownership alone never authorizes a read: the requested ID must also occur on the exact active canonical branch, so abandoned branches and deletion races fail closed. Downloads support one inclusive byte range, return 416 for malformed or unsatisfiable display ranges, honor a stable immutable ETag, send `nosniff`, and never enter WebSocket snapshots. The file-backed stream shares its `FileHandle` close authority, so an unread lease from a conditional 304 response closes without a descriptor race; the HTTP regression exercises a real stored file rather than a release counter. Unknown, missing, or corrupt objects remain explicit unavailable displays with canonical text fallback rather than being regenerated.

## Browser live viewing

`browser-live-view.v1` is a separate authenticated capability. The selected `agent_browser` package remains the sole automation/process owner. Its successful `get cdp-url` result receives an opaque `browser_live` source in both model-visible content and structured details; `display` consumes that handle without connecting. Live sources default to floating; other displays still default to sheets. Authority comes from finalized public SDK package provenance, not provisional loader metadata, output text, or a caller-supplied endpoint. The recognized source is the configured `git:github.com/fitchmultz/pi-agent-browser-native` repository (including the qualified revision spelling), not a verified code-hash attestation. The explicit-get path was qualified with wrapper 0.4.1 at `d6cde09af8d7757bbfba5a4ffaf83381bb392683` and native engine 0.33.2; updates need fresh qualification.

Per-action custom routing additionally requires the provider's `browserBinding` contract: `agent-browser.browser-binding.v1`, an exact local browser `cdpUrl`, native daemon `session`, process-ownership boolean `owned`, and `state: active|closed`. The native owner overwrites this reserved lifecycle metadata, including on execution errors; the wrapper promotes it from native envelopes, not page values or script `emit()`. Batch/script results stop at the final authoritative native binding, including explicit absence (`null`); unrelated local diagnostics have no observation. Successful cleanup marks an owned browser closed, while detaching from an externally owned browser does not claim to close it. Closed-browser chips remain manually activatable but never trigger automatic dead-browser popups. Commands without an observed local browser remain ordinary details. No extra CLI lookup, launch, resize or reconnect is performed by Gateway admission.

The adapter seals an opaque descriptor and its automatic-presentation policy to the canonical tool call and session using an ephemeral process key. Projection and branch authorization require the current session when verifying that receipt; copied calls/sessions and fabricated matching fields grant no viewing authority. Receipt verification is stateless. Multiple actions, explicit-get aliases and `display` calls reuse one exact endpoint/generation registration, never a reusable daemon name. A different UUID cannot replace another registration. Endpoint strings must already be canonical URL spellings; noncanonical aliases are rejected rather than keyed as another browser. An observed close retires only its exact generation and fences subsequent stale active results. Its descriptor remains in the same bounded receipt, including close-before-active, so repeated closed results retain one manual-only identity. The registry reserves at most 4,096 generation receipts across loaded sessions; exhaustion denies new admissions rather than forgetting a retirement fence, and load/session retirement clears its receipts. Browser-provider/native source adoption is separate from building Tron; the unmodified versions above do not supply per-action bindings.

Only an admitted canonical `display` result or sealed browser-action projection on the exact active session branch authorizes HTTP viewing. POST re-enters the existing device credential mutex after body consumption; final branch authorization, lease creation and response publication do not yield. Frame reads authorize and publish inside their initial credential admission. Frame/DELETE requests carry `X-Tron-Live-Lease` and `X-Tron-Live-Generation`; optional `X-Tron-Live-After` suppresses repeat JPEG delivery. A 204 response distinguishes `X-Tron-Live-State: waiting` (clear prior pixels) from `unchanged` (retain the already decoded frame). Observer failure ends its leases with a not-found response, not an endlessly renewable waiting state. Each viewer owns at most one unfinished HTTP frame response; overlapping reads fail busy without renewing the lease. Completion releases the write, while revocation, expiry and retirement abort it. Bytes already written to the network cannot be recalled.

A viewer starts one read-only CDP attachment to the exact loopback browser UUID endpoint. Fixed internal target/visibility queries follow tab changes while viewed. Confirmed target detachment retires that target's pending commands/pixels and fences late replies without ending remaining pages; ambiguous visibility, more than eight page targets, other command failures or a five-second setup/command deadline ends the observer. Successful screencast setup must also produce a valid frame from the selected target: a monotonic five-second first-frame deadline is checked by the existing 500ms reconciliation loop. It is cleared by the first admitted JPEG and rearmed on target replacement, so silent or wrong-target producers end viewing without imposing a heartbeat on static pages. No phone input becomes a CDP command. Producer ACK credits are paced at one per 200ms, with at most four pending credits and one replaceable encoded frame; only the newest candidate is allocated as JPEG bytes. Frames have a 2 MiB encoded, 2,560-edge and four-million-pixel admission limit using the JPEG's own dimensions; screencast requests cap the edge at 1,280. Registrations cap at 64, viewers at four per view and sixteen total. These are resource bounds, not an energy/latency benchmark.

Last-viewer close, device revocation, runtime/load replacement or transport disposal clears pixels and stops observation, never browser automation. Lost clients expire after fifteen seconds idle, checked by a one-second sweep that exists only while leases exist. Dismissal normally closes promptly over HTTP; immediate remote teardown cannot be guaranteed after network/process loss. Reopening may reconnect only the original UUID endpoint and never launches a browser. Frames never enter JSONL, immutable artifact storage, or a mobile artifact cache. The typed live descriptor contains no host path, endpoint or control capability; ordinary owner-authenticated browser-tool diagnostics retain their existing projection and are not a browser-control proxy.

Current integration scope is Gateway-managed RuntimeSlots. Native children use `agent_browser` through an explicit agent tool allowlist and provider extension; `display` remains parent-owned and is not needed by browsing children. Configure this in the user-scoped agent rather than rewriting packaged built-ins. Child live-view publication is out of scope. Process-wide browser admission is not implemented here, and viewer limits do not bound browser processes. Provider-owned crash cleanup and process admission require separate qualification before unrestricted parallel/unattended use; this adapter adds no Chrome reaper. Focused regressions: `server-live-view.integration.test.ts`, and the canonical-branch cases in `runtime-registry.integration.test.ts`.

## Uploads, blobs and exports

Uploads retain the 25 MiB per-request/prompt limit. Active and unclaimed
staging has its own 1,024-entry and eight-times-per-upload (200 MiB by default) quota; claimed canonical
history does not consume that quota, so older sessions cannot starve a new draft. Retained ownership is
separately bounded to 16,384 logical entries and 400 GiB of logical bytes by default; those retained
limits are checked only when a prompt claims staging, never while a user is still attaching a draft.
Every body reservation and temporary session-import copy conservatively preserves a 1 GiB filesystem
free-space floor, and every import copy is owned by a release lease so success and failure both remove it. A separate admission permits at most half the staging ratio
concurrently (four default 25 MiB bodies).

Authenticated chunks stream directly into protected staging files while computing SHA-256. Commit
atomically adopts one immutable, sharded content-addressed object and hard-links the stable logical UUID
path to it. Exact duplicate bytes therefore occupy one physical object while filename, MIME type, prompt
ownership, and public `upload:<uuid>` identity remain logical metadata. The folder's version-2 metadata is
the only accepted shape; a superseded shape is discarded as corrupt during inventory. Ordinary inventory
checks inode/size ownership without rehashing every retained object, and repairs a logical path that has
lost its object by stream-hashing it once, re-adopting the object, and fsyncing the object, its shard
directories, and the folder. The first read verifies a digest once per
process and caches that immutable-object proof; each maintenance pass rotates through one additional bounded
integrity audit. A failed digest retains logical/canonical metadata, marks the object unavailable, and fails
reads explicitly rather than silently dropping history. Orphan objects and malformed shards are removed only
after logical inventory is reconciled. An operational filesystem failure during startup validation (for
example a transient I/O or permission error while reading metadata or proving object ownership) is not
treated as corruption: the durable artifact and its immutable object are preserved, the identifier stays
explicitly unavailable to reads until a later validation succeeds. Quota-affecting ingest and
canonical reconciliation fail closed while any retained artifact cannot be accounted for. Both
orphan sweeps and healthy-sibling release preserve unknown object references; a failed validation
must not become data loss on the next initialization. The same distinction applies to a direct
upload lookup: only confirmed absence, symlink escape, or malformed evidence self-cleans, while an
operational ownership-check failure preserves the canonical folder and its indexed ownership.

Exact declared and observed sizes are checked before atomic metadata publication. Persisted logical
metadata remains limited to an exact 64 KiB canonical document; malformed or oversized entries self-clean
during startup inventory or direct materialization. Ordinary upload admission and periodic maintenance use the rebuildable in-memory
attachment index rather than reparsing retained history; only the at-most-1,024 unclaimed set is checked for expiry on each admission. Every rejection, overflow, truncation, or disconnect
removes uncommitted staging and releases its reservation. An authenticated client may immediately discard
an unclaimed upload when its local chip or presentation is retired; claimed prompt attachments reject that
operation. Remaining unclaimed uploads expire after 24 hours. Prompt attachment IDs are unique, and one
prompt cannot materialize more than the per-prompt byte ceiling. Startup performs the one physical inventory,
legacy migration, integrity/ownership reconciliation, and orphan-object sweep. The ten-minute pass, which the
background-work scheduler runs as one slice, then removes
stale bodies, expires indexed unclaimed files, retries pending cleanup, and removes claimed logical references
only when the canonical session catalog proves their owner no longer exists; it does not rescan every retained
metadata file. A later process start can always rebuild the disposable index from physical metadata.

`uploads.status` v2 exposes staging/claimed logical counts and bytes, unique object count/bytes,
deduplicated bytes, staging headroom, filesystem headroom/floor, pressure state, active body/import admissions,
unavailable objects, and cleanup backlog—never IDs, session IDs, paths, names, digests, or MIME data. Capacity failures identify
`staging_entries`, `staging_bytes`, `retained_entries`, or `disk` and include only bounded actionable
capacity facts. Publication fsyncs object/metadata files and their parent directories after atomic
link/rename boundaries, so acknowledged uploads are durable across power loss rather than merely process crashes.
The local-only retained tier remains subordinate to canonical session deletion; true
external/remote cold offload is intentionally deferred until an operator-owned destination and
lease-protected document rehydration contract exist. Mobile projection derives the
opaque upload identity from the validated store-owned canonical path, strips that private path, and
exposes the identity solely as an authenticated preview route; no extra identifier is added to the model
prompt. Unclaimed staging is never readable, while a prompt-owned file streams from its already-open
descriptor with its exact declared size and MIME type.
Successful imports remove
their staging folder; deleting a canonical session removes its claimed attachment folders. Cleanup
failure after canonical import/deletion success cannot turn that success into an ambiguous command receipt;
failed session-folder cleanup remains pending in the live store and periodic canonical-catalog maintenance
recovers it after process restart. Transient image blobs retain their 25 MiB item, 128-item, and 200 MiB aggregate
bounds; exact content deduplicates and access refreshes 30-minute idle expiry. Session archives use a separate protected,
file-backed export store because their capacity is unrelated to media admission. It admits one disk-reserved generation,
four readers, eight retained artifacts, 2 GiB per artifact, and 4 GiB aggregate, with a 64 MiB filesystem floor checked before copy/registration. Export registration and authenticated
HTTP delivery remain streamed with backpressure, support a single `bytes=start-end` range for bounded resume, and never retain a complete archive `Buffer` in Gateway memory.

An export captures one newline-terminated canonical descriptor/byte-length cut while briefly serialized with the live
runtime, then copies exactly that immutable prefix outside the session lane. Later appends therefore continue normally
and are excluded deterministically. A first-turn session whose Pi JSONL has not yet been created uses the runtime owner's
public append-only header/entry projection for that cut. JSONL preserves the complete canonical tree verbatim, including
abandoned branches and parent identities. HTML renders the captured active branch through Pi's documented standalone
export command in a child process, isolating the pinned renderer's current whole-document memory work from the Gateway
event loop. The response includes the exact generated size and advertises `session-export.v2`; older clients retain the
legacy 25 MiB download path. Active downloads survive pruning; expired IDs admit no new readers, and physical capacity
releases after the final reader. A requester disconnect does not alter the already captured cut: admitted generation remains
single-flight, HTML rendering retains its 15-minute kill bound, and any unclaimed completed artifact expires normally. Startup scavenges both disposable stores only after the Gateway binds successfully.
Capacity admission never evicts an ID already published to a client: excess projected images become bounded omission
text, while later requests can retry after expiry. Blob storage rejects control-bearing MIME metadata. Blob downloads
advertise byte ranges; malformed or unsatisfiable multi-range requests fail closed.
The retired `/engine` protocol is not exposed.

## Nested presentation

Nested `display` artifacts and trusted `agent_browser` live-view receipts have a separate
presentation seam because Pi's canonical `nestedCalls` summaries intentionally omit tool-result
payloads. Tron's first-party display extension observes nested `tool_result` events and retains
only validated display descriptors plus sealed browser receipt metadata, keyed to the parent call
ID. It caps the stash at 32 descriptors per parent and 16 KiB, reports `complete: false` when
bounded data is dropped, and clears it on parent completion, agent end/abort, or runtime shutdown.
It enriches the parent's Pi-owned tool result through `details.tronNested` only; Pi content and
`structuredContent` remain unchanged, and neither child rows nor independent child receipts exist.
Browser receipts are resealed to the parent's canonical tool-call ID, so the ordinary canonical
admission check remains authoritative. Display artifact bytes remain in the existing artifact
store. Transcript projection reads the same persisted parent details live and after cold reload;
`details.tronNested` is an additive Gateway wire field that older iOS decoders ignore.
The accepted P99-23 seam is exercised by `codemode-nested-presentation.integration.test.ts`.

## Prompt attachments and request size

Pi bounds the images that enter session history through `read`, `@file` arguments,
and tool results (2000x2000, 4.5MB encoded) but passes prompt-supplied attachments
through untouched. Tron owns prompt attachments, so `RuntimeSlot.prompt` bounds them
through the pinned SDK's own image pipeline before they become canonical entries. The
original upload stays in the upload store for previews and durable ownership; only the
copy admitted to model context is bounded. Every provider request re-serializes the
whole conversation, so an unbounded attachment is not a per-turn cost: a handful of
full-resolution phone screenshots can push a request past the provider's body limit,
which rejects the entire conversation instead of the offending turn. When the pinned
image backend cannot decode or bound an image, the original is kept rather than
dropping the user's attachment, matching Pi's tool-result normalization.

A provider that enforces a request-body limit answers with HTTP 413. Pi recovers an
oversized conversation by compacting it and retrying once, but only when the failure
matches an overflow pattern; an opaque provider body (for example opencode-go's
`server_error` wrapper) matches none, so the runtime retried the identical request and
then reported a permanent error, leaving the session unable to continue until it was
compacted. Tron's compaction policy classifies a 413 status as the generic
`context_length_exceeded` overflow so that existing recovery applies. The provider's own
text is preserved intact, and a session that cannot continue without shedding context
always has the user-visible **Compact Now** action as well.
