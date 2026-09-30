# Knowledge concept consolidation

- **Started:** 2026-09-29
- **Status:** Active
- **Last updated:** 2026-09-29, approved
- **Goal:** Every user-visible Knowledge idea (archived, decided, budget, summary, note, freshness, order, replacement) has exactly one owner and one meaning, before the library is seeded.

## Goal and constraints

A concept audit on 2026-09-29 (`main` at `f8039f5db`) found about a dozen places
where Knowledge keeps two versions of one idea. The first visible failure: an
entry archived from Entry Detail ("The Stanford STORM Method…") disappeared from
every Library view, because Archive wrote a verdict while the Archived view,
Unarchive, reads and object access check the admission state.

Decisions the user made (2026-09-29), which override an agent's own judgment:

- **Archive is one state.** Admission `archived` is the only archive, used by
  the user, agents and intake alike. The verdict loses `archive` and becomes
  Evergreen, Dated or Superseded, plus Clear.
- **Intake never overrides a decision.** Raindrop intake decides scope and
  keep/archive only for entries nobody has decided yet. A user or agent
  decision always wins.
- **One Jev budget.** The monthly Jev cap ($5) covers intake assessment and
  tagging together.
- **One Knowledge model.** The setting now labelled "Summary model" becomes the
  Knowledge model, used for all Knowledge generation, and says so.
- **Your take is the one note.** When a take is empty, it is seeded from the
  Raindrop note; afterwards only Your take is shown. "Correct record" is
  hidden for sources.
- **Library order.** Save date by default; the filter sheet offers
  "Recent activity" as a second order.
- **Sweep is discovery-only.** Intake is the only path that saves and decides
  bookmarks.

What must not change: captured evidence stays immutable and the original link
stays the source of truth; every curation edit stays a revision with a receipt;
personal sources stay out of agent work retrieval unless asked; the rules in
`AGENTS.md` (no compatibility shims, user-initiated Gateway rebuilds, merges
only on the user's word) apply to every task.

## Context

- Owning plan: `docs/plans/2026-09-28-knowledge-agent-curation.md`. Its seeding
  tasks (K10, K11) would lock in today's order, re-tag and budget behavior, so
  on approval K10 gains a dependency on C1–C9 of this plan.
- Live state (2026-09-29): STORM is the only entry with verdict `archive`; no
  entry has admission `archived`. `KnowledgeConfig.enrichment` is unset, so the
  Knowledge model rename needs no data rewrite. 378 sources in total.
- Audit evidence (file:line at `f8039f5db`) is in the task details below. The
  audit read the main Gateway Knowledge owners and iOS Knowledge screens; tests,
  the X reader and conversation observation were only sampled.

## Plan rules

- A persisted value that a task removes from the contract must be gone from live
  data before the Gateway that rejects it is installed. The task names the exact
  records, the RPC that rewrites them, and the check that proves none remain.
  No read-time fallback for the old value.
- Each task changes the Gateway owner, the iOS projection, the agent tool text
  and the owning doc together (`packages/gateway/docs/knowledge.md`,
  `packages/ios-app/docs/knowledge-sources.md`).

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| C1 | Done | Archive is one state: Archive/Unarchive write admission; verdict gains Clear; Archived view, reads and restore agree | none | knowledge-consolidation session, 2026-09-29 |
| C2 | Blocked | Remove `archive` from the verdict type after live data holds none | C1, user Gateway update, STORM rewrite | — |
| C3 | Done | Intake never overrides a decided scope or admission; decided-but-unmoved bookmarks leave the queue | none | knowledge-consolidation session, 2026-09-29 |
| C4 | Done | Sweep is discovery-only; intake is the only capture-and-decide path | C3 | knowledge-consolidation session, 2026-09-29 |
| C5 | Done | One monthly Jev budget for intake assessment and tagging | none | knowledge-consolidation session, 2026-09-29 |
| C6 | Done | Agent tool: `list` hides personal sources by default; search/recall metadata comes from the read record | none | knowledge-consolidation session, 2026-09-29 |
| C7 | Done | iOS: curation conflict outcomes surface and reload; linked entries open regardless of admission | C1 | knowledge-consolidation session, 2026-09-29 |
| C8 | Needs scoping | Library order: save date by default, "Recent activity" option in the filter sheet | none | — |
| C9 | Needs scoping | One re-tag predicate; enrichment only for retained entries; verdict no longer a tag input | C1 | — |
| C10 | Needs scoping | Your take is the one note: seed from Raindrop note; hide Saved notes and Correct record for sources | C3 | — |
| C11 | Done | Rename Summary model to Knowledge model; own input/output limits | none | knowledge-consolidation session, 2026-09-29 |
| C12 | Needs scoping | One summary: the intake assessment keeps only its decision fields | C5 | — |
| C13 | Needs scoping | One freshness vocabulary; verdict reported beside age, not folded into it | C2 | — |
| C14 | Needs scoping | Supersession stored once; forget scrubs it | C2 | — |
| C15 | Ready | Naming and dead code: Saved/Pending/scope labels, duplicate digest, double save-time source, dead iOS predicates | C1–C14 | — |
| C16 | Needs scoping | Audit live Knowledge data for sources left pending by historical connector sweeps and determine safe intake recovery | C4, user Gateway access | — |
| C17 | Needs scoping | Superseded by C18–C23 (user decision 2026-09-29): X gets connector primitives and the ingestion routine, not its own intake pipeline | C3, C4, C5 | — |
| C18 | Done | Decision authority in the store: connector/system writes never override a user or agent admission or scope | none | knowledge-consolidation session, 2026-09-29 |
| C19 | Done | Ingest primitive: save one queued provider item with identity, save date, note, collection and payload, undecided and idempotent | C18 | knowledge-consolidation session, 2026-09-29 |
| C20 | Done | Connector primitives as agent actions: discover, read queue, acknowledge/skip, Raindrop move under write permission | C19 | knowledge-consolidation session, 2026-09-29 |
| C21 | Done | Assessment primitive: assess a source with Jev (one budget) or the Knowledge model; returns a recommendation, decides nothing | C18 | knowledge-consolidation session, 2026-09-29 |
| C22 | Done | Ingestion routine as an editable agent skill, plus owning docs | C19, C20, C21 | knowledge-consolidation session, 2026-09-29 |
| C23 | Blocked | Dry-run parity with Raindrop intake on live data, then delete the intake pipeline and its batch machinery | C22, user Gateway update | — |
| C24 | Done | Migrate iOS manual source assessment from `knowledge.source.triage` to `knowledge.source.assess` with `assessor: model` | C21 | knowledge-consolidation session, 2026-09-29 |
| C25 | Needs scoping | Expose Jev admission choice, confidence, usefulness score and coverage so the archive threshold can be owned by the editable routine, not the assessment adapter | C21 | — |

## Task details

### C1 — Archive is one state

Evidence: verdict `archive` hidden by `pageFilter` (`packages/gateway/src/knowledge/knowledge-store.ts`
~1270) while `recordArchived` (~868), `read` (~1215), object reads (~1968), the
agent `restoreSource` (`packages/gateway/src/knowledge/knowledge-service.ts` ~886)
and the iOS Archived view check admission only. The Entry Detail Archive row
calls `setVerdict(.archive)`; the Verdict menu also lists Archive.

- Archive/Unarchive in Entry Detail write admission through `knowledge.source.admission`.
- The Verdict menu offers Evergreen, Dated, Superseded and Clear. Add a
  verdict clear to curation (`knowledge-curation.ts`, store `curateSource`).
- The `pageFilter` verdict clause goes; `pageFilter` and `recordArchived` are one predicate.
- Acceptance (E2E through the UI-test fixture and the Gateway store): archive
  from Entry Detail → the entry appears under Archived with Unarchive; Unarchive
  returns it to Saved; an agent `read` without `includeArchived` is refused.

### C2 — Remove the archive verdict

After the user installs a Gateway with C1: clear STORM's verdict and set its
admission to `archived` via RPC, prove zero records carry verdict `archive`,
then delete the value from the contract, validator, tool schema, catalog and
iOS enum.

### C3 — Intake never overrides a decision

Evidence: `packages/gateway/src/knowledge/connectors.ts` ~639 re-places scope
whenever it differs from the collection mapping; ~690 re-writes admission from
the Jev recommendation; ~701 `continue`s without the done write, so retained but
unmoved bookmarks are re-processed every run.

- An entry is decided when its admission or scope has a user or agent producer,
  or admission is not intake-pending. Intake leaves decided entries untouched.
- Decided or unmoved bookmarks get the done write; the outcome counter that
  mixes "retained" and "pending" is split.
- Failure-mode tests: restore a Jev-archived entry, re-run intake → stays
  retained; move an entry to Personal, re-run → stays Personal.

### C4 — Sweep is discovery-only

Evidence: the connector `run` path (`connectors.ts` ~820–875) captured sources
that defaulted to pending (`packages/gateway/src/knowledge/source-capture.ts`
~804), never admitted them, and marked them captured so intake skipped them.
Make `run` discovery-only; it only discovers provider identities into the
connector queue. Intake is the sole path that captures and decides bookmarks.
Historical sources left pending by previous sweep behavior require a separate
live-data audit (C16); this task must not contact the live Gateway.

### C5 — One Jev budget

Evidence: tagging reserves against the `knowledge.jev` monthly ledger
(`packages/gateway/src/knowledge/knowledge-tagger.ts` ~106–151); intake reserves
against Raindrop batch approval (`connectors.ts` ~466–491). Move the ledger to
one Knowledge-owned Jev budget used by both; batch approvals become per-run caps
within it. Turning off paid access stops both.

### C6 — Agent tool privacy and metadata

`list` gets the same personal-source default as search and recall, enforced in
`pageFilter`. Search/recall build save date, age, verdict and take from the
record they already read instead of a second filtered row query that drops
archived or pending results (`knowledge-service.ts` ~799, ~811).

### C7 — iOS conflict and linked entries

`setVerdict`, `setScope` and `setAdmission` return silently on a per-item
`conflict` outcome, leaving the spinner up
(`packages/ios-app/Sources/UI/Automations/KnowledgeDashboardView.swift`). Treat
any outcome other than applied/unchanged as an error and reload from
`currentRevision`. "Replaced by" opens with the linked row's admission.

### C8 — Library order (needs scoping)

Today sources sort by `updatedAt`, so every take, verdict or background tag
moves an entry to the top. Default order becomes the age anchor
(`sourceSavedAt ?? capturedAt`); "Recent activity" keeps `updatedAt`. Scoping:
the catalog head carries one `sortAt` and cursors encode it, so a second order
needs a second indexed key and a cursor that names its order. Measure the
row-page cost with the existing scale tests.

### C9 — Re-tag and enrichment eligibility (needs scoping)

Rows project `tagsStale` from the inputs digest only; the re-tag queue also
counts vocabulary changes and retired tags. Verdict is a tag input, so a verdict
change queues a paid re-tag. Summaries and tagging run on pending and archived
entries. Decide: one "needs re-tag" reason projected on rows; eligibility
"admission retained"; whether verdict stays a tag input.

### C10 — Your take is the one note (needs scoping)

`SourceTake` is user-owned (`producer.actor: "user"`, `confirmed: true`), so a
take seeded from the Raindrop note needs a decision on its producer and whether
it counts as confirmed. Scoping also covers backfilling existing entries' notes,
removing the Saved notes section for connector notes, and hiding Correct record
for sources (it also fails today on any curated source, because the iOS models
drop the `producer` fields the Gateway validator requires).

### C11 — Knowledge model

`KnowledgeConfig.enrichment.model` already drives summaries, triage, synthesis,
reflection and manual-capture assessment (`packages/gateway/src/gateway-main.ts`
~376). Rename the setting, field, tool text and iOS label to Knowledge model
(the live value is unset, so no data rewrite). Give it its own input/output
limits instead of borrowing the observation limits.

### C12 — One summary (needs scoping)

`SourceAssessment.summary` duplicates `content.summary` and is never shown. The
assessment keeps its decision fields (recommendation, confidence,
classification, versions, usage). Scoping: 314 records carry assessments, so
removal follows the plan rule on persisted values; also decide whether manual
triage stays on the Knowledge model or uses Jev.

### C13 — Freshness vocabulary (needs scoping)

Rows use fresh/aging/stale, assessments and notes use current/aging/stale, tags
use stable vs "does-not-age", and superseded forces stale. Pick one vocabulary;
report the verdict beside age.

### C14 — Supersession once (needs scoping)

It is stored as `verdict.supersededBy` and as a `supersedes` relation; forget
scrubs relations but not the verdict. Pick one owner and make forget scrub it.

### C15 — Naming and dead code

"Saved" (four meanings), "Pending" (three), connector `scope` (a collection or
user ID); duplicate tag-input digest in the tagger; intake passes both live
save time and recovered save time; unreachable iOS `.sources` branch in
`visibleRecords` and test-only helpers.

### C17 — X intake (needs scoping)

Since C4 the X connector sweep only discovers bookmarks, and only Raindrop has
an intake, so discovered X bookmarks are never captured while discovery still
spends paid X API attempts. The user chose (2026-09-29) to add an X intake
rather than remove the sweep. Scoping: whether X discovery keeps its own paid
attempt budget, how X items map to research/personal, and reuse of the Raindrop
intake decision path rather than a second one.

### C18–C23 — Ingestion as primitives plus an agent routine

User decision (2026-09-29): connectors are the only hardcoded part. Everything
after "the item is in Tron" is an agent routine that agents can edit, run by a
scheduled automation once the user approves one (K14 of
`docs/plans/2026-09-28-knowledge-agent-curation.md`).

Layers:

- **Connector (hardcoded, per provider):** authenticated discovery into the
  connector queue, a bounded queue read, acknowledge/skip, and provider writes
  (Raindrop move) gated by the connection's write permission. No admission,
  scope or assessment decisions.
- **Ingest (hardcoded, provider-neutral):** one primitive saves one queued item
  as a source with its provider identity, save date, provider note, collection
  and provider payload, runs save-time recovery and the unsafe-link check, and
  leaves admission pending. Idempotent by provider identity; re-ingesting never
  changes a decided admission or scope.
- **Assessment (hardcoded primitive):** assess a source with Jev (the single
  monthly ledger from C5) or the Knowledge model and return a recommendation.
  It records the assessment but never writes admission.
- **Routine (not hardcoded):** a user skill (`tron-knowledge-ingest`, beside
  `tron-x` and `tron-raindrop` in the Tron agent skills directory) that says
  which collections map to which scope, when to assess, how to decide, when to
  move in Raindrop, and how to report. Agents edit it; it is runtime
  configuration, not repository source.

Invariants stay with the Knowledge store, not the routine: connector/system
writes never override a user or agent decision (C18); one Jev ledger; personal
sources stay out of work retrieval; provider writes need write permission;
every write is a revision with a receipt.

Until C23, `knowledge.raindrop.intake` stays as it is so there is no gap; C23
deletes it only after a dry-run of the routine matches it on live data.

## Handoff log

### C1, C3–C7, C11 · Claimed · 2026-09-29 · knowledge-consolidation session

- Result: one session claims the Ready pre-seeding tasks together and does them
  in order on branch `knowledge/concept-consolidation`, because they share
  `knowledge-store.ts`, `connectors.ts` and the Entry Detail view and cannot run
  as parallel writers. Each task still ships as its own commit with its row.
- Deviations: batch claim instead of one task at a time, for the reason above.

### C3 · Done · 2026-09-29 · luna-worker

- Result: intake now preserves user/agent admission and scope decisions, persists producer ownership for new decisions, completes decided queue identities without treating no-move outcomes as pending, and splits retained/pending counts.
- Evidence: `cd packages/gateway && npm run build` (passed); `npx vitest run src/knowledge/connectors.test.ts src/knowledge/knowledge-store.test.ts` (78 passed); `python3 scripts/check-documentation-policy.py` (passed); `scripts/personal-info-guard.sh` (passed).
- Changes: this commit
- Tasks added: none
- Kept on purpose: legacy admissions without producer metadata are treated as prior decisions; intake never guesses their owner or overwrites them.
- Deviations: none.
- For the next agent: C4 can make the connector sweep discovery-only; intake's done receipt is now the boundary that removes completed identities from its queue.

### C4 · Done · 2026-09-29 · luna-worker

- Result: connector runs now only discover bookmarks into the connector queue; capture, admission, provider movement, and post-capture enrichment are absent from the sweep path. The knowledge tool explains that discovery does not capture or decide bookmarks and points processing to intake.
- Evidence: `cd packages/gateway && npm run build` (passed); `npx vitest run src/knowledge/connectors.test.ts src/knowledge/knowledge-service.test.ts` (69 passed); `python3 scripts/check-documentation-policy.py` (passed); `scripts/personal-info-guard.sh` (passed).
- Changes: this commit
- Tasks added: C16 — audit live Knowledge data for sources left pending by historical connector sweeps; requires user Gateway access and was not performed here.
- Kept on purpose: connector identity and provider metadata remain durably queued and deduplicated; intake continues owning source capture and decisions.
- Deviations: none.
- For the next agent: C16 must audit pending records without invoking Gateway mutations until an explicitly approved recovery route is known.

### C5 · Done · 2026-09-29 · luna-worker

- Result: Intake assessment and tagging now reserve and settle against the same monthly Jev ledger and ConnectionOwner paid policy. Raindrop approvals continue to limit an individual cohort but cannot authorize Jev dispatch past the shared cap; missing assessment usage conservatively settles at the reservation ceiling.
- Evidence: `cd packages/gateway && npm run build` (passed); `npx vitest run src/knowledge/connectors.test.ts src/knowledge/knowledge-tagger.test.ts src/knowledge/raindrop-intake-safety.test.ts src/knowledge/raindrop-intake-multipage.test.ts src/knowledge/knowledge-intake-enrichment.test.ts` (78 passed); `python3 scripts/check-documentation-policy.py` (passed); `scripts/personal-info-guard.sh` (passed).
- Changes: this commit
- Tasks added: none.
- Kept on purpose: uncertain Jev dispatches keep their shared reservation and block further paid Jev work until explicit reconciliation; Raindrop's per-cohort item/cent bounds remain in addition to, never instead of, the Knowledge monthly cap.
- Deviations: the multipage intake fixture's expected moved count is corrected to its actual eight eligible items after the resumed run reports one item already processed and one incomplete; the enrichment rerun expects zero new captures for its completed cohort.
- For the next agent: the running Gateway remains untouched; install/rebuild remains a maintainer action after the planned changes.

### C6 · Done · 2026-09-29 · luna-worker

- Result: Agent list excludes personal sources unless scope is explicit, enforced by the store filter. Search/recall derive source-row metadata from the returned record so archived and pending matches retain save date, age, freshness, verdict, and take.
- Evidence: `cd packages/gateway && npm run build` (passed); `npx vitest run src/knowledge/knowledge-take-freshness.test.ts src/knowledge/knowledge-service.test.ts` (32 passed); `python3 scripts/check-documentation-policy.py` (passed); `scripts/personal-info-guard.sh` (passed).
- Changes: this commit
- Tasks added: none
- Kept on purpose: personal notes and observations remain available; explicit scope personal permits source access.
- Deviations: updated one pre-existing freshness test to archive via admission rather than the superseded archive verdict path.
- For the next agent: C7 remains independent; Gateway runtime changes still require a maintainer update and were not applied here.

### C7 · Done · 2026-09-29 · luna-worker

- Result: linked replacement reads now carry the exact row's archived/pending authority. The existing per-item curation outcome decoder turns every status except applied/unchanged into an error; the Entry Detail error path releases saving and reloads conflict `currentRevision` with archived and pending access.
- Evidence: `scripts/tron ios generate` (passed); `TRON_IOS_TEST_TIER=ui-validation scripts/tron-ios-test build` (passed); `TRON_IOS_TEST_TIER=ui-validation scripts/tron-ios-test run --only-testing TronMobileUITests/TronKnowledgeDetailUITests/testCurationConflictShowsErrorReloadsAndReenablesVerdictControl` (1 passed); `python3 scripts/check-documentation-policy.py` (passed, 48 authored files); `scripts/personal-info-guard.sh` (passed).
- Changes: this commit
- Tasks added: none
- Kept on purpose: per-item conflict/error translation remains in the native RPC client, preserving each Gateway outcome's reason and current revision rather than moving curation outcome policy into the view.
- Deviations: the first UI run selected stale products and executed no tests; after rebuilding the UI-validation tier, the focused test passed. One intermediate test attempt corrected an accessibility label mismatch before passing.
- For the next agent: C8 remains ready for scoping; no Gateway runtime transition was performed.

### C11 · Done · 2026-09-29 · luna-worker

- Result: renamed the optional summary-model setting to `knowledgeModel`, with independent input/output character limits shared by summaries, triage, synthesis, reflection, and manual-capture assessment. The iOS setting and agent action now use Knowledge model terminology; unset summary generation refuses without falling back to observation.
- Evidence: read-only inspection of the persisted Knowledge catalog config found no `enrichment` key; `cd packages/gateway && npm run build` (passed); `npx vitest run src/knowledge/knowledge-service.test.ts src/knowledge/knowledge-curation.test.ts src/knowledge/knowledge-summary-scheduling.test.ts src/knowledge/knowledge-intake-enrichment.test.ts` (44 passed); `scripts/tron ios generate` (passed); `scripts/tron-ios-test build` (passed); `scripts/tron-ios-test run --only-testing TronMobileTests/KnowledgeModelsTests` (34 passed); `python3 scripts/check-documentation-policy.py` (passed, 48 authored files); `scripts/personal-info-guard.sh` (passed).
- Changes: this commit
- Tasks added: none.
- Kept on purpose: the configured limits default to 48,000 input and 8,000 output characters when the tool sets a model; iOS preserves these values through whole-config round trips, while clear removes the model configuration.
- Deviations: none.
- For the next agent: C8 remains ready for scoping; the persisted catalog configuration was inspected read-only and was not changed.

### C1 · Done · 2026-09-29 · luna-worker

- Result: archive is admission-only in storage filtering, curation, and Entry Detail; legacy archive verdicts remain readable but cannot be written.
- Evidence: `cd packages/gateway && npm run build` (passed); `npx vitest run src/knowledge/knowledge-store.test.ts` (29 passed); `TRON_IOS_TEST_TIER=ui-validation scripts/tron-ios-test build` (passed); `TRON_IOS_TEST_TIER=ui-validation scripts/tron-ios-test run --only-testing TronMobileUITests/TronKnowledgeDetailUITests/testArchiveAndUnarchiveRoundTripUsesAdmissionLabels` (1 passed).
- Changes: this commit
- Tasks added: none
- Kept on purpose: `archive` stays in Gateway and iOS verdict decoding for persisted legacy data; curation explicitly refuses new archive verdict writes.
- Deviations: an initial default-tier UI test invocation was rejected because the suite belongs to UIValidation; reran with the UI-validation tier. The first iOS build found and corrected an out-of-scope local variable reference before passing.
- For the next agent: C2 may remove the verdict value only after the live record is cleared and archived by admission; do not infer live-data cleanup from these fixture tests.

### C3/C5 review fixes · Done · 2026-09-29 · luna-worker

- Result: intake now processes scope-only decisions without changing their scope, decides pending admission normally, and only short-circuits for a decided admission. Jev intake reserves before dispatch and marks the shared monthly attempt dispatched at the transport boundary; cancellation before dispatch releases it. The agent curation input no longer accepts `archive`; persisted decoding remains unchanged for C2.
- Evidence: the C3 scope-only test failed against the old admission-or-scope short-circuit (`pending` stayed pending); the Jev cancellation test failed with dispatch marking in `beforeDispatch` (the shared reservation remained held). Revert proofs: restoring the old admission-or-scope guard failed the scope-only test; deleting the admission guard failed the rediscovery test (agent-retained became archived); restoring the old unconditional mapped-scope write failed the scope-only test (Personal became Research). Moving `markDispatch` back to `beforeDispatch`, or omitting pre-dispatch release, each failed the cancellation regression (`reservedCents` increased by the reserved attempt). Final validation: `npm run build` passed; `npx vitest run src/knowledge` passed (26 files, 375 tests); documentation policy passed (48 authored files); personal-info guard passed.
- Changes: this commit
- Tasks added: none.
- Kept on purpose: legacy stored `archive` values remain readable pending C2's live-data and update gate.
- Deviations: none.
- For the next agent: C2 remains gated on explicit live-data cleanup and a maintainer Gateway update; no Gateway lifecycle action was performed.

### C17 added · 2026-09-29 · knowledge-consolidation session

- Result: branch review found X sweeps spend paid attempts after C4 with no
  intake to consume them; the user chose to add an X intake. Added C17.
- Evidence: full Knowledge Gateway suite 375/375 on `7b6b7afe1`; full Gateway
  suite 2306/2308, the two failures (`recent-model-usage.integration`,
  `session-search-stall`) pass in isolation on both this branch and `main`.
- Changes: this commit.

### C18–C22 · Claimed · 2026-09-29 · knowledge-consolidation session

- Result: the user chose to replace per-provider intake pipelines with
  connector primitives and an editable agent routine now, instead of building
  an X intake first. C17 is superseded; C18–C23 added. One session does C18–C22
  in order on branch `knowledge/ingestion-primitives` (they share
  `connectors.ts`, `knowledge-store.ts` and `knowledge-service.ts`).

### C18 · Done · 2026-09-29 · luna-worker

- Result: the Knowledge store now returns a typed `decision-authority` refusal
  when connector/system admission or scope writes would replace a user/agent
  decision. Intake uses those store refusals instead of duplicating admission
  ownership logic.
- Evidence: `cd packages/gateway && npm run build` passed; final `npx vitest run src/knowledge` passed (26 files, 376 tests); documentation policy passed (48 authored files); personal-info guard passed. An earlier suite invocation hit a transient `ENOTEMPTY` test-temp cleanup error; the isolated case and subsequent full suite passed. Revert proof: removing the `setSourceAdmission` store guard made the added regression fail because the connector overwrite resolved and archived the source; restored code passes.
- Changes: this commit
- Tasks added: none
- Kept on purpose: agents can replace user/agent decisions; connector decisions
  remain permitted when the prior admission/scope is undecided; legacy
  non-pending admissions without connector producer metadata stay protected.
- Deviations: none.
- For the next agent: C19 can build ingest primitives on the store-owned
  decision boundary; C23's live dry-run remains a maintainer/Gateway gate.

### C19 · Done · 2026-09-29 · luna-worker

- Result: Added provider-neutral `knowledge.source.ingest` and agent `ingestItem`; ingestion accepts an explicit scope, stores queued Raindrop/X evidence as a pending source, recovers Raindrop save time solely from retained provider payload, and leaves queue acknowledgment, assessment, and decisions to their owning tasks. Legacy Raindrop intake now uses the same capture path.
- Evidence: `npm run build` passed; full `npx vitest run src/knowledge` passed (27 files, 377 tests); documentation policy and personal-info guard passed. Revert proof: making the ingest RPC reject at its boundary caused `source-ingest.test.ts` to fail with the explicit unsupported error; restoring the implementation made it pass.
- Changes: this commit
- Tasks added: none.
- Kept on purpose: `knowledge.raindrop.intake` remains until C23 and continues its current assessment/admission/move workflow; ingestion never acknowledges queued work.
- Deviations: none.
- For the next agent: C20 owns queue acknowledgment/skip and other connector primitives; C23 remains gated on user-approved live dry-run and Gateway update.

### C20 · Done · 2026-09-29 · luna-worker

- Result: Replaced connector sweep/run with connection-scoped discover, queue, acknowledgment, and Raindrop move primitives. Queue pages expose bounded identity/metadata and source admission/scope only, never provider payload. Processed/skipped acknowledgments leave the queue, persist a bounded reasoned processed record, and suppress rediscovery. Legacy Raindrop intake now acknowledges through the primitive.
- Evidence: `npm run build` passed; `npx vitest run src/knowledge` passed (27 files, 378 tests); documentation policy and personal-info guard passed. Revert proof: temporarily removing the `knowledge.connector.discover` dispatch made `connectors.test.ts` fail at discover in the discover→queue→ingest→ack case; restoring it and rerunning the Knowledge suite passed. A preceding full-suite run hit one transient 15-second enrichment-test timeout; its isolated rerun and final full suite passed.
- Changes: this commit
- Tasks added: none.
- Kept on purpose: `knowledge.raindrop.intake` remains until C23 and uses the shared discovery, ingestion, move, and acknowledgment paths; X retains the paid attempt budget and automation recurrence gate.
- Deviations: none.
- For the next agent: C21 owns the assessment primitive; C23 still requires the user-approved live dry-run and Gateway update before deleting legacy intake.

### C21 · Done · 2026-09-29 · luna-worker

- Result: Added `knowledge.source.assess` and agent `assessSource` for one exact source revision, selecting either the configured Knowledge model or Jev. Both persist only a revisioned assessment and return recommendation, confidence, and classification without changing admission. Jev uses persisted interests and reserves/marks/settles against C5's shared monthly ledger.
- Evidence: `PATH=/opt/homebrew/bin:$PATH npm run build` passed; final `PATH=/opt/homebrew/bin:$PATH npx vitest run src/knowledge` passed (28 files, 382 tests); documentation policy passed (48 authored files); personal-info guard passed. One earlier full-suite run hit transient `ENOTEMPTY` cleanup in the existing intake-enrichment fixture; its isolated rerun and the subsequent full-suite rerun passed. Revert proof: removing the assessment RPC dispatch made all four new source-assessment regressions fail; restoring it made them pass, including monthly settlement, pre-dispatch budget refusal, paid-access refusal, and model configured/unset behavior.
- Changes: this commit
- Tasks added: C24, to migrate the existing iOS manual-assessment caller and owning docs to the new RPC; the user explicitly directed that iOS work be planned separately.
- Kept on purpose: legacy `knowledge.raindrop.intake` remains through C23 and continues its bounded batch approval and admission/move workflow; the standalone primitive does not consume that cohort authority and never writes admission.
- Deviations: the Gateway RPC replaces `knowledge.source.triage`; the existing iOS caller remains on the old operation until C24 and therefore requires that task before use with this Gateway contract.
- For the next agent: C22 can build the editable ingestion routine against discover, queue, ingest, acknowledge, move, and single-source assessment; C24 migrates iOS; no Gateway lifecycle action was performed.

### C22 · Done · 2026-09-29 · luna-worker

- Result: Wrote the editable `tron-knowledge-ingest` routine at `/Users/<USER>/.tron/workspace/files/knowledge-ingest/SKILL.md` and documented the connector/ingest/assessment/routine layering and invariants in `packages/gateway/docs/knowledge.md`.
- Evidence: `npm run build` passed; `npx vitest run src/knowledge` passed (28 files, 382 tests); `python3 scripts/check-documentation-policy.py` passed (48 authored files); `scripts/personal-info-guard.sh` passed; `git diff --check` passed. Revert proof: this task changes only the editable Markdown routine and owning documentation, not executable behavior; no automated behavior test owns routine prose, and a source-text assertion would violate the testing policy, so no tests were added. The existing Knowledge suite validates the primitives used by the routine, not its natural-language workflow.
- Changes: this commit
- Tasks added: C25 — expose Jev admission choice, confidence, usefulness score and coverage so the archive threshold can be owned by the editable routine rather than the assessment adapter (depends on C21).
- Kept on purpose: `knowledge.raindrop.intake` remains until C23 after live dry-run parity and a user Gateway update; the routine introduces no parallel queue, scheduler, or run journal.
- Deviations: dry-run may perform bounded free Raindrop discovery/queue bookkeeping but does not ingest, assess, curate, acknowledge, move, or spend; it must not discover X because X discovery may be paid. Per supervisor direction, the routine applies the assessment's returned recommendation without adding a numeric confidence threshold; C25 captures the raw-signal ownership gap.
- For the next agent: C23 remains gated on user-approved live dry-run parity and a user Gateway update before deleting the legacy intake pipeline; C24 separately migrates the iOS manual-assessment caller. No Gateway lifecycle action or live Gateway access was performed.

### C18–C22 review fixes · Done · 2026-09-29 · luna-worker

- Result: Legacy intake now acknowledges user/agent-decided admissions before assessment, including agent-archived personal items; Jev refuses personal sources before ledger reservation; source capture guards use an explicit connector writer identity; Jev response usage settles across record-write failures, and committed source-assessment receipts replay before a paid reservation. The editable routine now uses X destination scope from its stated setting and documents exact connector action parameters.
- Evidence: each new Gateway failure-mode test failed with its corresponding guard/settlement/replay behavior reverted; final `npm run build` passed and `npx vitest run src/knowledge` passed (28 files, 386 tests); documentation policy and personal-info guard passed.
- Changes: this commit.
- Tasks added: none.
- Kept on purpose: when Jev usage settles but no source-write receipt exists, a retry with the same command ID returns a typed conflict directing a new command ID; no parallel persistent assessment receipt/schema was added. If the source write committed before a lost response, its receipt is returned before the paid ledger is touched.
- Deviations: none.
- For the next agent: C24 still migrates iOS manual assessment to the Gateway primitive; C23 remains gated on user-approved live dry-run parity and a user Gateway update. No live Gateway access or lifecycle action was performed.

### C24 · Done · 2026-09-29 · luna-worker

- Result: iOS manual Entry Detail assessment now calls `knowledge.source.assess` with `assessor: "model"`, decodes the shared source/assessment response, updates the presented source and reports its recommendation without changing admission. iOS architecture and Knowledge source docs now name the current primitive.
- Evidence: `scripts/tron ios generate` passed; `scripts/tron-ios-test build` passed; `scripts/tron-ios-test run --only-testing TronMobileTests/KnowledgeModelsTests` passed (35 tests); `TRON_IOS_TEST_TIER=ui-validation scripts/tron-ios-test build` passed; `TRON_IOS_TEST_TIER=ui-validation scripts/tron-ios-test run --only-testing TronMobileUITests/TronKnowledgeDetailUITests` passed (7 tests); documentation policy and personal-info guard passed.
- Changes: this commit.
- Tasks added: none.
- Kept on purpose: the manual assessment uses the Knowledge model, matching its previous intended configuration and keeping paid Jev out of iOS; the result remains a recommendation, not an admission decision.
- Deviations: none.
- For the next agent: C23 remains gated on user-approved live dry-run parity and a user Gateway update. No live Gateway access or lifecycle action was performed.

### C20 correction · Done · 2026-09-29 · knowledge-consolidation session

- Corrects: the C20 entry. Its new `knowledge.connector.queue` read was placed
  inside the Gateway service's mutating Knowledge case group, so every app
  Knowledge edit (config, take, curate, admission, notes, correction, forget,
  exclusion and more) bypassed the Gateway command receipt and restart drain.
- Evidence: `src/transport/gateway-service-transcript.test.ts` "resolves
  knowledge receipt references…" passed on `main` and failed from C20 onward
  (bisected across the branch commits). New regression "routes Knowledge edits
  through the Gateway command receipt" fails with the misplaced label and passes
  with the fix. Full Gateway suite 2319/2320; the one failure,
  `session-search-stall`, is the load-sensitive timing test that also passes in
  isolation on `main`.
- Changes: this commit.
- For the next agent: the Gateway service `invoke` switch is the only authority
  for which Knowledge methods get receipts; new reads go in the read group.
  Branch workers ran only `src/knowledge`; run the full Gateway suite before
  handing off a change that touches `gateway-service.ts`.

### C18–C24 final review fixes · Done · 2026-09-29 · knowledge-consolidation session

- Result: fixed the follow-up review's findings. Jev assessment checks the
  source's current head (scope and revision) inside `beforeDispatch`, after the
  committed-replay lookup and before any reservation, so an older research
  revision of a source since moved to personal can no longer reach Jev. Budget
  reservation conflicts name their real cause (open reservation, paid and
  settled, or released before dispatch) instead of always claiming "paid and
  settled". Legacy intake routes by the source's own scope, so an agent-placed
  personal source is never assessed. Decided items are acknowledged as
  `skipped`. The restart drain admits the Knowledge reads `tags.retag-needed`,
  `connector.status`, `connector.queue` and `raindrop.read`.
- Evidence: new regressions "refuses Jev for an older research revision…",
  "names an open unrelated dispatch…" and the personal-path assertion
  (`assessed === 0`) each fail without their fix and pass with it; the
  agent-archived personal test fails on the `skipped` disposition without the
  fix. Knowledge + transport suites green; full Gateway suite 2321/2322, the
  one failure (`session-search-stall`) is the load-sensitive timing test that
  passes in isolation on `main`.
- Changes: this commit.
- Kept on purpose: re-acknowledging an item keeps its first recorded
  disposition (the connector's processed history is per identity), so a
  rediscovered item first processed normally stays `processed`.
- For the next agent: C23 (live dry-run parity, then deleting
  `knowledge.raindrop.intake`) needs the user's Gateway update. Install the
  routine skill from `~/.tron/workspace/files/knowledge-ingest/SKILL.md` into
  the Tron agent skills directory as part of C23, not before.
