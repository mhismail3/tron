# Knowledge contract

Records, curation, capture and connectors of `gateway/knowledge`. The module
[README](README.md) owns storage, catalog and invalidation.

## Library rows and previews

- `projection: "sourceRow"` returns `{rows, nextCursor?, stateRevision}`: identity,
  scope, timestamps, title, canonical and original URI, media type, capture
  disposition, admission, provider save and publication times, freshness with its
  age basis and days, verdict and replacement, `hasTake`, `tagsStale`, the preview
  reference and the current generated summary — never saved text or bytes. `ids`
  (1..64) refreshes exact rows in order. It requires `kind: "source"`, excludes
  suppressed records and keeps the privacy fence and admission partition
  (`includeArchived`, `includePending`).
- `sourceRowFields` is the single owner of row rules: `ageDays` and `freshness` are
  computed at read time from the save-time anchor, decay class and verdict, never
  persisted. `KnowledgeConfig.tagVocabulary` owns tag IDs, labels and decay classes;
  retired or merged selections read `unknown` freshness. The original URI is the
  requested URI recorded for this item, else the canonical one (HTTP(S) only). A
  provider save time is never shown as publication time. A summary appears only
  while its evidence digest matches the record's title and readable text.
- `knowledge.previews.read`: up to 16 exact references, each authorized by its own
  committed revision and rechecked after the read; ≤ 512,000 bytes each and 4 MB per
  batch; a bad item returns its own `unavailable`.
- `knowledge.search` scored pages order by relevance, freshness, recency and
  identity; the cursor binds query, filters, projection and state revision, and an
  older revision fails `conflict`.

## Records and observations

- Types: `knowledge-contract.ts` (schema v1). Sources, observations and notes have
  stable IDs and immutable revision IDs. Observation ranges carry ordered canonical
  entry IDs and a range digest (never an individual-line digest); coverage repeats
  them. `observed`, `empty`, `excluded` are terminal; `pending`, `failed`,
  `unavailable` change only by an explicit Clear: `knowledge.observation.dismiss`
  (`knowledge-coverage-dismiss.v1`) marks one cut `excluded` (`dismissed-by-user`)
  against its expected coverage revision, keeping range, digest and reason.
- Corrections create new revisions. Receipts hold references, not bodies.
  Forgetting removes every revision, fences the record, purges receipt payloads
  (keeping an invalidation marker), scrubs derivative evidence and relations and
  removes superseded verdicts naming it; shared objects live while referenced.
- Exclusions are revision-checked config (`eligibility.excludedSessionIds`,
  `excludedProjectIds`, `setScopeExclusion()` session, branch or project fences):
  records stay stored but are hidden from recall and display and cannot be
  reflected; `scopeExcluded()` is the shared predicate. There is no admission grant.
- `reflect()` takes a bounded set of observation revisions from one session and
  branch and replaces that session/branch synthesis derivative, recording the input
  digest and `derivedFrom` relations.
- Recall separates no-match from unavailable; its text carries bounded dated,
  attributed evidence and a pinned `knowledge.read` continuation (`id`,
  `revisionId`, `offset`) when incomplete. Search, recall and list hide
  personal-scope sources unless a scope is requested. Unscoped lexical recall ranks
  by score, then personal observations and notes before research sources, then
  freshness and recency; observations tie on `observedAt`. Session or entry filters
  refill bounded head batches and never remove sources or notes. Recall is not a
  corpus snapshot.
- Notes: structured fields with exact evidence revisions, validity, confirmation,
  scope, freshness, corrections, supersession and contrary evidence; `privacyScope`
  is descriptive only. Optional `tags` (≤ 8, `^[a-z][a-z0-9-]{0,47}$`, owner
  metadata, not the vocabulary; Home's profile uses `home-profile` and
  `kind-<kind>`), `retired: true`, and `provenance.reason` (≤ 2,000 characters). An
  update omitting `tags` or `retired` keeps them; `retired: false` in a draft
  restores a note. Older Gateways drop these on write, so downgrade is unsupported.

## Curation

- `knowledge.source.curate` (agent `curate`): one operation per batch of 1..25 items
  — `summary` (caller text with `full`/`sampled` coverage), `tags` (active
  vocabulary IDs), `verdict` (`evergreen`, `dated`, `superseded` with its
  replacement, or clear), `placement` (scope and/or admission) or `relation` (add or
  remove an edge). The owner derives `sourceRevisionId` and `evidenceDigest`;
  interpretation never replaces evidence. Archiving is admission, never a verdict
  (the legacy `archive` verdict decodes but is refused).
- Each item is its own receipted mutation (command ID derived from batch and entry):
  outcomes are per item (`stored`, `unchanged`, `conflict` with `currentRevision`
  for `stale-revision`, `excluded`, `forgotten`, `command-id-reuse`); a crashed batch
  re-runs with the same command ID. Batch summary text is bounded
  (`KNOWLEDGE_CURATION_MAX_BATCH_SUMMARY_CHARS`). The curation gate may stop a batch
  (later items `skipped`) only for budget-spending operations.
- **Vocabulary**, with its own revision: ≤ 256 lowercase-slug IDs, unique labels,
  definitions ≤ 512, slug categories, `ages`/`stable` decay, `active`/`retired`/
  `merged` (a merge names an active target; no cycles), guidelines ≤ 8,000.
  `knowledge.tags.configure` (agent `configureTags`) takes typed edits and
  `expectedConfigRevision`; `knowledge.config` cannot change it. A merge starts one
  receipted re-point batch (≤ 25) continued by `knowledge.tags.reconcile`. Label,
  category, decay and state edits reproject source heads in the same commit.
  `knowledge.tags.retag-needed` (agent `tagsNeedingRetag`) pages sources with no
  selection, a stale edition, retired or merged IDs, or a stale
  `curationInputsDigest` (title, summary, readable text, verdict and Your take).
- **Jev tagging.** `knowledge.source.tag` (agent `tagSource`, exact
  `expectedRevision`) and `knowledge.tags.run` (agent `retagQueue`, 1..25 entries)
  return owned `tags` jobs using the `typesafe` provider credential from Pi's
  provider settings. Evidence bytes: title 512, summary 2,000, text 8,000, take
  2,000, verdict 1,000, guidelines 3,000. A tag is selected above 0.65 confidence;
  above 16 active tags Jev first picks categories, then asks ≤ 16 per group. The
  write fences the vocabulary edition used. Take and summary changes start a
  single-source job; vocabulary edits run an estimate and one affordable queue page.
  No scheduler.
- **Paid ledger.** One durable monthly ledger (default ceiling 500 cents) for
  tagging, Jev assessment and Raindrop intake, keyed by the `typesafe` provider; a
  configured key is the consent. Each call reserves the 64,000-input-token ceiling
  (0.2688 cents at Tron's $0.042/M estimate; Pi's zero catalog price is not used)
  just before dispatch and settles to estimated usage. Uncertain dispatches stay
  reserved and block the month until `knowledge.tags.budget.reconcile` charges
  them in full; nothing is retried. `knowledge.tags.estimate` (agent
  `estimateTaggingCost`) and `knowledge.tags.budget` (agent `taggingBudget`) report.
  The standalone `jev` tool requires `maxChargeCents` checked against that ceiling.
- **Jobs.** `knowledge.source.summarize` (agent `summarize`) and tag jobs run outside
  the store lock and commit after revalidating source revision, config revision and
  privacy; duplicates share one job and charge. `knowledge.curation.jobs` (agent
  `curationJob`) reports `running`, `done` or `failed` with a code; each terminal
  transition publishes `knowledge.curation.job` with the same shape. Job state is
  process-local; the committed revision is the durable outcome.
- **Model output.** Summary and assessment replies must hold exactly one top-level
  JSON object (`knowledge-model-output.ts`; stray structural delimiters are refused);
  OpenAI Responses endpoints (`openai`, `azure`, `openai-codex`) also get a strict
  `text.format` json_schema. Invalid replies are `model-output-invalid`; no repair.
  A model timeout bounds the wait, not the operation; store writes that began finish.

## Capture and sources

- `SourceContent` keeps the immutable `object`, the bounded readable `text` and an
  optional `assessment`. `extractReadableText` is structural (no host allowlist):
  quote-, void- and raw-text-aware HTML scanning picks the deepest element holding
  half the page's paragraph text and ≥ 120 characters, drops site chrome and
  link-only siblings. Thin, chrome-dominated, app-shell or title-only results are
  `partial` with a `captureReason`. Quality is `complete`, `partial`,
  `metadata-only`, `inaccessible` or `failed` and never upgraded by assessment.
- Capture (`knowledge.source.capture`) uses manual redirects with per-hop public-DNS
  and SSRF checks, bounded bytes and script-free extraction; URL diagnostics are
  redacted. A blocked destination is kept as `reference-only` with a sanitized
  reason. Previews are exact canonical image objects (OpenGraph/Twitter or X Article
  covers, 512 KB, JPEG/PNG/WebP signatures); failures never fail capture.
  `evidenceDigest` is SHA-256 of UTF-8 `JSON.stringify({title, text})`.
- `knowledge.source.preview.refresh` (`{commandId, sourceId, expectedRevision}`)
  fills only a missing preview: `updated`, `unchanged`, `no-image` or `unavailable`.
  `knowledge.source.reextract` (agent `reextractSource`) recomputes readable text
  from the retained object without network, or returns `needs-evidence`.
  `recoverProviderSaveTime` reads the retained provider payload (Raindrop `created`
  only; never `lastUpdate` or mtime) and never overwrites a save time.
- `knowledge.source.assess` (agent `assessSource`) records a revisioned assessment
  (recommendation, confidence, classification) with `assessor: "model"` or `"jev"`
  (rubric, persisted `KnowledgeConfig.currentInterests`, refuses personal scope
  before reserving); it never changes admission. Oversized evidence is a labelled
  bounded excerpt (`sampled`), which may classify but never archive.

## Public X posts

The `knowledge` action `x` reads one HTTPS X post without credentials:
`x-public-post.ts` discloses only the numeric ID to FxEmbed v2 conversation (a
first-page 404 earns one `/2/status/{id}` root read), then X's public syndication
as a root-only fallback. Bounds: 2 MB per page, 8 pages, 256 items, 8 MB raw,
no redirects, 15 s total and 5 s per attempt, one try per provider, a 429 never
retried; User-Agent `Tron/0.1 (public-source-capture)`. Success needs the expected
root ID, shape and text or Article body. `publicPostCoverage` is `root`,
`conversation` or `thread`; continuations need numeric author identity and an
explicit parent chain. Results and Articles stay partial unless verified; tool
output over 128 KB fails. `publicPostLookup: true` on capture stores the post
(canonical `https://x.com/i/web/status/{id}`), captures provider-declared outbound
URLs as separate related Sources (the final URI rechecked atomically, hidden owners
updated in place) and updates the same Source on retry. Private bookmarks are
discovered only by the paid OAuth X connector; browser state is never used.

## Connectors

- Connection setup owns the account, Raindrop collection roles and `credentialRef`
  (`connector:<provider>:<account>`), resolved only by the Mac Keychain adapter:
  printable ASCII tokens, one quoted `add-generic-password` command over `security
  -i` stdin (< 4096 bytes), never arguments. Tests inject a temporary keychain.
  Tokens never reach state, receipts, logs, prompts or iOS. A missing Keychain item
  names the service and account to add.
- Actions need an exact `connectionId`; readiness reads the current instance
  revision, policy and `credentialAvailability`/`providerIdentity`. A Raindrop
  `/user` admission may record `providerDisplayName` for the matching `_id`;
  repeating the current projection writes nothing. `allowWrites`,
  `paidAccessApproved` and `recurringApproved` default to false.
- Primitives make no admission decisions: `connectorDiscover` (provider IDs and
  metadata persisted before the checkpoint advances; offset pages restart at zero),
  `connectorQueue` (≤ 25 items, no payload), `ingestItem` /
  `knowledge.source.ingest` (one scoped item kept pending with provider identity,
  payload, collection provenance and save time), `connectorAck` (processed or
  skipped with a reason), `raindropMove`. Runs serialize per provider; identity
  reuse goes through a catalog index keyed by provider/account/item.
- **Raindrop**: `/rest/v1/raindrops/{collectionId}` pages; `knowledge.raindrop.read`
  (agent `raindrop`) verifies `/rest/v1/user` before each read and returns raw
  bounded metadata (`perpage` ≤ 50, 2,000,000-byte responses, 128,000-byte agent
  text, `Retry-After` honored, no redirects). `ConnectionInstance.raindropCollections`
  maps 1..64 collections to `research`, `personal`, `archive` (one home each) or
  `triage`, replaced only against `setupRevision`; unmapped collections are refused
  before I/O; archive collections are never ingested. `raindropMove` takes no
  destination: it derives the home from the source's admission and scope, verifies
  the live item, returns `already-home` without a write, and otherwise needs
  `allowWrites`, a durable effect receipt before the PUT and read-back
  reconciliation; uncertain PUTs are never retried.
- **X**: OAuth 2.0 PKCE public client (`tweet.read users.read bookmark.read
  offline.access`); access and rotating refresh tokens only in the Keychain, the
  rotation written first; one refresh near expiry or on 401. `/2/users/{id}/
  bookmarks` costs $0.001 per resource: each request reserves
  `ceil(requested/10)` cents and settles `ceil(returned/10)`; 4xx settles zero;
  server errors, bad envelopes and network uncertainty stay reserved until
  `reconcileConnectorBudget`. `knowledge.x.credits` reads balances without spending.
  `knowledge.connector.status` reports `capCents`, `spentCents`, `reservedCents`,
  `availableCents`, `month` and `uncertain`.
- Raindrop, X and Jev share a fixed-host no-redirect HTTPS transport; public capture
  keeps its DNS-pinned arbitrary-URL transport.

## Raindrop intake

`knowledge.raindrop.intake` is the manual bounded workflow; `dryRun` only discovers.
Research admission needs a pilot ID, ≤ 10 items and ≤ 100 cents, persisted as a
receipt-backed cohort per collection; `knowledge.connector.assessment.approve`
appends a new cohort (optionally freezing `itemIds`) without resetting receipts.
Each item keeps its Raindrop JSON as a `provider-api` representation, linked
evidence and collection provenance; X permalinks use the public post reader; GitHub
UI pages and incomplete captures stay pending and unmoved. After each item settles
its revision enqueues a summary (if it has readable text) and then a tag job.
Assessments reserve on the shared ledger just before the HTTP dispatch; a valid
earlier assessment with the same digests is reused. Results report per-item
outcomes and cohort cost totals from durable receipts. Moves revalidate the
committed revision, identity, object and live collection. Archived sources leave
normal retrieval but can be listed, read and restored; pending captures need
`includePending`.

## Publication and recovery

Heads come from one owner (`headFor`). `upgradeStorage()` rebuilds every head from
its latest revision in one transaction, fsyncs and writes the manifest last
(idempotent; failure keeps the old manifest and logs `knowledge.upgrade-failed`). The
storage-v1 reader admits ≤ 64 MiB, validates everything, prepares a new catalog and
publishes v2 by replacing the small manifest; there is no dual write or downgrade.
Cleanup intentions and tombstones commit before deletion; `reconcile()` retries exact
pending cleanup. Historical revisions do not expire. Missing, malformed or newer
state, unsafe ancestors and corrupt files stay visible failures. Object reads verify
hash and size; media type belongs to the reference.

Explicit profile partitions use `knowledge-notes.ts`: complete ID/revision/file
assignments, full original histories and immutable prepared identities in an
owner-only ≤ 64 MiB backup before any body mutation, then one SQL head commit.
Recovery validates exact originals/history and adopts those same identities;
rescanned identical destinations create no revisions. Invalid, stale, incomplete,
excluded or over-bound plans refuse without truncation or inferred classification.
This is storage recovery, not canonical Changes/undo publication; the
[Home profile owner](../modules/home/profile.md) owns that audit boundary.
