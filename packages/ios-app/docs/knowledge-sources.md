# Knowledge dashboard presentation

The dashboard is one library opening on **Sources**. Its filter sheet picks one collection —
**Sources**, **Syntheses** or **Legacy history** — and, for Sources, visibility (saved, pending,
archived); filters never mutate admission. Legacy history lists the preserved observations of the
retired Chronicle producer (gateway [Knowledge](../../gateway/src/knowledge/README.md), #1315),
read-only, searched through `knowledge.search`, each opening with its cited chat range. Needs
attention (coverage) opens from the logo menu.

## Knowledge Sources presentation

- **Rows** read the bounded `projection: "sourceRow"` page (identity, title, links, preview
  reference, admission, dates, summary, tag labels, age, `hasTake`, `tagsStale`), never saved
  text or objects; without `knowledge-library-rows.v1` the view shows an update-the-Gateway
  placeholder. A row is a title (≤ 2 lines), one domain/type line, freshness and verdict text and
  a square preview (the Gateway's safe JPEG/PNG/WebP or X Article cover, else a deterministic
  fallback). Intake assessment and capture state are not shown.
- **Cache.** The first page per profile and filter (≤ 8 filters per Gateway, one page each,
  size-capped) shows immediately while the Gateway's page replaces it; never across profiles.
- **Images** are content-addressed by the published hash (fetched once, verified), batched ≤ 16,
  bounded in memory and on disk; a refused image is remembered and retried once on reconnect.
- **Search** waits for a settled query (300 ms, ≥ 2 characters), cancels superseded reads and
  pages with the same cursor; rows prefetch the next page (no Load more).
- **Invalidation.** `knowledge.changed` with an equal state revision changes nothing; named rows
  patch in place; anything else (unknown row, no revision, an active search) merges a fresh first
  page beneath the reached rows. Syntheses and Legacy history keep full records.

**Entry Detail** shows the row's header, link and summary at once and replaces them with
`knowledge.read` at the row's exact revision and admission authority. One header container:
title, a domain pill (the original link, opened in `TronSafariView`) and a preview spanning both.
The original link is the source of truth; captured bytes and extraction are not reading surfaces.
Inline below: **Summary** (Generate/Regenerate), **Your take**, vocabulary tags with their
updating state, verdict (Evergreen, Dated but useful, Superseded, Clear), a replacement picker
(bounded search incl. archived), Research/Personal scope, Archive/Unarchive, and **Details**
(type, publication/save/capture dates, freshness and age basis, capture state, origin, media type,
revision), then notes, related entries (one bounded rows request), links and coverage. The
original-link pill uses the requested URL recorded for that saved item (HTTP(S) only); Raindrop
`created` is the save time, never a publication date.

- **Summary.** Opening never generates. **Generate AI summary** starts the Gateway-owned job and
  returns; the job survives dismissal, backgrounding and reconnect; reopening queries
  `knowledge.curation.jobs`; repeated taps share the command ID; failure shows Retry without
  clearing existing data. A summary whose evidence digest no longer matches title and text is
  withheld (**Regenerate**); partial evidence is labelled sampled.
- **Your take** autosaves after an idle pause and on dismissal; a failed save keeps the newest
  process-local draft with Retry, never resurrected after a successful settle or attached to a
  replacement Mac (`testOlderFailedTakeKeepsNewerDraftAfterReopen`,
  `testOlderFailedTakeCannotResurrectSettledDraft`,
  `testRetiredTakeFailureCannotAttachToReplacementMac`); a stale revision shows the current take
  and keeps the draft. **Updating tags** shows only while the Gateway's tag job runs.
- **Curation.** Verdict, placement and admission use receipted `knowledge.source.curate`;
  anything other than `applied`/`unchanged` is a failed edit with Retry; a conflict reloads
  `currentRevision` with archived and pending authority. No free-form tags or client summaries.
  Reads are fenced by presentation activity and Gateway identity; accepted mutations belong to
  the Gateway's receipt and job owners.
- **Assessment.** `knowledge.source.assess` with `assessor: "model"` shows its recommendation
  without changing admission. Prices are fractional cents (`Double`); tagging and assessment share
  one 500-cent monthly budget with the TypeSafe key as consent. `evidenceDigest` is reproduced
  from Gateway `JSON.stringify({title, text})` without Foundation's slash escaping (a shared test
  vector). Knowledge models are the background queue
  ([settings model 6.3](../../gateway/docs/settings-model.md#63-model-fallback-queues));
  `KnowledgeConfig.knowledgeModel` round-trips only its character limits.

Validation: `TronKnowledgeDetailUITests` against the hosted scripted Gateway
([iOS development](development.md)).

## Sheet and accepted-command lifetime

Knowledge and Connected Services forms bind their originating Mac and lifecycle generation
(`KnowledgeDestinationIdentity`) apart from the disposable socket identity
(`KnowledgePresentationIdentity`): backgrounding and same-Mac reconnect retire reads, not fields
or accepted handles; a new destination invalidates the sheet, so a draft never targets another
Mac. `KnowledgeMutationObserver` observes one accepted task while its sheet is active and rejoins
it after suspension without resubmitting; `ConfirmedMutationExecutor` resolves uncertain receipts
with a fresh admitted connection. X OAuth never recreates PKCE for a missing receipt: an
unresolved begin or completion keeps its command ID and offers **Check setup status**
(`command.status` only); a full redirect URL wins over code plus state; tokens stay on the Mac.
MCP add, token storage and sign-in capture their destination; a real profile or credential change
closes the form and fences late results; success clears only the submitted draft; add and token
storage stay separate commands.
