# Home memory ownership

Home's endless conversation, physical chapters and episodic summaries are one
continuity subsystem with distinct authorities. This map locates those owners;
the [Home contract](../src/modules/home/README.md) and
[episodic contract](../src/episodic/README.md) retain their detailed policies.

## State and policy authorities

| Authority | Files / symbols | Manifest |
|---|---|---|
| Designation, chapter ledger, rollover, pause and memory lifetime | `modules/home/home-owner.ts` (`HomeOwner`), `home-chapter-state.ts`, `home-chapter-materialization.ts` | `src/modules/home/home.module.json` |
| Chapter counts and summary-topic presentation | `modules/home/home-chapter-contents.ts`; Home's `chapterList` | Home |
| Memory binding, readiness and frozen activation view | `modules/home/home-memory.ts` (`HomeMemory`) | Home |
| Activation boundary, request fidelity and Home cache placement | `modules/home/home-request-policy.ts`; `home-module.ts` composes hooks and the background queue | Home |
| Model-facing `zoom`, `date`, `memory_search` schemas and results | `modules/home/home-memory-tools.ts`, `home-memory.ts`; `tron-home-extension.ts` registers them | Home |
| Ordered chapter deltas, source cursors and exact evidence proofs | `episodic/home-source.ts` | `src/episodic/episodic.module.json` |
| Permanent projected indices, tree, pump, invalidation and view | `episodic/episodic-memory.ts`, `episodic-tree.ts`, `episodic-projection.ts` | Episodic |
| Summary prompt, size feedback, provider adaptation and cache pieces | `episodic/episodic-compactor.ts`, `cache-layout.ts` | Episodic |
| Persisted catalog, nodes, cursor, block and spend | `episodic/episodic-store.ts`, `episodic-contract.ts` | Episodic |
| Browser admission, cursor encoding and display projection | `episodic/home-memory-browser.ts`; `EpisodicMemory` constructs pages | Episodic |
| Canonical JSONL parsing, branch reads and digests | `kernel/session/canonical-reader.ts` | `src/session-catalog.module.json` |
| Canonical live runtime and mutation ordering | `kernel/session/runtime-registry.ts`, `kernel/run/runtime-slot.ts` | `src/run.module.json` |
| Wire shapes and RPC dispatch | `protocol/types.ts`; `transport/gateway-service.ts`, `server.ts` | `src/protocol/protocol.module.json`; `src/transport/transport.module.json` |

Paths in the table are relative to `packages/gateway/src/`, except manifest paths,
which are relative to `packages/gateway/`. Home and episodic are L3 capability
owners. `episodic-contract.ts` is episodic's shared implementation contract, not
a separately owned pure L1 public contract. Canonical reader and runtime files
share a physical `kernel/session/` directory but have different manifest owners.

## Lifetimes and boundaries

- `HomeOwner` supplies the ordered ledger snapshot and holds one `HomeMemory`
  keyed by stable `homeId`. Physical chapter rotation and runtime eviction do not
  rotate that memory namespace or reset its spend.
- `HomeMemory` configures the binding and ingests before serving tools. An
  activation waits only for the view before its input boundary, then freezes that
  view across its tool loop. Home owns admission and pause, not a second tree pump.
- `EpisodicMemory` owns node scheduling and stale-result rejection.
  `EpisodicStore` owns durable derived state, never the canonical transcript or
  Home ledger. Home supplies the summarizer; the background queue owns model choice.
- `home-source.ts` assembles chapter deltas and frozen proofs using the canonical
  reader. Source cursors and projection stay episodic-owned; canonical parsing and
  digests stay with the session catalog. Producer line bounds belong to
  `kernel/resources/prompt-bounds.ts`, not a second reader-specific policy.
- Browser reads refresh without starting summary work. Home fences the binding,
  ledger and complete source proof; episodic fences the tree revision. A page
  cannot publish after either authority changes during an await.
- Chapter topics use already-built summaries and never schedule compaction.

## Native and model consumers

The native browser uses `home.memory.view` and `home.memory.evidence`, plus
`home.chapterList` for chapters. iOS `State/HomeSheetReadOwner.swift` owns bounded
DTO validation and current-request publication; `AppModel.readHomeSheet` performs
the identity/capability-fenced RPC. Both belong to `Sources/state.module.json` (its State directory claim).

`HomeSheets.swift`, `HomePagedListSheet.swift`, `HomeMemorySheets.swift` and
`HomeChapterSheets.swift` own native routes, the disposable page feed and rendering
under `Sources/UI/Chat/chat.module.json`. They do not maintain a memory corpus.
`HomeToolDetailPresentation.swift` belongs to the same Chat owner but renders the
recorded tool invocation's text/details. It does not fetch browser evidence.
The two consumers deliberately have different contracts; a browser projection
must not be presented as model-tool output or exact canonical evidence.

Personal notes belong to [Profile](../src/modules/home/profile.md); research
sources are ordinary exported files. Knowledge observations and coverage have no
runtime reader or Home memory feed. Their backup-first retirement is an explicit
offline maintainer operation, never episodic initialization or Home-memory deletion.
