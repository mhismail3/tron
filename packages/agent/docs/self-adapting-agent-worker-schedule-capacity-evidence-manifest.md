# Self-Adapting Agent Worker Schedule Capacity Evidence Manifest

Status: **complete**

Baseline: `9e9393acde1284b0c684a5c15d9bf331133c9928`

## Row Evidence

| Row | Status | Evidence | Verification | Residual Risk |
|---|---|---|---|---|
| SAAWSC-0 | passed_after_fix | Added SAAWSC scorecard, evidence manifest, inventory docs/TSV, static invariant target, README links, and local/GitHub CI wiring. | `self_adapting_agent_worker_schedule_capacity_invariants::saawsc_docs_readme_and_ci_are_linked`. | Whole-repo closeout still depends on final command log. |
| SAAWSC-1 | passed_after_fix | Source inventory covers resource pagination, memory/SQLite stores, host forwarding, scheduler scan state, service cancellation, predecessor dispatch path, and forbidden surfaces. | `saawsc_scorecard_and_inventory_are_complete`. | Static inventory requires updates for new capacity surfaces. |
| SAAWSC-2 | passed_after_fix | Added `ListResourcesPageRequest`, `ListResourcesPage`, and `ResourceListCursor`; `list` delegates to first-page behavior so existing callers retain the same contract. | Static source gate plus resource store pagination tests. | Cursor shape is internal and not stable API. |
| SAAWSC-3 | passed_after_fix | Memory and SQLite stores share deterministic ordering and strict cursor-after semantics; limit validation is inherited from `ListResources`, and pages cap at 500. | `in_memory_resource_pages_resume_without_duplicates`; `sqlite_resource_pages_match_in_memory_cursor_semantics`. | Tied timestamp behavior is string-gated by source order and cursor comparison. |
| SAAWSC-4 | passed_after_fix | Added `worker_schedule_scan_state` resource definition, schema id, required safe fields, lifecycle states, and worker namespace claim. | `saawsc_scan_state_contract_is_registered_and_safe`. | Schema validates shape; runtime owns semantic cursor parsing. |
| SAAWSC-5 | passed_after_fix | Runtime uses `SCHEDULE_SCAN_PAGE_SIZE` 100 and `SCHEDULE_SCAN_MAX_PER_POLL` 500 to bound per-poll scanning. | Static runtime gate and capacity resume test. | Constants are internal and can change only with scorecard/gate updates. |
| SAAWSC-6 | passed_after_fix | Runtime loads the last scan cursor, pages after it, persists progress after each page, clears cursor on tail, and wraps back to the head when a prior cursor yields no more rows. | `worker_schedule_dispatch_resumes_beyond_first_scan_budget`. | No sharded scheduling yet. |
| SAAWSC-7 | passed_after_fix | Transport service passes `CancellationToken` state into the scheduler; runtime checks cancellation between pages and items and persists cancelled status. | `worker_schedule_dispatch_persists_cancelled_scan_without_enqueue` and static service gate. | Cancellation is cooperative between items, not mid-resource validation. |
| SAAWSC-8 | passed_after_fix | Scan state payload contains cursor, poll timing, budget flags, summary, trace id, and generic redacted error only. | `assert_safe_scan_state_payload` plus static forbidden-surface checks. | Safe ids remain durable by design. |
| SAAWSC-9 | passed_after_fix | Capacity test creates 500 newer future schedules and one older due schedule; first poll exhausts budget without enqueue, recreated runtime resumes and enqueues the older due schedule. | `worker_schedule_dispatch_resumes_beyond_first_scan_budget`. | Test uses in-memory host; store-level SQLite pagination has separate coverage. |
| SAAWSC-10 | passed_after_fix | SAAWSC adds no provider/public/deploy/iOS/launchd/SMAppService/repo-skill/restart/retry/payload replay surface and no direct activation/launch/supervisor calls. | `saawsc_forbidden_surfaces_are_absent`. | Future surfaces must update this gate before merge. |
| SAAWSC-11 | passed_after_fix | Closeout commands cover formatting, check, focused capacity/store tests, SAAWSC invariant, predecessor invariants, and final git hygiene. | Final closeout log in commit/final response. | Full CI is high-cost and run only when warranted by broad changes. |

## Verification Notes

- `in_memory_resource_pages_resume_without_duplicates` proves cursor pages compose back to the same ordered first-page list without duplicate resources.
- `sqlite_resource_pages_match_in_memory_cursor_semantics` proves SQLite paging also drains the full filtered set without duplicate resources.
- `worker_schedule_dispatch_resumes_beyond_first_scan_budget` proves a due schedule older than 500 newer reviewed schedules is eventually reached by cursor resume.
- `worker_schedule_dispatch_persists_cancelled_scan_without_enqueue` proves cooperative cancellation can stop before item dispatch and still produce durable safe scan state.

## Relationship To Predecessor Campaigns

- SAAWSD remains the schedule-to-trigger dispatch contract.
- SAAWTL remains the trigger-created worker launch path.
- SAAWBH remains live activation-bundle custody and stdin handoff.
- SAAWO remains direct-exec process supervision.
- SAAWA remains activation issuance and readiness.
- SAAWSC only hardens how SAAWSD finds reviewed schedule plans at capacity; it does not change dispatch authority or launch behavior.
