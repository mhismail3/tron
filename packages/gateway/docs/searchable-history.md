# One searchable history, centered on Home

**Status: Chronicle generation retired (#1315); legacy Chronicle history
preserved and retrieved through existing owners (#1314, #1316).** Audit #1311's
historical source baseline is `b931c3f6c`; its measured installation facts below
are not a current-runtime attestation. No history migration, new store or
deployment is part of this document. Current contracts remain
[Home](home.md), [Knowledge](knowledge.md), [session search](session-search.md)
and [episodic memory](episodic-memory.md).

## Decision

**One history, centered on Home; no parallel summary producer.** Home's
endless-chat configuration and native memory/summary lifecycle are the only
ongoing summarization of conversation history and are unchanged by this decision.
Chronicle — Knowledge's derived cross-session observation records, produced by
the former `KnowledgeObservationService` — no longer generates anything: settled
turns create no observation record, coverage cut, background model call or
Knowledge work, and there is no startup re-admission of old cuts.

Existing Chronicle records are kept as attributable history, never deleted or
rewritten: their immutable revisions, coverage rows, provenance and
`sessionEntry` citations stay searchable and readable through Knowledge (the
iOS Library Legacy history, Home's read-only `knowledge` tool, the ordinary agent tool),
correctable, reflectable and clearable. Older observations are the only compact
discovery path into the 19,986 records that predate this Home, and remain useful
for that. Exclusions still hide them; a transcript that vanished leaves its
record as unverified evidence.

Retrieval of new history uses the existing owners only: Home's memory tools for
Home, `session_search`/`session_read` for other chats (#1314), accepted task
reports for delegated work, and Knowledge for saved sources, notes and legacy
observations. No composed adapter, supplement, mini-summary cache, prompt
appendix or per-read model call is built (#1316): nothing measured shows a gap
that justifies one.

### Why generation was removed (#1315)

Measured read-only on 2026-10-19 from the installation's Knowledge catalog,
coverage ledger and Home task records; no private text was read or published.

- **Redundant with native Home.** 3,899 of the 3,975 observation heads created
  October 12–18 (98%) came from sessions referenced by Home task records: the
  observer was re-summarizing delegated worker transcripts whose accepted reports
  Home already receives and summarizes through its own memory lifecycle. Home
  chapters themselves were excluded, so the remaining generation was a second,
  parallel summary of the same delegated work.
- **No consumer depended on new records.** A consumer map (Gateway, iOS, Mac,
  docs, tests) found only readers of stored records: Knowledge search/recall/read,
  the iOS Library Legacy history and Needs attention coverage sheet, explicit reflection and the agent
  tools. Home activation, the learned profile, the episodic compactor and chapter
  topics never read observations. The only generation-dependent surface was the
  iOS **Observe all Tron sessions** switch.
- **Generation had already silently stopped.** After the Gateway restart at
  08:32 UTC on October 18 every admitted cut failed with "No background models
  are configured" (101 failed cuts over the following 21 hours) and no new
  observation was written; nothing noticed.
- **Low measured answer value.** The October 13 private evaluation scored existing
  observations 2/25 against 10/25 for raw transcript retrieval; the #1311 samples
  showed audit echoes crowding primary sources, and the Home tool census showed no
  Knowledge calls.
- **Privacy and cost exposure without accounting.** The observer sent bash
  commands/output, tool text, hidden custom messages and compaction summaries of
  every granted conversation to the background provider with best-effort
  redaction, at one model call per settled turn, with no observer-specific usage
  accounting (cost unknown, not zero).

Adoption is a normal manual Gateway update: the next config write drops the
retired settings from storage, the iOS sheet becomes **Current interests**, and
an unobserved interval since the update is not backfilled. Rollback restores
the old code; legacy records and canonical transcripts are untouched either way.

## Current ownership and overlap

| Record / projection | Producer and authority | Consumers / automatic context | Retention and limitation |
| --- | --- | --- | --- |
| Session JSONL, including Home chapters | One canonical session runtime; Home ledger orders physical chapters under stable `homeId` | Chat/history, selected-branch reads, search projections; not all replayed into Home | Preserve canonical bytes/identity. Chapter sealing is not deletion. Attachments and thinking require their existing boundaries. |
| Home episodic catalog/tree | `HomeMemory` feeds one `EpisodicMemory` from Home commits; demand-driven compactor, not Chronicle | Frozen bounded preceding-history view on activation; `memory_search`, `zoom`, `date`; native memory browser | Derived projections and summaries, permanent logical indices and physical provenance; caps/omissions, checkpoint reclamation, no age expiry established. Summary wording is not factual proof. |
| Chapter rows/topics | Home ledger plus existing open memory | Native chapter list, bounded topic orientation; no separate chapter-summary pipeline | Disposable projection. Reading topics does not admit compactor spend. |
| Chronicle observations and coverage | Retired terminal-turn observer (#1315); Knowledge owns the preserved immutable revisions, heads and coverage rows | iOS Library Legacy history, Knowledge search/recall/read, explicit reflection/correction; Home can query Knowledge | Legacy only: nothing new is generated or re-admitted. No age TTL. Exact-range citations, not per-item. Explicit exclusions/forget remain Knowledge-owned. |
| Learned profile | Knowledge notes with profile/kind labels; existing audited profile writers | Bounded profile section in Home's system prompt | Maintained preferences/decisions, not arbitrary history. Never auto-promote retrieved observations into profile instructions. |
| Knowledge sources and notes | Explicit capture/ingestion/curation owners | Library and Knowledge retrieval; external source evidence | Separate legitimate canonical evidence, not transcript duplicates. Preserve revision/scope/admission/forget policy. |
| Session search cache | `SessionSearchService` derives bounded postings from canonical selected branches; optional local semantic ranking | Home `session_search`; snippets/IDs, no automatic corpus injection | Disposable SQLite acceleration. Present extractor indexes user/assistant text, not tool results or custom worker reports; coverage can be partial. |
| Task results | Task receipt/lifecycle owner; immutable report in worker's canonical session | Task/report tools and delivered result in Home; later episodic summary | Prefer the accepted report and exact worker citation, not every child transcript or progress artifact. Task state is not a second transcript. |
| Logs / audit documents / GitHub | Their existing owners | Operational diagnosis or deliberate cited research | Logs rotate and are not memory truth. Documents are not automatically collected. GitHub ingestion remains an explicit later choice (#897). |

Historically the observer was turn-triggered after terminal settlement, sent a
redacted projection that could include tool text, custom messages and compaction
summaries, and cited each item by its entire input range. Those properties now
describe the preserved records, not a running producer.

## Measured baseline and what it does not prove

Read-only installation observations on 2026-10-18 UTC; private reproducible artifacts
are retained as `files/chronicle-home-history-1311/` in the internal workspace.
No private text or source identities are reproduced here.

- Knowledge manifest storage version 4, configuration revision 4: observation
  enabled, global session eligibility granted, input 48,000 characters, output
  8,000, timeout 30 seconds, one configured attempt. Background inherits the
  subagent queue; no settings changed.
- **25,063 observation heads from 310 source sessions**, created September 15
  through October 18. **19,986 predate this Home's creation**; **zero** heads name
  its eight chapters. Last seven UTC dates, October 11–17 inclusive: **4,305**
  heads; October 18 is separately right-censored. These are records, not proven
  distinct useful facts or a constant future growth rate.
- **5,091 coverage cuts:** 4,699 observed, 169 empty, 42 excluded, 75 failed,
  106 unavailable. Unavailable reasons include 60 over-input-bound entries and
  46 missing invocation provenance. These are cut dispositions, not a success
  percentage over all turns: rejected pre-admissions are absent from coverage.
- Retained logs contain **360 shed-admission rows/cuts**, 309 since October 17
  UTC. No unique-turn denominator or bound-specific cause is recorded. Do not
  treat these as recoverable pending coverage.
- The Knowledge catalog was 69,083,136 bytes; all record revisions 200,273,100
  bytes; objects 180,248,912 bytes. These latter totals include Library/notes,
  not just Chronicle. One file inventory is not measured byte growth.
- Search cache: **140 sessions / 4,573 passages / 387,018,752 bytes**. Only **38
  of the 310 observation-source identities** occur in it. Different eligibility,
  size limits and supported entry kinds prevent calling 38/310 a recall score.
  Latest startup logged 140 reused, zero parsed sessions; no live search-service
  coverage response was obtained by this audit.
- Twenty-four observation bodies across 23 sources were schema/provenance
  sampled; twelve were inspected for meaning. Several older items preserved
  requests/decisions, while recent items also retained transient or image-related
  exchanges and report restatements. This is evidence of mixed value, not a
  corpus-wide precision estimate. Six newest sampled records lacked resolved
  model metadata. No trustworthy Chronicle token or dollar total was available.
- A prefix census of the latest three Home chapters found `zoom` 5,
  `memory_search` 4, `date` 3, `session_search` 1, and no Knowledge calls. Each
  chapter was capped at 16 MiB and stopped before the next oversized line; all
  three cuts were incomplete. This shows some actual retrieval, **not** lifetime
  usage or proof that Home never uses Chronicle.

Installed build-inputs selected `b931c3f6c`; the running epoch logged startup at
08:32:06 UTC with payload `0.1.0-beta.8`. A selected manifest is not proof of the
exact source revision loaded into that process. Separate database transactions,
file cut hashes and timestamps are not one cross-store snapshot.

### Retrieval observations

Six actual read-only Knowledge searches (`kind=observation`, limit 3): `bottom
blur`, `Chronicle`, `SIGSTOP`, `notification`, `reMarkable`, `bookmark`. Five returned
three hits; `SIGSTOP` returned no match. Wall times were 66–105 ms in one pass,
not a performance comparison or answer-quality score.

All three `bottom blur` hits came from one later audit session, not three
independent primary sources; two cited 50-entry ranges. Two original cited
messages were still present and described the earlier and revised values.
This demonstrates useful discovery **and** re-observation/echo crowding. A later
summary about a decision must not become an independent corroborating source.
The no-match query does not establish absence from transcripts, Home or profile.

The earlier October 13 private backfill experiment (#893/#894) reported 10/25
correct for complete raw retrieval, 2/25 for existing observations, and 14/25 for
hybrid cards/raw. It used a 24-session prototype and one model judge, not today's
live service; its price estimates and timings are not current billing or a new
measurement. Its proposals for `session_read` and Knowledge ranking have since
landed (#895/#896). Do not reimplement them or repeat their historical gaps as
current facts. Its separate card index remains an evaluation artifact, not a
production store to adopt.

## Retrieval over existing owners

Home's memory search/zoom covers Home; `session_search` and `session_read`
cover other chats; Knowledge recall/read covers saved sources, notes and legacy
observations; task report reads cover accepted delegated outcomes. Other-chat
hits open through `session_read`, and legacy Chronicle revisions open through
Knowledge before checking their available canonical sources. There is no
fan-out adapter, parallel history tool/store or ingestion pipeline.

Each result needs a typed, mechanically followable evidence handle:

- Canonical passage: installation + physical session + branch/entry identity +
  source digest/revision. A copied fork prefix is not new evidence; preserve its
  origin, and index only independently owned suffixes.
- Home address: stable `homeId` + permanent index/range, **also** physical
  chapter/session/entry provenance and current cut. A summary address is not a
  replacement canonical identity.
- Knowledge: record + immutable revision + existing `sessionEntry` or captured
  source/object evidence. Preserve coarse-range citation status on old records;
  never manufacture item-level support or silently reinterpret a range digest as
  an individual-line digest.
- Task outcome: task identity plus exact accepted report entry/operation; progress,
  later re-telling and child artifact copies are not separate completed outcomes.

Group exact shared/overlapping evidence before ranking; one cut must not occupy
all six slots just because it yielded many observation records. Identical text
from independent sources may support each other, but is not identity. Collapse
known re-tellings only with provenance, not model similarity or irreversible
record deletion. Conflicting dates/claims stay visible; newest does not mean true.

### Freshness, authorization and cancellation

Resolve the existing owner on every read; enforce exact request/route/revision
fences across awaits. Verify source membership and digest before exposing a
passage or claiming support. Re-check exclusions/forget/admission at publication;
revocation wins over cached search hits. Mark partial coverage, capped/omitted
content, stale evidence and unavailable sources explicitly. A legacy observation
whose transcript vanished may be the only retained evidence: preserve it, label
it unverified, and do not use it for exact-value certainty.

Do not broaden root-chat, project, personal-source or delegated-session grants.
Excluding a Knowledge observation and allowing a user
canonical read are different current authorities, not a reason to bypass either.
Keep raw authenticated `home.memory.evidence` out of model tools: it can contain
credentials. Agent-facing passages require the existing safe projection contract.
Retrieved instructions remain quoted evidence, never authorization or confirmed
profile policy. Prompt wording is defense, not proof against injection.

The #1314 real Home/RuntimeRegistry journey reproduced and closed two gaps:

1. Search now applies selected-branch context edits and shared credential redaction
   before postings, optional embeddings, snippets and fallback titles. Explicit
   titles are redacted whole. The disposable index derivation changes, so older
   raw rows cannot be reused even when canonical files are unchanged. No canonical
   transcript or historical tool result is rewritten; no live secret was probed.
2. Other-chat search excludes ledger-owned Home chapters, including disabled
   chapters, matching `session_read` rather than returning dead-end citations.
   Home's native memory tools remain the only Home-history route. A controlled
   ranking wait also proves an edited stale passage is dropped before publication.

A preserved v2-style observation fixture is recalled/read at its immutable
Knowledge revision, then verified against its exact source entry through the
existing tools. This proves route closure for that fixture, not universal
fact-level support: legacy ranges remain coarse and missing evidence unverified.

## Stages and rollback

1. **Preserve and measure (#1311).** Bounded inventory/citation samples; raw
   audit artifacts stay private.
2. **Qualify existing retrieval (#1314).** Privacy/edit and other-chat citation
   boundary closed; #893 retains eligible coverage/report gaps. Normal owner
   startup rederives the disposable search index.
3. **Retire generation, keep history (#1315, #1316).** Maintainer-approved. The
   retirement journey `src/sessions/legacy-chronicle.integration.test.ts` runs
   a real RuntimeRegistry over a pre-#1315 Knowledge namespace (Chronicle
   enabled with the global grant, observed v2 records, pending/failed gaps) and
   proves that settled turns generate nothing; that the retired settings are
   stripped on read and dropped at the next write; and that legacy recall,
   search, byte-identical read, tool citation, coverage paging, Clear,
   reflection, correction and exclusions keep working. Its report is
   `test-results/legacy-chronicle/report.json`. No composed retrieval adapter is
   built: none was measured to be needed.

No legacy record, coverage row or canonical transcript is migrated, compacted or
deleted. Rollback is a code rollback; history is unaffected either way, and an
interval without observation is never silently backfilled.
