# gateway/display

## Purpose

Visual results in chat: the first-party `display` tool and its artifact store,
read-only browser and native live viewing, and nested-call presentation.

## Owns

`tron-display-extension.ts`, `display-contract.ts`, `display-artifact-store.ts`,
`browser-live-view*.ts`, `browser-live-cdp.ts`, `browser-tool-reference.ts`,
`native-live-view.ts`, `nested-presentation-extension.ts` and the capture/computer
extensions. Native capture qualification: [native tool
settlement](../../docs/native-tool-settlement.md).

## Contract

**Pure wire values.** [The L1 contract](../modules/display/contract.ts) owns the
projection/artifact/live-view descriptors, kind vocabulary and schema/capability
constants. Protocol consumes that contract directly; admission, provenance,
stores and live-view lifetime remain here. The module-host hooks are the existing
consumer operations, not a second display service port.

**Display descriptors.** `display-modules.ts` owns `DisplayOwner` and display/native-capture
metadata. Composition supplies its shared store, live views and lazy native session reads;
Display reads only disposal and canonical `ToolReferences`, not the Run implementation.
Native capture remains absent without live views. Transport consumes the owner directly.
The display projection also admits canonical artifact/live-view references in one scan;
runtime slots cache its result only for the exact current session and leaf.
It also admits each extension load with a display-owned session/generation/token scope;
extension attribution consumes that scope without depending on the live-view registry.

**Computer descriptor.** `computer-module.ts` owns `tron-computer` metadata and
its per-session extension. Availability remains Mac-only, sampled when the
runtime requests its extension; session identity is read at each operation.

**Display results.** `display` advertises `display-artifacts.v1` and persists one
ordinary `tron.display.v1` tool result in canonical JSONL: bounded title, caption,
alt/fallback text, content kind, requested `sheet`/`inline`/`floating` surface, and an
opaque artifact or public HTTPS URL — never paths, bytes, credentials or coordinates.
The Gateway validates the closed shape into a typed transcript field; lookalikes stay
ordinary output. Project sources are visible paths relative to the trusted workspace
(no hidden components, traversal or symlinks), opened no-follow, hashed while copied,
descriptor identity kept through publication; recognized types must pass magic and
UTF-8 checks. Public URLs are credential-free HTTPS without query or fragment, never a
local, private, reserved, link-local or multicast address; the Gateway never fetches
them. The tool's model guidance asks for proactive, honestly labelled visuals and
prefers `inline` for bounded images; that is guidance, not a transport default.

**Markdown images.** The first 16 distinct standalone image targets may snapshot visible relative PNG/JPEG/GIF/WebP children beneath the document directory, at most 25 MiB combined. Refused or missing targets count toward this bounded scan. The canonical `markdownImages` mappings contain destinations and ordinary immutable artifact descriptors, not filesystem authority. Missing/refused children stay unavailable; no remote fetch, traversal, symlink or lazy source resolver is admitted. Projection reference collection includes children for exact-branch reads, fork/rekey, restart reconciliation and deletion. [Rendering contract](../../../ios-app/docs/display-artifacts.md#markdown-images).

**Artifact store.** `DisplayOwner` coordinates one durable store constructed by
composition, separate from the transient `BlobStore`. Its traced lane admits reads and
session removal; Core supplies live deletion/membership facts and one exact-leaf reference
cut. Storage initialization remains parallel with blob initialization, then loaded-runtime
ownership reconciliation is awaited through the projection policy. Maintenance reads fresh
catalog membership, and rekey grants complete before identity commit. Store internals own: random logical IDs over immutable SHA-256 objects, session
owner links that survive restart and pass to a fork before its identity commit.
Ownership reconciles against the complete JSONL tree (abandoned branches keep theirs);
deletion and catalog maintenance drop links, objects go with the last owner and
reader. Bounds: item/type bytes, logical bytes and count, concurrent ingestion and
readers, owner fan-out, a 1 GiB filesystem floor. A read also needs the ID on the
exact active branch. Downloads: one inclusive byte range (416 when unsatisfiable),
stable ETag, `nosniff`, never in WebSocket snapshots. Missing or corrupt objects stay
explicit unavailable displays with text fallback.

**Browser live view** (`browser-live-view.v1`). `agent_browser` stays the only
automation owner. Its `get cdp-url` result carries an opaque `browser_live` source that
`display` consumes without connecting; live sources default to floating. Authority is
finalized SDK package provenance of the configured
`git:github.com/fitchmultz/pi-agent-browser-native` source (not a code-hash
attestation), qualified with wrapper 0.4.1 at `d6cde09af8d7757bbfba5a4ffaf83381bb392683` and engine 0.33.2;
updates need requalification. Per-action routing needs the provider's
`agent-browser.browser-binding.v1` (`cdpUrl`, `session`, `owned`, `state:
active|closed`), promoted only from native envelopes. The adapter seals the descriptor
to the tool call and session with an ephemeral key; copies grant nothing. One exact
endpoint/generation registration is reused; noncanonical endpoints are rejected; a
close retires only its generation (manual chips stay, no dead-browser popups). At most
4,096 generation receipts; exhaustion denies admission.

Viewing is authorized only by an admitted display result or sealed browser projection
on the exact active branch, inside the device credential admission. Frame and DELETE
carry `X-Tron-Live-Lease`/`X-Tron-Live-Generation`; `X-Tron-Live-After` suppresses a
repeat JPEG; 204 `X-Tron-Live-State: waiting` clears pixels, `unchanged` keeps them.
One unfinished frame response per viewer. A viewer makes one read-only CDP attachment
to the exact loopback browser UUID; target changes are followed; more than eight page
targets, ambiguous visibility, a failed command or a 5 s setup/command/first-frame
deadline ends observation. No phone input becomes a CDP command. ACK credits one per
200 ms, at most four pending, one replaceable frame; frames ≤ 2 MiB, 2,560 px edge,
4 Mpx (requests cap at 1,280); 64 registrations, four viewers per view, 16 total.
Last-viewer close, revocation, runtime replacement or transport disposal stops
observation, never the browser; idle leases expire after 15 s. Reopen reconnects only
the original endpoint. Frames are never persisted. Children use `agent_browser` through
their own allowlist; child live views, process-wide browser admission and a Chrome
reaper are out of scope.

**Nested presentation.** Pi's `nestedCalls` summaries omit results, so the display
extension stashes validated display descriptors and sealed browser receipts from
nested `tool_result` events per parent call (32 descriptors, 16 KiB, `complete:false`
when dropped), cleared at parent completion, agent end or shutdown, and enriches only
the parent's `details.tronNested`. Browser receipts are resealed to the parent call ID.
Projection reads the persisted details live and after cold reload.

## Invariants

- Viewing authority is always the exact active canonical branch; retention alone
  never authorizes a read.
- Runtime replacement and slot disposal revoke the retiring session's views and load
  token without revoking unrelated live sessions. The real-runtime lifecycle lock
  checks both boundaries and rejects re-admission with the retired token. Display
  performs retirement through the kernel's synchronous, best-effort `sessionRetired`
  observers; runtime slots do not retain the live-view registry.
- Live viewing never launches, controls or closes a browser.

## Verify

```bash
scripts/tron test gateway src/display/runtime-retirement.lock.integration.test.ts \
  src/display/display.store.lock.integration.test.ts \
  src/display/display-image-lifetime.integration.test.ts \
  src/transport/server-live-view.integration.test.ts \
  src/kernel/projection/codemode-nested-presentation.integration.test.ts
```

Canonical-branch cases: `runtime-registry.integration.test.ts`.

## Not here

- HTTP admission and leases' credential cut: [protocol](../transport/protocol.md).
- Uploads, blobs and exports: [uploads](../machine/uploads.md).
