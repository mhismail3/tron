# One searchable history, centered on Home

**Status: proposal, not implemented.** Bounded audit #1311, source baseline
`b931c3f6c`. No history migration, capture-policy change, new store, runtime
change or deployment is authorized by this document. Current contracts remain
[Home](home.md), [Knowledge](knowledge.md), [session search](session-search.md)
and [episodic memory](episodic-memory.md).

## Decision

Keep the history; consolidate retrieval, not canonical storage. **Chronicle is
useful as a derived, cross-session discovery aid, not as a second memory authority
or a complete record.** It is the iOS Knowledge dashboard's observation view,
produced by `KnowledgeObservationService`, not Home's `EpisodicMemory`.

Home continuity and Chronicle are not currently double-observing Home: the
producer excludes every ledger-owned Home chapter, enabled or disabled. Chronicle
retains older/non-Home conversation discoveries, including tool-derived outcomes
that raw session search currently omits. Those facts generally originate in
canonical transcripts; the unique value is compact discovery and cross-session
reach, not independent evidence that makes the transcript disposable.

Do not bulk-backfill or disable capture yet. First qualify privacy, search
coverage, citation closure and observer accounting. Then measure whether selective
cross-session extraction earns its cost beyond complete transcript/report search.
Do not create a separate episode-card database, synthetic Home chapters, another
memory tree, nightly mirror, or a recurring prompt appendix.

## Current ownership and overlap

| Record / projection | Producer and authority | Consumers / automatic context | Retention and limitation |
| --- | --- | --- | --- |
| Session JSONL, including Home chapters | One canonical session runtime; Home ledger orders physical chapters under stable `homeId` | Chat/history, selected-branch reads, search projections; not all replayed into Home | Preserve canonical bytes/identity. Chapter sealing is not deletion. Attachments and thinking require their existing boundaries. |
| Home episodic catalog/tree | `HomeMemory` feeds one `EpisodicMemory` from Home commits; demand-driven compactor, not Chronicle | Frozen bounded preceding-history view on activation; `memory_search`, `zoom`, `date`; native memory browser | Derived projections and summaries, permanent logical indices and physical provenance; caps/omissions, checkpoint reclamation, no age expiry established. Summary wording is not factual proof. |
| Chapter rows/topics | Home ledger plus existing open memory | Native chapter list, bounded topic orientation; no separate chapter-summary pipeline | Disposable projection. Reading topics does not admit compactor spend. |
| Chronicle observations and coverage | Terminal-turn observer over eligible non-Home root sessions; Knowledge owns immutable revisions, heads and exact cut/digest coverage | Chronicle UI, Knowledge search/recall/read, explicit reflection; Home can query Knowledge | Prospective, not historical backfill. No age TTL found. Exact-range retry dedup is not semantic fact dedup. Explicit exclusions/forget remain Knowledge-owned. |
| Learned profile | Knowledge notes with profile/kind labels; existing audited profile writers | Bounded profile section in Home's system prompt | Maintained preferences/decisions, not arbitrary history. Never auto-promote retrieved observations into profile instructions. |
| Knowledge sources and notes | Explicit capture/ingestion/curation owners | Library and Knowledge retrieval; external source evidence | Separate legitimate canonical evidence, not transcript duplicates. Preserve revision/scope/admission/forget policy. |
| Session search cache | `SessionSearchService` derives bounded postings from canonical selected branches; optional local semantic ranking | Home `session_search`; snippets/IDs, no automatic corpus injection | Disposable SQLite acceleration. Present extractor indexes user/assistant text, not tool results or custom worker reports; coverage can be partial. |
| Task results | Task receipt/lifecycle owner; immutable report in worker's canonical session | Task/report tools and delivered result in Home; later episodic summary | Prefer the accepted report and exact worker citation, not every child transcript or progress artifact. Task state is not a second transcript. |
| Logs / audit documents / GitHub | Their existing owners | Operational diagnosis or deliberate cited research | Logs rotate and are not memory truth. Documents are not automatically collected. GitHub ingestion remains an explicit later choice (#897). |

The observer is turn-triggered, after terminal receipt/attention settlement.
Startup recovers admitted pending/failed cuts from canonical evidence. Its
1–30-second admission retry timer is not a Chronicle schedule or periodic miner.
The audited installation had three draft automations, none naming Chronicle or
observation; this does not certify arbitrary external jobs on the Mac.

Observation model input excludes thinking/attachment bodies and removes known
credential forms and machine paths; it can include tool text, displayed or hidden
custom-message text, and compaction/branch summaries. This differs from Home's
projection. Both are lossy, and neither is a universal secret scrubber. Observation
items carry speaker/certainty/date but cite an entire input range, not an exact
supporting entry per assertion.

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

## Simplest single-history retrieval design

### One logical evidence graph, existing canonical owners

Start with existing tools: Home projection search/zoom for Home, session search
and cited read for other chats, Knowledge recall/read for observations and saved
sources, task report reads for accepted outcomes. Strengthen those paths first.
A common result adapter may later **extend the existing Home `session_search`
operation** to fan out to those owners with an explicit source scope. Do not add a
parallel history tool/store or run another ingestion/indexing pipeline merely to
unify presentation. Human chapters/memories remain existing views of this history.

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

### On-demand context supplement, not a prompt appendix

A first implementation should return existing mini-summaries or short redacted
passages, **without a model call**. Home asks when its current view lacks detail;
ordinary turns do not pay a lookup/injection tax. Proposed initial response bounds:
at most six distinct evidence groups and **8 KiB total encoded UTF-8**, including
labels/citations/omission markers; summary text at most 600 bytes per group, and at
most two 1,000-byte canonical proof passages within that same total. Count actual
encoded bytes, not a bytes-to-token estimate. Offer exact continuation handles.

Use a ready Home node or an existing Knowledge observation as the mini-summary.
If no qualified summary exists, return a passage, not a synchronous compactor
request. Any later paid extraction must justify itself under #894's existing
owner/coverage path; no per-query persistent summary cache in v1. Searchable task
reports are already authored summaries and should be tried before re-summarizing
worker transcripts.

Rank relevance, exact entity/project and source strength before recency. Favor
first-party decisions/outcomes on equal relevance; keep personal Library-source
scope opt-in. Diversify source groups and label request, proposal, report and
verified result distinctly. If an identical source range is already in Home's
frozen view, offer expansion rather than injecting its summary twice. Never claim
novelty merely because the same fact appears under a newer observation ID.

Only the requested result enters the current activation as an untrusted tool
result. Do not insert it into the system/profile, tool declarations, every future
activation, or the front of the frozen view. Canonical tool delivery then follows
normal Home summarization once. No fixed repeated appendix, per-turn changing
system text, eager search wake, or new prefix/cache-control mechanism is needed.

### Freshness, authorization and cancellation

Resolve the existing owner on every read; enforce exact request/route/revision
fences across awaits. Verify source membership and digest before exposing a
passage or claiming support. Re-check exclusions/forget/admission at publication;
revocation wins over cached search hits. Mark partial coverage, capped/omitted
content, stale evidence and unavailable sources explicitly. A legacy observation
whose transcript vanished may be the only retained evidence: preserve it, label
it unverified, and do not use it for exact-value certainty.

Do not broaden root-chat, project, personal-source or delegated-session grants.
Knowledge observation consent is not blanket permission to send all private
history to any provider. Excluding a Knowledge observation and allowing a user
canonical read are different current authorities, not a reason to bypass either.
Keep raw authenticated `home.memory.evidence` out of model tools: it can contain
credentials. Agent-facing passages require the existing safe projection contract.
Retrieved instructions remain quoted evidence, never authorization or confirmed
profile policy. Prompt wording is defense, not proof against injection.

Two source-level gaps require qualification before widening retrieval:

1. Session-search extraction currently uses raw message text, unlike redacted,
   context-edit-aware cited reads (#1314). No live secret leak was probed.
2. Search can admit Home chapters, while `session_read` deliberately refuses them.
   Every unified hit must name its correct next-read route; don't solve this by
   exposing privileged Home canonical evidence. Reproduce the closure gap in a
   real Home journey before choosing filtering versus safe Home-projection routing.

## Stages, rollback and retirement acceptance

1. **Preserve and measure (this audit).** Leave Chronicle running, keep canonical
   transcripts/Knowledge revisions, and record bounded inventory/citation samples.
   No settings or storage format change. Raw audit artifacts stay private.
2. **Qualify existing retrieval.** #1314 privacy/edit boundary; #893 current eligible
   coverage and report indexing; #1315 usage/shed diagnostics. Use named per-source
   omissions, not a claim that a cache-row count proves complete search. Existing
   #895/#896 read/ranking behavior stays owned and tested, not replaced.
3. **Shadow bounded composition.** Read-only evaluation of existing owners, then
   a small result adapter only if it improves held-out tasks. No second store or
   automatic injection. Roll back the adapter/code to the previous reader; no
   canonical data rollback is required. Old tools are not retained as speculative
   aliases: identify real consumers before any replacement.
4. **Selective enrichment, only after measured need.** Reuse #894 for explicitly
   admitted historical cuts with dry-run spend bounds and item-level citations.
   Prefer unique non-Home gaps/reports; never backfill synthesized Home chapters.
   Current v2 observation revisions have live readers. Any new persisted schema
   requires an explicit preservation/migration/rollback decision, not the older
   proposal's simultaneous claims of atomic replacement and unqualified old-reader
   compatibility. Do not re-observe all history simply to change the prompt version.
5. **Retire only proven duplicate production.** Require matched evaluation showing
   no unique recall loss, source/citation closure, privacy tests and measured cost
   reduction before a maintainer-approved logged capture-policy change. Preserve
   existing observations and the path to read them. Re-enable through the same
   logged owner if quality regresses; name any unobserved interval, since prospective
   re-enable is not backfill. UI consolidation/renaming is separate product work.
   No automatic deletion, compaction of canonical transcripts or destructive rollback.

### Finite acceptance tasks

Use the same bounded corpus and queries for complete transcript/report search,
existing observation retrieval and composed retrieval. Separate pre-observer,
non-Home recent, Home-only, worker-report-only and duplicate-everywhere cohorts.
Use human-checkable canonical answer/citation oracles, not only a model judge.

| Task | Distinguishes |
| --- | --- |
| Find an older decision before observation began | Genuine canonical-history coverage vs missing observations; no-match must name coverage limits. |
| Recover the two historical blur changes, then distinguish present state | Exact values, primary citation, stale-value trap, later audit echoes not corroboration. |
| Find an accepted worker outcome recorded only as a custom report | Unique report coverage vs observing every worker/child/tool output. |
| Recall a preference already in Home/profile and in another chat | Dedup and no repeated context/profile promotion. |
| Query a recent Home-only instruction and an off-branch correction | Stable cross-chapter identities, safe next-read routing, edit/omission handling. |
| Same fact in three repeated summaries plus one primary source | Source-group diversity and marginal value, not hit count. |
| Forgotten/excluded/personal source, synthetic secret and quoted injection | Publication-time scope/redaction; no task/profile/settings mutation from retrieval. |
| Append/rollover/revise while search awaits | Latest-request/cut fences; no stale publication or uncertain-input replay. |

Before retiring any duplicate producer: all required fixture citations must open
through their permitted reader; no lost unique-answer cohort; zero synthetic
credential leakage or unauthorized effects; byte/result bounds hold; incomplete
coverage stays explicit. Report exact correct/partial/wrong, independently
supported unique facts, duplicate groups in top six, tool calls, response bytes,
latency, provider attempts/usage and unknown billing. Accept an adapter only for
incremental useful answers or fewer bounded reads at unchanged correctness—not
more hits, fewer lines, or incomparable warm/cold timings. Spending/decommission
thresholds must be set before that experiment, once #1315 supplies a baseline.
