# Tron session search: implementation plan

Status: implemented in source on `feature/session-semantic-search`, based on
`3d1a9329d951b0bb81ce4cfd02f73383eb39be7d`; not deployed. Lexical retrieval,
qualified local semantic retrieval, opt-in Jev ranking with durable allowances,
multi-Gateway grouped results, and bounded historical navigation are present.
The maintained runtime contract is [session-search.md](session-search.md), with
iOS window ownership in `packages/ios-app/docs/session-search-plan.md`. This
plan records the design and acceptance targets; targets are not measured claims.
Signed helper availability and explicit per-Gateway consent still gate their
respective capabilities. Production corpus latency, physical-device behavior,
and live-provider ranking have not been validated.

Final focused validation passed: Gateway typecheck and 113 tests; iOS test build
and 297 tests covering search transport, presentation, transcript and scroll
owners; protocol and personal-information guards. A full Gateway run passed
1,652 tests and failed three Knowledge timing tests; those two test files passed
all 31 tests in an isolated rerun. The full concurrent suite is therefore not
claimed green. No Gateway lifecycle transition or app installation was performed.

## 1. Scope and non-goals

The feature is a resilient, hybrid **session search** used by the iOS dashboard
search field:

- typing immediately filters the already-authoritative title/workspace catalog;
- after a bounded debounce, the Gateway searches all admitted canonical session
  content, not just rows currently visible in iOS;
- lexical retrieval covers words, phrases, identifiers, paths, and exact
  substrings;
- local sentence embeddings add genuine semantic recall, including queries with
  zero shared lexical terms with the matching passage;
- a bounded, explicitly opted-in Jev pass may rank a small candidate set for
  relevance; Jev is called through `JevDecisionClient`, never by starting a Pi
  agent turn or invoking the `jev` extension from a session;
- results contain a session summary and deterministic excerpts anchored to exact
  canonical entry IDs; selecting one opens the owning Gateway and navigates to
  that exact message.

The feature does **not** create a session database, a second Pi runtime, an event
journal, a remote corpus mirror, generated snippets, query replay, automatic
prompt replay, or a remote full-corpus upload. It does not alter canonical JSONL,
Pi settings, runtime ownership, branch selection, or chat identity.

Performance numbers below are proposed admission targets until measured. They
must not be advertised as guarantees:

| Stage | Proposed target (warm index, representative fixture) |
|---|---:|
| title/path filtering | same SwiftUI frame/update path as today; no network wait |
| Gateway lexical response | p95 <= 150 ms |
| local semantic candidate retrieval | p95 <= 500 ms |
| optional Jev refinement | p95 <= 1.5 s, hard deadline <= 3 s |
| index append after a canonical append | p95 <= 1 s without blocking chat |

Measure cold startup, corpus rebuild, old/deep matches, concurrent typing, and
partial index states before retaining or changing these targets.

## 2. Source findings and ownership seams

### Canonical session and catalog owners

- `packages/gateway/src/sessions/runtime-registry.ts` owns canonical session
  discovery, identity/path admission, user-versus-delegated topology, catalog
  generations, invalidation, live summary overlays, and `pageSource()`. Its
  structural index intentionally retains metadata only and never transcript
  text. Search must consume this authority and must not add a competing catalog.
- `packages/gateway/src/sessions/catalog-metadata-index.ts` is the existing
  bounded metadata acceleration. It records file identity, size, mtime, EOF and
  tail evidence; it is a model for reconciliation and strict symlink/path
  admission, not a place to add searchable message bodies.
- `packages/gateway/src/sessions/session-branch.ts` provides
  `branchFromParsedSession()`, which selects the current leaf-to-root branch from
  parsed canonical entries, but it does not reject duplicate IDs or malformed
  disconnected records. Search must first run the stricter graph validation
  equivalent to `fork-boundary.ts` (duplicate IDs, malformed IDs/parents,
  cycles, missing parents) over the complete parsed file, then select the
  branch. Open runtimes must use the SDK-selected branch through the owning
  `RuntimeSlot`, never reparse and guess a leaf.
- `packages/gateway/src/sessions/fork-boundary.ts` is the authority for
  inherited-entry ancestry. A search index identity includes an optional exact
  `ForkBoundaryAnchor` (child session, inherited anchor ID, gap ordinal,
  boundary kind). For a child, all entries at or before the inherited anchor on
  the validated child branch are excluded from searchable passage rows; the
  boundary itself remains metadata. This applies when parent/child IDs overlap,
  the child has no own entries, and the child leaf later advances.
- `packages/gateway/src/sessions/runtime-slot.ts` owns one live runtime per
  session. `snapshot()` and `transcriptPage()` call the canonical projection;
  `transcriptPage()` validates runtime generation, leaf ID, and entry anchors.
  Search does not instantiate another live `SessionManager` for an open session
  and does not read a second mutable runtime. Live append/branch/rekey/delete
  callbacks notify the search owner to invalidate or enqueue exact work. Add
  an explicit derived-observer hook carrying the canonical append/branch cut;
  generic `changed` events without an entry ID are not index triggers. Startup
  initializes the coordinator after catalog admission, and registry disposal
  cancels workers/helper children before runtime teardown.
- `packages/gateway/src/sessions/projection.ts` and the protocol projection
  types define safe transcript content/roles/semantic metadata. Reuse their
  content extraction/redaction policy where possible; do not infer user-visible
  text from rendered SwiftUI rows.

### Gateway transport and Jev owners

- `packages/gateway/src/transport/gateway-service.ts` registers the method
  allowlist, drain list, observer admission, `session.list`, `session.open`,
  `session.transcript`, and canonical session operations. Add `session.search`
  and consent/config methods here. Search is a bounded observer read and must
  use `awaitWhileClientConnected(..., client.signal)` (or the equivalent owner
  cancellation boundary) at every filesystem/helper/Jev await.
- `packages/gateway/src/transport/server.ts` owns WebSocket request lifecycle,
  client disconnect signals, frame bounds, and `session.listChanged`/summary
  broadcasts. Search responses remain request-correlated; no search result is
  broadcast globally. Add one capability string to `system.info` only when the
  protocol contract is updated together.
- `packages/gateway/src/protocol/types.ts` is the typed, bounded wire projection
  owner. Add `SessionSearch*` request/response/status/result types with strict
  counts, byte limits, enum admission, index coverage, semantic status, and
  optional Jev status. Keep canonical entry IDs and profile/session IDs
  opaque, bounded strings.
- `packages/gateway/src/knowledge/jev-client.ts` already pins
  `jev-1.13.0`, enforces the existing request/body/state/response bounds,
  validates typed answers, cancellation, credential ownership and no automatic
  retries. Search must call this class directly. The existing client’s
  `maxChargeCents` guard is per-call only; search needs a separate durable
  aggregate reservation/receipt owner before dispatch.
- `packages/gateway/src/knowledge/connector-credentials.ts` and
  `packages/gateway/src/index.ts` already construct the Mac Keychain-backed
  `JevDecisionClient`. Pass that same capability into the search service; never
  read keys in the search index, iOS app, environment, argv, or worktree.

### iOS transport, projection, and navigation owners

- `packages/ios-app/Sources/UI/Chat/SessionShellView.swift` currently owns the
  dashboard search state. `filteredSessions` at approximately lines 872–881
  filters title and cwd only. Preserve `DashboardPresentationSnapshot`, server
  filtering, workspace disclosure, expansion, route replacement, scroll state,
  and composer behavior. Replace only the search presentation owner with a
  search coordinator that layers authoritative local catalog filtering and
  Gateway result rows without rewriting `visibleSessions`.
- `packages/ios-app/Sources/State/AppModel.swift` is the MainActor composition
  façade. `visibleSessions`, `dashboardPresentationRevision`, profile switching,
  `activateDashboardProfile()`, `navigationRoute(...)`, and
  `performOnOwningGateway(...)` are the seams for search. Search requests must
  capture profile ID, lifecycle generation and connection ID, then reject late
  success/error/loading publication after profile switch, disconnect, dismissal,
  or a newer query.
- `packages/ios-app/Sources/State/DashboardGatewayConnectionPool.swift` owns one
  bounded client per eligible background Gateway and paged user catalog reads.
  Search can query each eligible profile only through this pool (or a focused
  lifecycle client for the selected profile), never by creating another socket.
  Each profile result remains qualified by `gatewayProfileID`; one offline
  profile is partial failure, not an empty global result.
- `packages/ios-app/Sources/Gateway/GatewayClient.swift` owns request
  correlation, transport epochs, cancellation, and deadlines. Add no second
  response decoder or ad-hoc WebSocket. The pool’s request path must retain
  captured connection admission and return `CancellationError` for retired
  epochs.
- `packages/ios-app/Sources/Models/SessionCatalogModels.swift` owns summary
  DTOs and profile-qualified dashboard IDs. Add search DTOs in a focused
  `SessionSearchModels.swift`; enforce bounded excerpts, result counts, anchor
  identity, coverage status, and explicit semantic/Jev availability in decoding.
- `packages/ios-app/Sources/State/SessionPresentationStore.swift` owns the
  mounted authoritative snapshot, exact transcript paging, runtime/leaf/branch
  fencing, and prefix coverage. Its transcript seam admits atomic `before` or
  `after` cursors with adjacent projected-entry identity, so forward pages cannot
  silently skip byte-bounded content. Search navigation must use it, not a
  transcript cache. Extend its existing `session.transcript` anchor flow to load/locate a
  result’s canonical entry, then hand the exact entry ID to the existing scroll
  owner in `ChatView`/`ChatScrollCoordinator`.
- `packages/ios-app/Sources/UI/Chat/SessionTreeSheet.swift` already resolves an
  exact `initialEntryID` for history sheets, but that is not a direct transcript
  jump. Keep evidence/history routes unchanged and add a distinct search-anchor
  route or presentation command so selecting a search result opens the chat and
  jumps directly to the matching canonical message without changing composer
  ownership or current scroll continuity for an already-mounted chat.
- `packages/ios-app/Sources/UI/Chat/ChatView.swift`,
  `ChatTranscriptScrollView.swift`, and `ChatScrollCoordinator` are the physical
  scroll owners. They must admit a search jump only after the exact transcript
  page is installed and layout is settled, with an exact presentation/anchor
  token. A search result must never reset the composer, replace a live chat
  snapshot, or cause automatic tail-following.

## 3. Search data contract

### Search scope

The first product scope is `scope: "user"` and current canonical branch only.
A result is eligible when all of the following hold:

1. `RuntimeRegistry` admits the session as a user session for the requesting
   profile; delegated/subagent-only rows are excluded by default.
2. The canonical JSONL path is regular, non-symlinked, within the admitted
   session root, and passes the same identity/path/file evidence used by the
   catalog.
3. The entry lies on the branch selected by the canonical leaf and parent links.
4. The entry is a visible user or assistant message with text content. Thinking,
   hidden internal messages, status/state records, and image bytes are excluded.
5. Tool output is excluded by default. A future explicit scope can include
   bounded tool result text, but it must be a separate user choice and a
   separate coverage/ privacy label; never mix it silently into the default.

Retained pre-compaction history means canonical entries still physically present
in the JSONL branch, including entries before a compaction summary. The indexer
must retain and search those entries. Text removed by compaction and no longer
present in canonical JSONL is not recoverable and is reported as ordinary corpus
coverage, not as a fabricated match. Compaction and branch summary entries are
not searchable bodies. Forks are separate canonical sessions: the child’s own
current branch is searchable only when it is an admitted user session; inherited
parent entries are represented by the child’s fork boundary but are not duplicated
in the child index. Delegated child sessions and process transcripts remain out of
scope until an explicit scope is designed.

### Result shape

The additive search RPC is carried by the existing protocol v5 capability
`session-search.v1`; it does not change `config/GatewayProtocol.json` or the
minimum protocol. Older iOS clients never call the method and continue their
existing title/path filter. Method-specific bounded Swift/TypeScript decoding
and capability tests are the rollout contract.

The proposed `session.search` response is:

```text
{
  query, queryRevision,
  corpusRevision, indexRevision,
  coverage: { state: complete|indexing|partial|unavailable, sessionsIndexed,
              sessionsTotal, passagesIndexed, omittedSessions, reason? },
  semantic: { state: ready|indexing|unavailable|unsupportedLanguage|disabled,
              modelRevision?, language?, dimension?, reason? },
  ranking: { state: lexical|localSemantic|jev|jevUnavailable|budgetLimited },
  results: [{
    sessionId, title, cwd, gatewayProfileID?, updatedAt,
    entryId, parentEntryId?, ordinal,
    passageKind: user|assistant,
    snippet, // deterministic canonical text, bounded; never model-generated
    lexicalScore, semanticScore?, jevScore?,
    indexRevision, anchorRevision
  }]
}
```

Results are grouped/presented by session but each passage retains its exact
canonical `entryId`. A stable comparator sorts (Jev score when available,
semantic score, lexical score, session updated time, session ID, entry ID) with
no random or provider-order tie break. A single session has a bounded number of
passages; response bytes and node counts remain below existing protocol limits.
The result’s `anchorRevision` identifies the canonical file identity, leaf ID,
branch digest, fork-boundary cut and entry ordinal used to prove navigation.
Search navigation is a distinct Gateway contract, not an unvalidated route
field: `session.search.anchor` accepts session ID, entry ID, anchor revision,
expected runtime generation/leaf and a bounded page budget; Gateway obtains the
owning open slot when present (otherwise a strict canonical read), validates the
exact admitted branch/cut/file identity, and returns either the exact entry page
or `changed`/`not_found`. It never substitutes a same-ID/new-content row.

### Deterministic excerpts

The Gateway loads matching entry content from canonical JSONL after candidate
selection and derives a bounded excerpt around the literal match or a stable
middle/first sentence for semantic-only matches. Normalize whitespace only for
presentation; preserve code punctuation and identifiers. Do not use Jev or any
model to generate, paraphrase, summarize, or select factual snippets. If the
entry disappears or its branch digest changes before response publication, omit
that result and mark coverage stale rather than returning an unanchored excerpt.

## 4. Derived index design and invalidation

### Storage and authority

Add a Gateway-owned `SessionSearchIndex` under a disposable cache directory
owned by `GatewayConfig.tronHome` (for example
`<tronHome>/gateway/cache/session-search/`). It is not under the Pi session
folder, Knowledge canonical catalog, iOS cache, or internal workspace documents.
The cache has a versioned manifest containing index schema, tokenizer/chunker
revision, embedding model revision, language, dimension, corpus fingerprint and
bounds. It can always be deleted and rebuilt from canonical JSONL; absence or
corruption never prevents chat or session listing. Its directory is checked for
0700 ownership and excluded from logs/diagnostic export; secure deletion is not
claimed as an SSD erasure guarantee. Queries/result caches expire and are
bounded. Terms, trigrams, vectors, and cache keys remain sensitive derived data
and never enter diagnostics.

Use Node’s pinned built-in `node:sqlite` (already used by
`knowledge-catalog.ts`) with rollback journaling, secure deletion, and a
workspace mutex. Milestone B has a build qualification gate: execute a real
`CREATE VIRTUAL TABLE ... USING fts5` probe against the exact pinned bundled Node
runtime before publishing an FTS schema. If FTS5 is absent, publish the explicit
term/trigram postings schema instead, with its measured bounds; there is no late
startup shape switch after clients depend on it. The search index must not store
raw transcript text:

- a contentless FTS5 term table or equivalent postings table stores searchable
  terms and row IDs only;
- a bounded trigram postings table preserves identifier/path/substring recall;
- metadata stores session ID, entry ID, branch/file identity, role, ordinal,
  token/gram counts, vector blob, vector model revision/language/dimension and
  no excerpt/body;
- snippets are read deterministically from canonical JSONL at query time.

If the chosen contentless index cannot support deletion/update safely, use
explicit postings tables with transactional row replacement; do not silently
switch to a raw-body FTS mirror. Search cache files are chmod 0700/0600 and are
never uploaded or included in diagnostics.

### Chunking and lexical retrieval

Index one message entry as one passage when within the passage byte bound. Split
large text at paragraph/sentence boundaries with deterministic overlap and keep
the canonical entry ID plus passage ordinal. Preserve code fences, paths,
identifiers and punctuation in the trigram stream; use Unicode case folding only
for a separate normalized lookup. Phrase confirmation always re-reads the
canonical entry so an index token collision cannot publish a false hit.

Lexical query handling has an explicit parser:

- quoted phrases are exact normalized phrase candidates;
- ordinary terms use term postings/intersection/union with bounded top-K;
- short identifiers and path-like queries use trigrams plus canonical exact
  verification;
- empty/overlong/control-containing queries are rejected or treated as the
  title/path-only empty state, never sent remotely;
- all query expansion is deterministic; no synonym toy is used as semantic
  recall.

### Local semantic backend (selected prerequisite)

No semantic wire status may be `ready` until the real signed helper artifact has
passed capability, supported-language, input-limit, vector-dimension, finite
value, and synthetic zero-overlap recall/negative-control qualification on a
supported macOS build. A mock helper test can cover framing only and is never
semantic acceptance. If qualification fails, the shipped lane remains
`unavailable`/`unsupportedLanguage` and lexical search remains functional; stop
and escalate rather than adding ONNX, remote embeddings, or a synonym imitation.

Use a narrow signed macOS helper backed by Apple NaturalLanguage’s
`NLEmbedding.sentenceEmbedding(for:)`, not ONNX, Ollama, a remote embedding API,
or a fake synonym table. Apple documents the real API as returning an optional
`NLEmbedding` for an `NLLanguage`; implementation must query that API at runtime.
The helper must validate actual model availability, supported languages, input
length, vector dimension and finite values. It must not download language assets,
request permissions, or alter OS settings. Unsupported language/model state is a
truthful `unsupportedLanguage`/`unavailable` result and lexical search remains
available; this does not count as satisfying semantic search.

The helper is a stateless bounded vector capability. It is not a session store,
indexer, scheduler, worker framework or Gateway authority. Add a macOS executable
source/target (exact names to be finalized during implementation, e.g.
`packages/mac-app/Sources/SearchEmbedding/SessionSearchEmbeddingMain.swift` and
`TronSearchEmbedding` target) that:

- reads newline-delimited JSON requests from stdin and writes one bounded JSON
  response per request to stdout;
- supports only `capabilities` and `embed` operations;
- returns `modelRevision`, `language`, `dimension`, `vector` and request ID;
- rejects unknown fields, oversized UTF-8 text, too many queued requests,
  non-finite/incorrect vectors and mismatched model revisions;
- processes requests serially in one process (or a fixed, bounded pool only if
  measured); applies per-request and overall idle deadlines;
- closes stdin/stdout on cancellation, kills/reaps the exact child, and never
  lets a stale helper response satisfy a successor request;
- emits no transcript text in stderr/logs.

Gateway executable resolution is explicit and fail-closed: stable builds use
`TRON_GATEWAY_PAYLOAD_ROOT` (set by the existing signed launcher) and resolve a
fixed relative path under the owned app payload, such as
`<payloadRoot>/../../Library/Native/Tron Search Embedding`; development builds
may use a dedicated absolute `TRON_SEARCH_EMBEDDING_HELPER` supplied by the
repository’s controlled build/run helper. Never search `cwd`, `PATH`, or a user
writable arbitrary executable location. Packaging must add the helper to the Mac
app’s explicit copy/sign phase, deep signature validation, payload fingerprint,
architecture checks and `scripts/tron mac verify` contract. The existing
`packages/mac-app/project.yml`, `bundle-gateway.sh`, payload verifier and Mac
architecture/development docs are the owners. Do not add a second copy through
Xcode’s ordinary Resources phase.

The vector metadata is part of the index identity. A vector is comparable only
when model revision, language, dimension, tokenizer/chunker revision and
normalization match exactly. Any change deletes/rebuilds derived vectors; it
never compares incompatible vectors. Startup capability probing is bounded and
cached only for the current helper process; index readiness is separately
revisioned.

### Incremental indexing

`SessionSearchIndexCoordinator` is driven by canonical catalog evidence and
runtime lifecycle callbacks, not by iOS polling:

- initial startup schedules bounded background indexing after the canonical
  catalog is admitted; it never blocks Gateway readiness or `session.list`;
- new/append-only files index from the last newline offset after verifying inode,
  header, leaf and tail evidence;
- a live session’s pre-append/message-end hook enqueues the exact file/entry;
  no transcript-wide rescan is needed for ordinary appends;
- same-inode rewrite, branch/fork/rekey, changed leaf, compaction replacement,
  deletion, path replacement or digest mismatch transactionally removes all old
  postings/vectors for that session and queues a full rebuild;
- deletion/rekey marks rows stale before the registry pre-hook, removes or
  renames them only after canonical commit, and restores the stale marker when
  the commit fails; an old identity is never published under a new ID;
- deletion removes index rows/cache files only after canonical catalog evidence
  proves the owner is gone; uncertain canonical state marks the session stale
  and leaves no published result;
- after each rebuild, publish the new index revision only after file identity,
  branch digest, model metadata and row bounds are committed; a late worker
  cannot publish an older revision;
- at most one indexing operation owns a session at a time, with bounded global
  filesystem/helper concurrency and a fair queue so one huge session cannot
  starve the catalog.

Index status reports complete/partial/indexing with omitted session counts and a
bounded reason. Partial indexing never becomes “zero matches”; lexical results
are labeled partial and semantic results are labeled unavailable/partial when
appropriate.

## 5. Hybrid query pipeline

1. **Admission:** trim and validate query/filters; capture client signal, profile,
   corpus/index revision, scope and a unique request generation. Reject after
   disconnect/revocation. Do not start a paid call during admission.
2. **Immediate iOS layer:** `SessionShellView` filters current authoritative
   dashboard summaries by title/path and server filter synchronously. This
   preserves the existing instant affordance even while the Gateway is offline.
3. **Lexical retrieval:** Gateway contentless postings/trigram lookup returns a
   bounded candidate set. Canonical reread verifies exact phrases, computes
   snippets, and drops stale branch/file identities.
4. **Local semantic retrieval:** if the helper is qualified and the query is
   eligible, embed the query, cosine-search compatible vectors, and merge a
   bounded semantic shortlist with lexical candidates. The response carries
   `semantic.state = partial` plus vector counts whenever only part of the
   admitted corpus has compatible vectors; `localSemantic` never implies
   complete recall unless semantic vector coverage equals the corpus revision.
   ANN is not required for
   the first bounded corpus; benchmark SQLite/linear scan against measured
   corpus sizes before adding another index. A zero-overlap fixture must return
   the paraphrased passage through this lane, not through lexical expansion.
5. **Optional Jev ranking:** only when the durable consent/allowance admission is
   active, select at most 16 candidates and build the exact serialized state and
   questions first. Measure UTF-8 byte sizes against all existing
   `JevDecisionClient` limits (24 KB state, 28 KB state-plus-question, 60 KB
   body, 16 questions) before reserving any spend. Reserve the client’s
   conservative maximum charge (currently `64_000 * 42 / 10_000_000` cents),
   settle using validated `usage.input_tokens`, and use fixed integer
   micro-cent accounting/rounding. The Jev adapter returns explicit dispatch
   certainty of `notSent`, `sent`, or `uncertain`; credential/read/validation
   failures before POST release the reservation, while timeout/cancellation or
   transport failure after POST retain an `uncertain` receipt and never retry.
   Use one typed `score` question per candidate with fixed 0–4 criteria:
   unrelated; incidental; related but weak; directly useful; strong direct
   answer/context. Require the existing response validator’s ordered/probability
   constraints. No model output is copied into the UI except numeric ranking
   metadata. If dispatch outcome is uncertain, retain the reservation and expose
   `budgetLimited`/`jevUnavailable` rather than replaying.
6. **Deterministic merge:** lexical exact matches are retained even when Jev
   scores them lower. Sort with stable tie-breakers, cap sessions/passages,
   reread canonical anchors, and publish only if query generation, index
   revision, profile/connection, branch/file identity and signal remain admitted.
7. **iOS publication:** coordinator publishes loading/results/error only when the
   exact managed dashboard presentation activity, profile/lifecycle admission,
   request generation and latest query still match. Dismissal cancels task and
   clears results; an older request may not clear a newer result or loading flag.

No Jev call occurs for title/path-only filtering, empty queries, offline
lexical-only operation, unavailable helper, or a request without explicit remote
consent. Query/result cache entries are bounded and keyed by profile, corpus
revision, query normalization, scope, model/rubric revision, semantic model
identity, and consent mode. Do not cache raw excerpts beyond the managed result
TTL; never persist private query/result history as canonical state.

## 6. Privacy, consent, and spend admission

Add a dedicated Gateway-owned session-search policy/ledger, separate from Pi
settings and Knowledge. It is stored under the Gateway home with strict file
ownership and durable atomic updates. It contains only policy, bounded
reservations/receipts and hashes/IDs—not credentials, transcript bodies, or
queries. The policy owner exposes:

- remote Jev ranking disabled by default;
- an explicit iOS disclosure explaining that selected deterministic excerpts and
  the search query are sent to the configured Jev provider for relevance scoring;
- an explicit user command to enable the feature and set a bounded per-query and
  aggregate daily allowance;
- a durable command ID, policy revision, requesting device identity and exact
  allowance reservation before paid dispatch;
- `reserved`, `settled`, `uncertain`, `expired` receipts with bounded retention;
- no release of an uncertain reservation based only on a timeout; manual
  reconciliation/clear is required by the owner policy;
- aggregate in-flight and daily caps enforced before every batch, so concurrent
  devices/queries cannot exceed the allowance;
- reset/revoke on consent disable, device revoke, policy revision change, or
  Gateway restart recovery according to the durable receipt state.

Allowance authority is explicitly **per Gateway profile**. The selected
profile’s Gateway owns consent, reservations, and its local daily cap; a query
fanned across profiles has one independent allowance decision per profile and
reports those outcomes separately. The product does not claim a user-global
aggregate cap across independently owned Gateways. iOS must use the captured
`GatewayConnectionAdmission` expected-connection overload for every background
profile request, and a retired profile request is discarded rather than
qualified by a successor epoch.

The only remote payload is the bounded query plus selected excerpts after a
conservative deterministic secret scrub (API-key/token/password/private-key
patterns and known credential-shaped strings). Redaction is explicit in
response diagnostics (`redactedCount`), never logged with source content, and
must not claim to guarantee discovery of all secrets. Thinking/hidden/internal,
tool output, attachments and binary content are never sent. Consent text must
state provider retention/processing is outside Tron’s control. If consent is
revoked or the allowance is exhausted, local lexical and semantic results remain
usable and the UI labels remote ranking unavailable.

The Jev provider key remains in the existing Mac Keychain credential owner.
There is no iOS key, environment secret, argv secret, or source fixture key.
Tests use synthetic provider credentials and HTTP fixtures only; no live provider
calls/private corpus uploads are permitted during implementation or validation.

## 7. Protocol and iOS presentation milestones

### Milestone A — contract and pure search primitives

Add focused Gateway modules/tests (names may follow repository conventions):

- `packages/gateway/src/sessions/session-search-contract.ts` — bounded DTOs,
  query/scope/coverage/status admission, anchor identity and stable comparator;
- `packages/gateway/src/sessions/session-search-tokenizer.ts` — deterministic
  Unicode terms, phrases, identifiers, trigrams and canonical snippet rules;
- `packages/gateway/src/sessions/session-search-branch.ts` or shared helpers —
  parse JSONL using pinned `parseSessionEntries` plus
  `branchFromParsedSession()`; test malformed/cycle/missing-parent cases;
- `session-search-contract.test.ts`, `session-search-tokenizer.test.ts`, and
  branch/snippet fixtures for exact phrases, identifiers, code, redaction and
  no generated text.

Update `packages/gateway/src/protocol/types.ts` and the shared protocol contract
only after DTO limits are frozen. Add iOS `SessionSearchModels.swift` and
`GatewayProtocolContract.swift` decoding/admission tests. Do not bump protocol
version until all source and generated/fixture consumers are updated atomically.

### Milestone B — disposable lexical index and canonical invalidation

Define the open-runtime authority before implementing query rereads: the indexer
and snippet loader call a registry-owned bounded `readSearchCut(sessionID,
anchor)` that returns the exact slot-selected branch/text cut when the session is
open. It never creates a second `SessionManager` or tails a file concurrently
with SDK append. Cold sessions use a complete-file descriptor/line-commit read
followed by full graph validation; incomplete final lines are omitted and mark
coverage partial. The same returned cut feeds postings validation, snippets and
anchor RPC validation. Add the stricter complete-graph validator and exact
`ForkBoundaryAnchor` exclusion before branch rows are published.

Add `session-search-index.ts`, `session-search-index.test.ts`, and
`session-search-index-invalidation.test.ts`. Implement contentless FTS/postings,
trigram postings, metadata, file/branch fingerprints, transactional replacement,
startup rebuild, partial status, cleanup, and bounded mutex/concurrency. Wire one
`SessionSearchIndexCoordinator` into `RuntimeRegistry` as a disposable owner;
reuse catalog evidence/path admission and canonical lifecycle hooks. Add no RPC
until the index has behavioral tests for append/rewrite/delete/rekey/fork,
malformed files, old retained entries, and partial coverage.

### Milestone C — signed local embedding helper

Add the stateless Swift helper under the Mac source owner, its exact target and
copy/sign/fingerprint validation in `packages/mac-app/project.yml`,
`packages/mac-app/scripts/bundle-gateway.sh`, payload validation fixtures and
Mac docs. Add a Gateway `session-search-embedding-client.ts` with framed I/O,
explicit resolver, capability handshake, model metadata checks, bounded queue,
request timeout, cancellation, child exit/reap and shutdown cleanup.

Before claiming semantic support, run a real helper artifact against synthetic
paraphrase/negative-control fixtures on macOS. Confirm actual supported
languages, length limits, model revision, dimension, finite vector values and
stable cosine behavior. If API availability or quality is insufficient, stop and
escalate rather than adding a fake fallback or silently declaring semantic
search complete. Lexical operation must still work with helper unavailable.

### Milestone D — Gateway RPC and Jev policy owner

Before enabling the semantic result state, run the signed helper qualification
from Milestone C and record the actual model/language/dimension/input limits in
the source-owned fixture. A failed qualification is a blocked semantic release,
not permission to ship a keyword-only implementation under a `ready` label.

Add a `SessionSearchService` that composes index, embedding client, canonical
snippet loader, Jev client, and policy ledger. Inject it from
`packages/gateway/src/index.ts`; expose only `session.search`,
`session.search.policy.get`, and confirmed `session.search.policy.set` (or a
single equivalent policy API) through `GatewayService`. Add drain/read admission,
request cancellation, bounded response projection, diagnostics without content,
and a capability string.

Add `session-search-service.test.ts`, `session-search-rpc.test.ts`,
`session-search-jev.test.ts`, and policy/ledger tests covering state/body/question
bounds, highest-probability validation, no retry, reservation/settlement and
uncertain dispatch. Add transport tests for disconnect/revocation, duplicate
request IDs, stale catalog revisions, response byte/node limits, and partial
profiles. Run `scripts/personal-info-guard.sh`.

### Milestone E — iOS dashboard search and exact navigation

Add a MainActor `SessionSearchCoordinator` (likely under
`Sources/State/`) and integrate it into `AppModel`,
`DashboardGatewayConnectionPool`, and `SessionShellView`. Preserve existing
server/workspace filters and local title/path matching. Use 150–250 ms proposed
debounce only after measurement; cancel the previous task before starting a new
one and carry the exact presentation activity/profile/connection/query fence
through every await.

Add nested session/passage result rows with deterministic excerpts and clear
labels for partial indexing, helper unavailable, Jev disabled/unavailable and
offline profiles. The default UI never implies that a partial index is complete.
Add explicit consent/allowance disclosure before remote Jev ranking; no search
keystroke may silently enable or spend.

Add the `session.search.anchor` Gateway RPC and a separate search-anchor route
field to
`AppModel.SessionNavigationRoute` (do not overload history-sheet semantics),
pass it through `SessionShellView`/`ChatView`, and extend
`SessionPresentationStore` plus `ChatScrollCoordinator` to issue the bounded
anchor RPC and load pages toward the exact entry using existing `before`, runtime
generation, leaf ID and next-entry fences. Install and scroll only after the
page/layout gate; if canonical branch
or file identity changes, show “result changed” and do not substitute another
entry. Keep the existing `initialHistoryEntryID` evidence route behavior.

Add Swift unit tests for DTO bounds, nested grouping, latest-request fences,
dismissal/profile-switch cancellation, offline/partial labels, route identity,
exact anchor navigation and preservation of an already-mounted chat’s composer/
scroll state. Add a UI validation scenario for typing, selecting a deep result,
returning to dashboard and reopening the search surface.

### Milestone F — documentation, measurement, and release gates

Update nearest owners: `packages/gateway/README.md` for Gateway/search
invariants and operational bounds, `packages/gateway/docs/session-search.md`
(or this plan promoted to the final contract), `packages/ios-app/docs/architecture.md`
and development/events docs, and `packages/mac-app/docs/architecture.md`/
`development.md` for helper packaging and manual artifact validation. Add the
protocol fixture and capability to any contract generator/check.

Measure and record warm/cold lexical, local semantic and Jev paths with bounded
synthetic corpora. Use matched release/optimized Mac and iOS builds for claims;
simulator/debug timings are diagnostic only. Capture recall@K, zero-overlap
semantic recall, p50/p95/p99 latency, CPU/memory/index bytes, helper failure
recovery, Jev calls/cost reservations, and UI frame/composer/scroll regressions.
Do not retain a speed claim without representative evidence and a correctness
oracle.

## 8. Acceptance matrix

| Requirement | Evidence required | Owning tests/checks |
|---|---|---|
| Instant title/path search | UI responds without Gateway round trip | existing dashboard tests plus new search coordinator test |
| Full content literal search | old/deep user+assistant entry, phrase, identifier/path, exact canonical anchor | tokenizer/index/service/RPC tests |
| Genuine zero-overlap recall | real signed NaturalLanguage helper artifact retrieves synthetic paraphrase; negative control does not; unsupported model is not called ready | helper qualification + semantic integration test; no mock-only pass |
| Stable snippets | output equals canonical deterministic excerpt; Jev text cannot alter it | snippet/service tests |
| Nested results | multiple passages group under profile-qualified session | DTO/UI tests |
| Exact navigation | selected entry loads via existing transcript paging and scrolls exact ID | SessionPresentationStore/Chat UI validation |
| Active branch/forks | current branch only; fork and parent do not duplicate | branch/index invalidation tests |
| Retained pre-compaction history | physically retained old entry searchable; omitted history honestly absent | fixture/index test |
| Tool/hidden privacy scope | default excludes tool/thinking/hidden/delegated content | index/privacy tests |
| Incremental invalidation | append, rewrite, delete, branch/rekey, replacement never publish stale rows | coordinator tests |
| Partial coverage | interrupted/oversized/malformed corpus reports partial, not zero | index/RPC tests |
| Latest request fencing | rapid queries, dismissal, profile switch, reconnect cannot publish stale data | Swift coordinator and Gateway cancellation tests |
| Helper resilience | unsupported language, missing helper, malformed frame, timeout, crash, queue full | helper/client tests and signed artifact smoke |
| Jev bounds | exact prebuilt UTF-8 state/questions satisfy <=16 questions, <=24 KB state, <=28 KB state-plus-question, <=60 KB body; certainty transitions and no paid retries | Jev adapter/ledger fixtures |
| Consent/spend | default off; explicit disclosure/allowance; per-Gateway/profile cap and uncertain dispatch; no false cross-Gateway aggregate claim | policy/ledger/RPC tests |
| No corpus upload | recorded fixture inspects provider body contains only bounded selected excerpts | Jev HTTP fixture/privacy guard |
| Existing dashboard UX | server/workspace filters, identity, scroll expansion, composer unchanged | focused Swift UI tests and manual path |
| Protocol/package correctness | additive v5 capability and method-specific decoding agree; signed helper is owned/fingerprinted and actual helper qualification passes | protocol verifier, Mac build/sign checks |

## 9. Validation and manual operations

Local validation, in order:

```bash
cd packages/gateway
npm run check
npx vitest run src/sessions/session-search-*.test.ts src/transport/session-search-*.test.ts
npm run build
cd ../..
scripts/personal-info-guard.sh
scripts/verify-gateway-protocol-contract.py
```

After Mac helper source/packaging exists, use the canonical generated project and
read-only artifact checks; do not install or replace the app:

```bash
scripts/tron mac generate
cd packages/mac-app
xcodebuild build-for-testing -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64'
# Validate the staged/signed artifact and helper path; do not run Gateway lifecycle.
scripts/tron mac verify
```

For iOS source changes, use the skill-owned route:

```bash
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileTests/SessionSearchTests
```

A maintainer/user must manually perform any app replacement and Gateway
transition using the Mac reinstall/runbook. Agents may prepare artifacts and
report exact paths, but must not restart, rebuild, promote, install, or deploy a
Gateway/app. No live Jev provider call or private transcript upload is part of
validation.

Manual release gates before enabling the default semantic lane:

1. Build/sign the helper in a clean Release composition; verify fixed payload
   path, deep signature, architecture, fingerprint and no duplicate Resources
   copy.
2. On a supported macOS version, run the real helper capability probe and
   synthetic zero-overlap fixture. Confirm unsupported languages remain explicit.
3. Build a synthetic canonical corpus containing old retained entries, long
   identifiers, exact phrases, paraphrases, forks, deleted/replaced files,
   malformed entries and redacted credential-shaped text.
4. Exercise iOS typing, switching profiles, disconnecting, dismissing search,
   selecting a deep result, and returning while an existing chat is mounted.
5. Configure explicit Jev consent/allowance with synthetic credentials only;
   verify bounded request bodies, no retry, concurrent cap, uncertain dispatch
   retention and local fallback.
6. Observe index coverage, helper/Jev status, latency, memory, CPU and cache
   bytes from content-free diagnostics. Ensure no transcript text, query,
   excerpt, vector payload or secret appears in logs/diagnostic exports.
7. Only after all gates pass should a maintainer perform the documented manual
   Mac app replacement/Gateway transition and then validate the matching iOS
   protocol artifact. Existing users without the new helper remain on lexical
   search with an explicit semantic-unavailable label.

## 10. Risks and explicit stop/escalation conditions

- **NaturalLanguage quality/availability:** NLEmbedding is optional by language
  and runtime. If the actual macOS helper cannot load a sentence model, has
  unacceptable paraphrase recall, or cannot satisfy bounded framed execution,
  stop before declaring semantic search shipped. Escalate a backend decision;
  do not add ONNX, remote embeddings, or a synonym imitation silently.
- **Contentless lexical index cost:** postings and trigram rows can become large.
  Measure index bytes and query tails; bound corpus work and make coverage
  visible. Do not store raw bodies to hide the cost.
- **Canonical race:** an entry can change between candidate selection and snippet
  load. Revalidate file identity/branch digest/entry ID immediately before
  response and navigation; stale results are omitted or explicitly stale.
- **Jev spend/dispatch uncertainty:** local search must never depend on Jev.
  Reserve before dispatch, never retry a paid/uncertain call, and retain
  uncertain reservations. If the ledger cannot prove aggregate caps across
  restart/concurrency, disable remote ranking rather than spending.
- **Privacy leakage:** deterministic redaction is not perfect. Default to no
  remote excerpts, exclude hidden/thinking/tool/delegated data, disclose provider
  processing, and keep all provider fixtures synthetic. Any requirement to send
  full corpus or unbounded content is out of scope and requires user approval.
- **Transport/UI races:** latest-request fencing must cover debounce, RPC,
  helper, canonical reread, Jev, profile activation, view dismissal, and every
  publication. A successful test that only fences the final await is insufficient.
- **Protocol rollout:** session search requires a matching Gateway/iOS contract.
  Missing capability remains a graceful lexical-only path; do not widen minimum
  protocol or invent an old-client compatibility mirror. Protocol changes are
  Mac-first and require manual artifact validation.
- **Index corruption/partial startup:** discard/rebuild only the disposable
  search cache. Never delete or rewrite canonical JSONL, Knowledge state,
  credentials, settings, or iOS application/Keychain data.
- **Operational boundary:** source/build preparation is allowed; Gateway
  lifecycle transitions, app installation/replacement, deployment and live paid
  provider calls remain maintainer/user actions.
