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
| C3 | Claimed | Intake never overrides a decided scope or admission; decided-but-unmoved bookmarks leave the queue | none | knowledge-consolidation session, 2026-09-29 |
| C4 | Claimed | Sweep is discovery-only; intake is the only capture-and-decide path | C3 | knowledge-consolidation session, 2026-09-29 |
| C5 | Claimed | One monthly Jev budget for intake assessment and tagging | none | knowledge-consolidation session, 2026-09-29 |
| C6 | Claimed | Agent tool: `list` hides personal sources by default; search/recall metadata comes from the read record | none | knowledge-consolidation session, 2026-09-29 |
| C7 | Claimed | iOS: curation conflict outcomes surface and reload; linked entries open regardless of admission | C1 | knowledge-consolidation session, 2026-09-29 |
| C8 | Needs scoping | Library order: save date by default, "Recent activity" option in the filter sheet | none | — |
| C9 | Needs scoping | One re-tag predicate; enrichment only for retained entries; verdict no longer a tag input | C1 | — |
| C10 | Needs scoping | Your take is the one note: seed from Raindrop note; hide Saved notes and Correct record for sources | C3 | — |
| C11 | Claimed | Rename Summary model to Knowledge model; own input/output limits | none | knowledge-consolidation session, 2026-09-29 |
| C12 | Needs scoping | One summary: the intake assessment keeps only its decision fields | C5 | — |
| C13 | Needs scoping | One freshness vocabulary; verdict reported beside age, not folded into it | C2 | — |
| C14 | Needs scoping | Supersession stored once; forget scrubs it | C2 | — |
| C15 | Ready | Naming and dead code: Saved/Pending/scope labels, duplicate digest, double save-time source, dead iOS predicates | C1–C14 | — |

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

Evidence: the connector `run` path (`connectors.ts` ~820–858) captures sources
that default to pending (`packages/gateway/src/knowledge/source-capture.ts` ~804),
never admits them, and marks them captured so intake skips them. Make `run`
discovery-only; audit live data for sources stuck pending by past sweeps and
route them through intake.

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

## Handoff log

### C1, C3–C7, C11 · Claimed · 2026-09-29 · knowledge-consolidation session

- Result: one session claims the Ready pre-seeding tasks together and does them
  in order on branch `knowledge/concept-consolidation`, because they share
  `knowledge-store.ts`, `connectors.ts` and the Entry Detail view and cannot run
  as parallel writers. Each task still ships as its own commit with its row.
- Deviations: batch claim instead of one task at a time, for the reason above.

### C1 · Done · 2026-09-29 · luna-worker

- Result: archive is admission-only in storage filtering, curation, and Entry Detail; legacy archive verdicts remain readable but cannot be written.
- Evidence: `cd packages/gateway && npm run build` (passed); `npx vitest run src/knowledge/knowledge-store.test.ts` (29 passed); `TRON_IOS_TEST_TIER=ui-validation scripts/tron-ios-test build` (passed); `TRON_IOS_TEST_TIER=ui-validation scripts/tron-ios-test run --only-testing TronMobileUITests/TronKnowledgeDetailUITests/testArchiveAndUnarchiveRoundTripUsesAdmissionLabels` (1 passed).
- Changes: this commit
- Tasks added: none
- Kept on purpose: `archive` stays in Gateway and iOS verdict decoding for persisted legacy data; curation explicitly refuses new archive verdict writes.
- Deviations: an initial default-tier UI test invocation was rejected because the suite belongs to UIValidation; reran with the UI-validation tier. The first iOS build found and corrected an out-of-scope local variable reference before passing.
- For the next agent: C2 may remove the verdict value only after the live record is cleared and archived by admission; do not infer live-data cleanup from these fixture tests.
