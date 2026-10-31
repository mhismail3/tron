# Built-in Home improvement loop

## Contract and scope

Home improves its existing prompt, brief and profile using outcomes of work it already
owns. No standing audit worker, second task database, model judge, new queue, scheduler
or implicit permission. [Diagnosis](FINDINGS.md) separates observations from hypotheses.
The source owners remain authoritative; projections are disposable and never write back.

**Slice 1 is implemented:** read-only task metrics through the existing Home `task`
tool. **Slice 2 is design only:** Home-owned self-check Automation and brief changes.
Nothing here creates an Automation, modifies live Profile/AGENTS, restarts or installs.
It becomes available only after the maintainer's next rebuild.

## Signal: one record projection, existing health joins

`home-task-metrics.ts` reads the existing `HomeTaskStore`; `HomeOwner.taskTool` admits
`task {action:"metrics", from?, to?, taskId?, limit?}` under Home's existing identity
check. It is available on an ordinary or trigger Home turn because it is a read, not a
shell workaround. No worker runtime/session is acquired, no report or private transcript
is read, and no diagnostic exports blocker text or identifiers.

Default cohort: roots delegated in the preceding 72 hours, **[from,to)**. Explicit UTC
ISO cutoffs span at most 31 days. A named task selects its full resume lineage regardless
of creation time. Ancestors/successors and their counters are current observations,
not an as-of historical snapshot. Old roots resumed during the window are not silently
mixed into the root-created scorecard; inspect them by task ID/history.

The TypeScript result type is exported as `HomeTaskMetrics`. The projection includes:

| Output | Authority / missingness |
|---|---|
| Root ID, delegation time, operation IDs/status/outcome, admitted resumes | Existing record identity and `homeTaskLineages`; refused admissions never count as operations/resumes |
| Attention events + exact blockers | Retained accepted check-ins, deduplicated by original task/session/operation/ID; always partial, not a total wake count |
| Parks | Explicit admitted `needs-input` outcomes only; stored reason/detail are settlement provenance, not an inferred cause; use `task report` for the actual requested decision |
| Prompt/output tokens | Existing operation spend; `homeTaskPromptTokens` preserves legacy inclusive-input semantics; null spend stays missing; partial totals identify their operation denominator |
| Delegate→landed, steer count, full-suite/lock/reviewer wait, USD | Null with explicit reasons: records have no trustworthy endpoint/interval/control/billing owner; never classify prose or chat gaps as durations |

Five #2135 scorecard fields are present: approval→main, deploy lag, main reds,
flake rate and resumes/task. The first four remain unavailable in this record-only
view, with pointers to the existing `scripts/tron health` owner rather than a copied
Git/verify/install classifier. Resumes/task exposes the mean and denominator of terminal
recorded root lineages, **partial** because canonical history completeness is not checked.
It is not the complete-history aggregate consumed by health, nor resumes per landed slice.

One store pass validates all records and resume links; the existing namespace epoch and
write counter fence awaits. Any change refuses rather than merging snapshots. There is
no cache or incremental counter. The scan refuses above 10,000 records. Rows default to
20, max 50; `coverage.more` names omitted lineages. Per-lineage operation/attention/park
arrays retain at most the latest 50 with counts/truncation metadata. The full response
refuses above 256 KiB; reduce limit or select a task. Arbitrarily large histories are
not hidden behind a misleading complete flag. A long-term retention/index decision
belongs to the task owner if this explicit bound is reached.

Source text is Home-private: blockers may contain private details. This is deliberately
not the anonymous diagnostic export from `home-response-timing.ts`/`home.taskHistory`.
Do not feed it to public issues, external judges or generic logs. Full records remain
under existing retention/authority; the projection creates no new persisted telemetry.
The investigation's private packet is evidence for this task, not a runtime dependency.

## Slice 2: consume signals through Automations

Reuse #2156's generic Automations definitions, durable run/outbox and Home target,
not a new monitor owner. A maintainer-authorized Home Automation sends a finite,
attributed self-check objective at an agreed cadence/expiry. No cadence or definition
is installed by this slice. A trigger cannot create/mutate other schedules, grant
file/shell rights, renew task grants, approve changes or override pauses.

On that wake, Home reads metrics and existing health evidence where available, then:

1. Reports the bounded window, denominators, missingness and top repeated cost.
2. Opens only the relevant `task status`/`task report` and Profile revisions for context;
   never launches a census worker merely because the Automation fired.
3. Proposes one concrete cause→owner change and its smallest faithful oracle.
4. Distinguishes pending proposal, approved change, landed commit and observed deployment.
   Existing Change IDs, Profile revisions, task reports and Git commits carry linkage;
   no duplicate outcome/proposal ledger.
5. On the next comparable cohort, checks whether the intended cost changed without
   hiding regressions. Different SHA/config/case samples are not a controlled A/B.

The present records cannot measure all waits or exact landing latency. Future typed
intervals/control/publication joins belong at their existing completion owners, with
bounded content-free projections and a contract/test, not keyword classifiers or a new
metrics database. Exact wake defects use inbox delivery/ack receipts and invocation
causality; an acknowledged task is not proof Home made a good ruling.

## Feedback destinations and authority

| Destination | Proposed path | Approval and rollback |
|---|---|---|
| Home system prompt / worker brief template | Reviewed repo patch to `tron-home-extension.ts` / `home-task-dispatcher.ts`; only explicit authorized work, no wake-originated direct write | Existing code-review/maintainer work authority and Git revert; effect waits for maintainer rebuild. Never pretend a source patch already changed the live prompt |
| Inferred operational lesson / durable ruling | Existing Profile `standing-decision` or `delegation-default` with source task/report/maintainer provenance | Existing Profile Changes/Undo owner. Home learning remains inferred/nonbinding. Confirmed/safety content changes keep the shared exact before/after tap; no inferred confirmation |
| Shared repo rule | Draft narrowly scoped `AGENTS.md` diff only after repeated evidence, reconciled with owning skill/docs | Existing authorized repo workflow, review and Git revert; never automatic rule weakening or live instruction injection |

**Existing gap, not invented Undo:** Profile supports shared Changes/Undo today;
external AGENTS/skill/prompt destinations explicitly remain drafts until their owner
supports safe Undo (`HOME_OPERATING_CONTEXT`). Git revert is code rollback, not a native
Changes-sheet Undo button. Slice 2 must not advertise/apply an external-destination
Changes action without that exact owner contract. It may retain a draft patch and ask
for the existing bounded maintainer-authorized repo task. No new approval engine or
confirmation bypass is justified by calling the change “self-improvement.”

Reversible Profile changes use their current apply/log/Undo tier; changes that expand
trust/authority/privacy, incur spend/install, or are irreversible keep the one native
approval path. A retro recommendation, task result, inferred note or Automation is not
a maintainer approval. A Home objective ruling cannot relax safety or consumer promises.

## Decision memory: reuse Profile, not a rulings store

`home-profile.ts` already defines `standing-decision`, provenance, exact revisions,
supersession, confirmation and active/retired state. `profile-store.ts` owns durable
bodies and the shared Changes owner owns conflict-safe Undo. This covers durable rulings.
Home's view intentionally receives a metadata index; relevance is Home's job, not a
Gateway heuristic that promotes notes into authority.

Proposed slice-2 brief discipline:

- Before dispatch/resume, read relevant active standing decisions by exact ID/revision.
- Include the few applicable rulings and their source/confirmation/scope in the brief;
  do not dump the profile or create a separate “binding rulings” JSON file.
- Separate objective Home dispositions from maintainer-only irreversible/subjective
  decisions. An inferred operational lesson cannot become a binding safety rule.
- Check the draft for contradictory requirements: full-before vs affected-before,
  LOC quotas, repeated test-text permission requests, legacy/compat bridges.
- Resolve conflicts using canonical maintainer evidence/active revisions; do not resurrect
  retired guidance or infer a ruling from the summarizer's paraphrase.

This requires a brief/prompt change and dedicated tests, **not included in slice 1**.
It addresses standing-decision application drift. The separate follow-up in FINDINGS
establishes a lost task-completion attribution, not a deleted standing decision.

## Maintainer-owed closure

Archive summaries are not a current obligation owner. The Home `obligation` tool uses
canonical chapter history for one typed request/reported-done/verified/reopened ledger
with exact maintainer-source references; no new database, audit worker, Profile todo
list or keyword-derived status. Missing verification never resurrects a human action.
Existing task/approval owners retain their lifecycle; closing a prerequisite never
authorizes key revocation. Home lists only current open items. The Gateway enforces
current maintainer-origin writes and canonical tool-result verification evidence.
See [Home's contract](../../packages/gateway/src/modules/home/home-obligations.md)
for bounds, persistence and real-Gateway summary/chapter/restart regression proof.

## Regression proof and delivery

Existing real Home provider-wire E2E executes `task metrics` after dispatch, steer,
Stop and in-place resume. It proves the advertised schema, admitted counts/token sums,
missing values, window endpoints, invalid calls, Home-only access, no intent/path export
and byte-identical task files. Existing continuity journeys prove inherited blocker
ID deduplication, active/missing-spend exclusion, explicit parks and refused resume
admissions. They use records actually produced by the Gateway fixture, not a copied
algorithm or live private data. Existing task-history tests retain the complete-history
oracle; metrics deliberately does not replace it.

Run `scripts/tron verify --changed` on the committed diff, retain counts/logs and obtain
independent acceptance of test edits. Home owns broad post-land runtime/full-tier
checkpoints. No full Gateway suite, Debug/Stable restart, install, live state mutation,
self-check Automation or brief-template behavior change belongs to this implementation.
