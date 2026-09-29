# Agent-curated Knowledge library

- **Started:** 2026-09-28
- **Status:** Active
- **Last updated:** 2026-09-29, K1–K3 done
- **Goal:** Agents keep every Library entry summarized, tagged, judged for freshness and correctly scoped, guided by the user's own takes, so useful sources surface on their own in future work.

## Goal and constraints

The user saves links for two reasons, and Knowledge must keep them apart:

- **research** scope is the resource bank: anything that may help a future
  project or task, and should surface organically even when forgotten.
- **personal** scope is Moose's Corner: fun, novel items that say something
  about the user but have no expected work value. They surface only when the
  user asks about himself or his collection, never in work retrieval.

Decisions the user made (2026-09-28 interview), which override an agent's own
judgment:

- Agents may edit summaries, tags, notes, verdicts, scope, admission and
  relations, and apply those edits directly. Every edit goes through the
  Knowledge owner as a new revision with a receipt, so it is reversible.
- Summaries are written by `opencode-go/deepseek-v4.1-flash`, automatically at
  intake. This is a separate enrichment model setting; the observation model
  stays as it is.
- Tags come from a controlled vocabulary the user owns. Jev decides which tags
  apply to each entry, using the entry's content, written tagging guidelines,
  and the user's take. Re-tagging must be cheap enough to rerun whenever the
  guidelines or a take change. Jev spend is capped at $5 per month.
- Each entry has one permanent, editable **Your take** note written by the user.
  It feeds tagging, verdicts and retrieval every time, not just once.
- Default freshness when no verdict exists: tools, products and news age after
  about six months; ideas and principles do not age.
- Verdicts: evergreen, dated but useful, superseded (with a link to what
  replaced it), archive. Nothing is deleted automatically; archive is
  recoverable admission.

What must not change: captured evidence stays immutable and the original link
stays the source of truth; Chronicle observations and notes keep their current
visibility (the personal-source retrieval rule applies to sources only); no
arbitrary record replacement or JSON patch API; no Gateway lifecycle action by
an agent; no recurring automation is enabled without the user's explicit
go-ahead.

This plan replaces the 2026-09-23 Knowledge agent enrichment plan, deleted on
approval with a HISTORY entry; its task details (evidence
binding, receipt/revision fences, dashboard invalidation, date recovery) are
carried into K1, K2 and K6 below.

## Context

Inspected 2026-09-28 on `main`.

- Library: Resources (163) and Agent Sorted (113) are fully captured as
  `research` sources. Unsorted (15), Moose's Corner (106) and Shopping (26) are
  not ingested. No entry has a generated summary yet.
- The Raindrop connector's scope is one collection (Resources). Intake always
  captures as `research`.
- Summaries today: an explicit per-entry button that calls the configured
  observation model on saved readable text. Page extraction keeps site chrome
  (GitHub pages start with thousands of characters of navigation), which
  poisons summaries.
- Tags today: free-form, generated with the summary. There is no vocabulary.
- Jev (`jev-1.13.0`) answers typed `choice`, `noul` and `score` questions, at
  most 16 per call, about $0.042 per million input tokens. Knowledge paid access
  is currently off with a zero budget.
- Notes already support confirmation, freshness, supersession and exact
  evidence references; freshness is otherwise only on Jev assessments.
- Agent retrieval (`knowledge` search/recall) does not weight freshness and does
  not distinguish personal sources.
- Library rows, batch previews, coalesced change events and lock-free reads
  landed on 2026-09-28; K6 builds on them.

## Plan rules

- **Evidence vs interpretation.** Summaries, tags and verdicts are
  interpretation and carry producer provenance (model or user, time, evidence
  revision). They are withheld or marked stale when their evidence changes; they
  never overwrite captured evidence.
- **One write path.** Built-in generation, Jev tagging, agent edits and the
  iOS Your take field all publish through the same typed Knowledge operations.
  Model and Jev calls run outside the store lock; publication is a short
  compare-and-commit on the expected revision.
- **Costs.** Every Jev call reserves against the monthly budget before
  dispatch; uncertain outcomes are reconciled, not retried blindly. Bulk
  re-tagging reports its estimated cost before running.
- **Tests.** Write the failure modes down first; prefer one integration case
  per boundary that leaves an inspectable artifact.

### Reliability bar for agent editing tools

The user requires these to work reliably, not just exist. Every K1 operation,
exposed through the agent `knowledge` tool and RPC, must:

- be idempotent by command ID: a retried or replayed call returns the original
  outcome without a second model/Jev charge or a second revision;
- fence on the expected revision and return a typed conflict carrying the
  current revision, so an agent can re-read and retry deliberately;
- fail with typed, actionable errors (stale revision, unknown tag, budget
  exhausted, entry excluded/forgotten, invalid input) rather than generic ones;
- read back what it wrote: the tool result includes the committed revision and
  the fields as stored;
- support bounded batches (for example up to 25 entries per call) with a
  per-item outcome, where one failing item never aborts or rolls back the others;
- tolerate concurrency: two agents, or an agent and the user, editing one entry
  produce one winner and one clean conflict, never a lost update;
- recover after a Gateway restart mid-batch using receipts, reporting items as
  applied, skipped, conflicted or failed.

Acceptance: an end-to-end test drives the real agent tool against a real store
through a 25-entry batch with an injected conflict, a replay, a budget stop and
a simulated restart, and writes a JSON outcome report as its artifact.

### Interaction bar for Entry Detail

Generate/regenerate summary, re-tag, editing Your take, changing verdict,
scope or admission, and editing tags must all be smooth and non-blocking:

- the sheet never freezes, never blocks scrolling, and never disables unrelated
  controls while work runs; only the control doing the work shows progress;
- long work (summary generation, re-tagging) runs as an owned Gateway operation
  that survives sheet dismissal, app backgrounding and reconnects; reopening the
  entry shows it still running or its result, and the result appears in the
  open sheet and Library row via `knowledge.changed` without a manual refresh;
- repeated taps do not start duplicate work or double-charge (same command ID
  while in flight);
- Your take autosaves after a short typing pause and on dismissal, keeps the
  local draft if saving fails and retries, never loses typed text to an
  incoming revision (a conflict shows both and keeps the draft), and never moves
  the cursor or scroll position while typing;
- saving your take triggers re-tagging in the background automatically; the
  tag area shows a quiet "updating" state and then the new tags;
- failures show a short inline message with Retry; they never discard user
  input or clear an existing summary/tags;
- every await keeps the existing presentation fences (activity, Gateway
  identity, latest request).

Acceptance: iOS tests cover dismissal during generation, reconnect during
generation, double-tap, autosave with a conflicting remote revision, save
failure with retry, and re-tag after a take edit; a simulator run records
screenshots of each state. Device validation by the user after K9.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| K1 | Done | Typed enrichment and curation operations for agents, RPC and the agent tool | none | deepseek-worker, 2026-09-28 |
| K2 | Done | Clean evidence for summaries: extraction without site chrome, provider-date recovery | none | deepseek-worker, 2026-09-29 |
| K3 | Done | Tag vocabulary and tagging guidelines owned by Knowledge config | K1 | luna-worker, 2026-09-29 |
| K4 | Ready | Jev tagger with monthly budget and re-tag triggers | K1, K3 | — |
| K5 | Ready | DeepSeek enrichment model; summarize then tag at intake | K1, K2, K4 | — |
| K6 | Ready | Your take, verdicts and freshness policy; freshness- and scope-aware retrieval | K1 | — |
| K7 | Ready | iOS: Your take field, tags, verdict, scope editing, research / Moose's Corner filter | K1, K6 | — |
| K8 | Ready | Multi-collection Raindrop intake with collection-to-scope mapping | K1 | — |
| K9 | Ready | Maintainer runtime update and live capability check | K1–K8 | — |
| K10 | Ready | Seed: agent drafts the vocabulary from the 276 entries; user edits it | K9 | — |
| K11 | Ready | Seed: summarize and tag the existing library within budget | K10 | — |
| K12 | Ready | User fills Your take at leisure; agent applies verdicts, relations and re-tags | K11 | — |
| K13 | Ready | Ingest Moose's Corner as personal; decide Unsorted and Shopping with the user | K12 | — |
| K14 | Ready | Automations: ingest new saves; weekly vocabulary review session (user go-ahead required) | K13 | — |

## Task details

### K1 — Enrichment and curation operations

Owning files: `packages/gateway/src/knowledge/knowledge-contract.ts`,
`packages/gateway/src/knowledge/knowledge-store.ts`,
`packages/gateway/src/knowledge/knowledge-service.ts`,
`packages/gateway/src/transport/gateway-service.ts`,
`packages/gateway/src/workspace/tron-core-extension.ts`.

Typed operations, each with command ID, target source ID, expected revision and
producer provenance:

- set summary (with exact evidence revision, coverage full/sampled);
- set tags (vocabulary IDs only, after K3; with producer and inputs digest);
- set verdict (evergreen / dated / superseded / archive) and supersededBy;
- add or remove relations between entries;
- change scope (research ↔ personal) and admission.

Receipts, same-command/different-payload rejection, stale-revision conflicts,
exclusion/forget races failing closed. The agent `knowledge` tool gains these
actions. Meets the reliability bar for agent editing tools above, including
bounded batches with per-item outcomes. Summary generation and re-tagging are
owned background operations with a queryable state (running, done, failed) so
the app and agents can observe them without holding a request open. No arbitrary record replacement. Change events flow through the
existing coalesced `knowledge.changed`.

### K2 — Clean evidence

Owning files: `packages/gateway/src/knowledge/source-capture.ts`,
`packages/gateway/src/knowledge/connectors.ts`.

Fix the readable-text extractor so navigation, menus and footers do not consume
the evidence budget (main-content selection, not per-site hacks); mark poor
extraction as needs-evidence instead of summarizing it. Recover Raindrop
`created` as original save time from retained provider evidence; unknown
publication dates stay unknown. Carried from the replaced plan's E2.

### K3 — Tag vocabulary

A canonical vocabulary in Knowledge config: stable tag ID, unique label, one-line
definition, category, decay class (`ages`/`stable`), active/retired/merged state,
and free-text tagging guidelines. Agents may add, rename, redefine,
recategorize, merge and retire tags (decision: apply directly), or edit
guidelines, through typed, receipted edits fenced on the expected configuration
revision. Validation bounds count and lengths and rejects duplicate labels,
malformed IDs, dangling merge targets and cycles. The vocabulary has its own
edition revision, so unrelated configuration edits do not trigger Jev
re-tagging. A merge re-points matching selections in bounded, receipt-backed
source curation batches; retirements remain visible and are listed by a bounded
re-tag query. Source row labels and search use catalog heads without body reads.
The decay-class accessor is exported for K6; freshness remains K6's owner.

### K4 — Jev tagger

Owning files: `packages/gateway/src/knowledge/jev-assessment.ts`,
`packages/gateway/src/knowledge/jev-client.ts`.

One `noul` question per candidate tag, batched 16 per call; a category `choice`
pass first narrows candidates when the vocabulary is large. Inputs: title,
summary, bounded clean text, the user's take, verdict, tag definitions and
guidelines. Threshold and ties defined and tested. Monthly budget ($5) persisted
with reservations and settlement; the tagger stops cleanly when exhausted.
Re-tag triggers: new entry, summary change, Your take change, vocabulary or
guideline change (bulk, with a cost estimate first). Install the budget through
K1's `KnowledgeCurationGate`, which receives the batch operation: refuse only
operations that spend Jev budget, and reserve at Jev dispatch, not at
publication of an already-computed selection.

### K5 — Summaries at intake

A Knowledge enrichment model setting, set to `opencode-go/deepseek-v4.1-flash`,
separate from the observation model. Intake order: capture → clean evidence →
summary → Jev tags → admission. Failures leave the entry pending with a reason,
never a fabricated summary.

### K6 — Your take, verdicts, freshness, retrieval

Your take is one confirmed user note per source (one editable note, replaced by
revision, history kept). Freshness per entry = user verdict if present, else
the decay class of its tags applied to age since the original save date.
Retrieval (`knowledge` search/recall and the agent tool):

- personal-scope sources are excluded unless the request asks for personal
  scope explicitly;
- ranking uses relevance, then freshness; archived entries are excluded;
- each result carries save date, age, freshness, verdict, supersededBy and the
  user's take, so agents cite age and prefer the user's note over source text.

### K7 — iOS

Your take text field on Entry Detail; tags shown from the vocabulary; verdict,
scope and re-tag controls; the Generate / Regenerate summary action; the
Library scope filter labels personal as Moose's Corner. Meets the interaction
bar for Entry Detail above. Keep the current compact layouts and presentation
fences.

### K8 — Multi-collection intake

The Raindrop connection maps several collections to scopes (Resources →
research, Moose's Corner → personal). Personal entries use a lighter capture:
link, title, preview and any saved note; capture failure is acceptable because
the link is the source of truth.

### K9 — Runtime update

Agents prepare and validate; the user rebuilds the Gateway and installs the app.
Then verify the new operations and capabilities live.

### K10–K12 — Seed

K10: the agent reads the existing 276 entries and drafts categories, tags,
definitions, decay classes and guidelines; the user edits them in chat; the
agent stores the result. K11: summarize and tag all existing entries, reporting
estimated and actual Jev spend. K12: the user writes Your take entries in the
app and tells the agent when done; the agent derives verdicts and
supersededBy relations, updates guidelines if the takes reveal new rules, and
re-tags affected entries.

### K13–K14 — Moose's Corner and automations

K13 ingests Moose's Corner as personal and asks the user where Unsorted and
Shopping belong. K14 creates the intake automation and the weekly review
session only after the user confirms the schedule.

## Handoff log

### K1 · Done · 2026-09-28 · deepseek-worker

- Result: `knowledge.source.curate` (RPC, capability `knowledge-curation.v1`, agent
  tool `curate`) writes summaries, vocabulary-tag selections, verdicts, placement
  and relations onto an exact revision; summary generation became owned
  background work with a queryable job (`knowledge.curation.jobs`, tool
  `summarize`/`curationJob`). Free-form summary tags were replaced by the
  vocabulary selection so one taxonomy owns tagging.
- Evidence: `npx vitest run src/knowledge/` — 289 passed, 20 files. The
  acceptance case in `knowledge-curation.test.ts` drives the real agent tool
  through a 25-entry batch with an injected conflict, a replay, a budget stop and
  a restarted owner instance, and writes `knowledge-curation-outcome.json` under
  its temp root (`applied` 10 / 24 / 24 / 5, one `stale-revision` conflict, 20
  `skipped`). `src/transport/` passed on re-run (404); two log-rotation and
  drain-timing cases failed once under host load and passed on re-run.
- Changes: `feat(knowledge): add typed source curation to the store` (8a0e666e8);
  `feat(knowledge): run curation batches and summary jobs through the owner`
  (f30103e81); plus this plan/docs update.
- Tasks added: none.
- Kept on purpose: `knowledge.source.admission` (connector intake and explicit
  restore) stays separate from curation placement, because intake carries rubric
  and profile versions that a placement decision must not inherit. The
  assessment model seam is unchanged; K5 selects the enrichment model.
- Deviations: the store's `KnowledgeTagVocabulary` seam is a constructor seam
  rather than a config field, because K3 owns the config shape; an empty
  vocabulary refuses every tag write with `unknown-tag`. The curation gate is a
  service constructor seam (K4 installs the Jev budget). `SourceSummary.tags` was
  deleted rather than kept beside the vocabulary: the live corpus held zero
  stored summaries (checked read-only against the running Gateway, 438 sources),
  so the replacement needed no migration. An old iOS build cannot decode a
  record summarized after this change until K7 lands — no such record can exist
  until the Gateway is rebuilt at K9.
- For the next agent: K3 fills `KnowledgeTagVocabulary` from config and must
  record its revision; K4 tags through the `tags` curation operation and installs
  the gate; K5 wires the enrichment model; K6 extends `curationInputsDigest` with
  the user's take and must then re-tag; K7 adopts `tags`/`verdict` on iOS and
  drives `summarize` + `curationJob` instead of awaiting a summary call.

### K2 · Done · 2026-09-29 · deepseek-worker · `knowledge/k2-clean-evidence`

- Result: The save-time reconciliation and the readable-text extractor are done.
  `extractReadableText` (source-capture.ts) now reads the article rather than the
  page chrome, and `recoverProviderSaveTime` recovers Raindrop's original save
  time from the payload already retained at the exact revision. Both are exported
  for K5/K10; the connector's intake and sweep paths call them.
- Evidence: `npx vitest run src/knowledge` in `packages/gateway`: 21 files, 302
  tests passed. Focused owners: `source-readable-text.test.ts` (14 failure-mode
  tests, written before the implementation), `source-save-time.test.ts` (11),
  `source-capture.test.ts` and `connectors.test.ts` (including one end-to-end
  sweep that recovers the save time through the connector). Measured over 602
  unique HTML pages retained in the live Library with a read-only script: chrome
  phrases (Skip to content, Sign in, Notifications, Cookie, Pricing, …) fell from
  1017 to 37, median readable text 14,161 → 7,335 characters, and no page with
  more than 3,000 readable characters is marked partial (0 false positives).
  Page-quality split after the change: 326 complete, 5 chrome-heavy, 18 app
  shell, 11 title-only, 1 no text. The GitHub readme case was reproduced from a
  real saved GitHub page: `<article>` (README, 4,560 characters) is chosen over
  `<main>` (5,112 characters including repository chrome). Against a read-only
  copy of the live Library (no writes), the reconciliation recovers a save time
  for 273 of its 275 Raindrop sources, finds no evidence belonging to a different
  item, and reports 2 whose retained payload carries no usable `created`.
- Changes: `78042a73c` (extraction), `adfc5c70f` (save-time recovery),
  `packages/gateway/docs/knowledge.md` in the same commits.
- Tasks added: none.
- Kept on purpose: `mergeHydratedContent` and the linked-target failure wording
  are unchanged; the extractor keeps its output as single-space collapsed text
  (no new block-newline formatting) so stored text, evidence digests and rows keep
  their existing shape; a `confidence`-style score was not introduced, because the
  region rule answers the only question the pipeline asks (which text is the
  page's content).
- Deviations: (1) The recovery reads retained provider evidence through the store's
  object authorization, which fences pending sources from their own objects, so a
  freshly captured source cannot be reconciled that way. Instead of weakening that
  boundary (`knowledge-store.ts` is K1's file and the fence is deliberate), the
  caller may pass the bytes it has just retained, and they are accepted only when
  they hash to the representation the exact revision lists. (2) The sweep path
  still passes no live save time, because recovery from retained evidence now
  covers it; passing both would be two sources of truth. (3) Existing records keep
  their old readable text until they are re-captured or explicitly re-extracted;
  K2 did not rewrite the corpus. (4) `extractReadableText` is exported from
  `source-capture.ts` rather than moved to a new module, to keep one home for the
  source owner.
- For the next agent: K5/K10 should call `recoverProviderSaveTime` (and, if a
  pending source must be reconciled, pass the retained bytes as `evidence`); no
  agent-facing operation exists yet, because that contract is K1's. K11 should
  re-extract existing records rather than assume new text, since the 602 pages
  measured above still hold pre-K2 text. The 34 pages now reported as
  needing-evidence are the honest set to re-capture with a browser or the
  provider, not to summarize.

### K3 · Done · 2026-09-29 · luna-worker · `knowledge/k3-vocabulary`

- Result: Knowledge config owns a bounded controlled vocabulary and free-text
tagging guidelines, with typed receipt-backed add/rename/redefine/recategorize/
retire/merge/guidelines operations fenced on the config revision. Vocabulary
edition is separate from the broader config revision. Merge edits start one
atomic, bounded re-point batch; opaque cursors and batch receipts resume more
than 25 affected sources. Retired selections stay visible and the bounded
`knowledge.tags.retag-needed` query pages untagged/stale/retired sources for K4.
Source-row list and search carry catalog-head labels, category, decay class and
state without body reads. `knowledgeTagDecayClass` exposes the decay class for K6.
- Evidence: `npm run build` passed. `npx vitest run src/knowledge/` passed
23 files / 329 tests; `npx vitest run src/transport/` passed 43 files / 405
tests; `npx vitest run --config vitest.scale.config.ts src/knowledge/` passed
3 scale tests. `knowledge-tags.test.ts` covers stale/reused config receipts,
validation, merge cycles/retired targets, config changes during partial merge,
restart resume/replay, retired-tag refusal, re-tag queries, the agent/RPC paths,
label rename/search and zero body reads. `knowledge-tags.scale.test.ts` uses
12,600 heads / 440 source heads and measured row list 4.4 ms, tag search 15.6 ms,
and re-tag query 1.8 ms in its verbose run; body reads: 0.
- Changes: `f908e35cb` (`feat(knowledge): own controlled tag vocabulary`); this
handoff updates the plan with the implementation.
- Tasks added: none.
- Kept on purpose: the vocabulary has a revision distinct from
`KnowledgeConfig.revision`; ordinary observation/config edits must not cause a
paid Jev re-tag. Definitions/guidelines do not rewrite row heads, while edits to
label/category/decay/state reproject only the source heads in the catalog.
Existing selections stay as immutable prior revisions when a tag is retired;
K4 receives them through the bounded query. A merge cursor is fenced by the
current config revision, and each batch commits atomically with its replay
receipt.
- Deviations: merge configuration immediately re-points the first 25 sources,
then returns a cursor for explicit continuation; this bounds each RPC and makes
partial restart recovery receipted. An unrelated config edit between the merge
and its first batch is returned as a committed vocabulary edit plus a typed
resume conflict rather than misreported as a failed taxonomy mutation.
- For the next agent: K4 reads `config.tagVocabulary` (including `guidelines`),
uses the tag definitions/categories/decay classes, and asks
`knowledge.tags.retag-needed` for a vocabulary edition before tagging. K6 should
use `knowledgeTagDecayClass(config, tagId)` and keep freshness policy outside
K3. K7 can render `KnowledgeSourceRow.tags` without opening source bodies.

Drafted from the 2026-09-28 interview and approved by the user the same day,
with the reliability and interaction bars added at the user's request. K1 and
K2 claimed for parallel DeepSeek workers on isolated branches.
