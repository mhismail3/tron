# Self-Adapting Agent Worker Trigger Launch Evidence Manifest

Status: **complete**

Baseline: `899910502ec894e1ba8b0c6a5bb0795549383d88`

## Row Evidence

| Row | Status | Evidence | Verification | Residual Risk |
|---|---|---|---|---|
| SAAWTL-0 | passed_after_fix | Added scorecard, evidence manifest, inventory docs/TSV, invariant target, README links, and local/GitHub static-gate wiring. | `self_adapting_agent_worker_trigger_launch_invariants::saawtl_docs_readme_and_ci_are_linked`. | Whole-repo HRA/PCC/TPC/TMB/SACB inventory rows are current after the SAAWSD closeout refresh. |
| SAAWTL-1 | passed_after_fix | Source inventory covers trigger dispatch, autostart plan parsing, activation issue, SAAWBH vault, stdin launch, attempt audit, replay/export, and forbidden surfaces. | `saawtl_scorecard_and_inventory_are_complete`. | Inventory is static and intentionally conservative. |
| SAAWTL-2 | passed_after_fix | `worker_autostart_plan` resource type and runtime-scoped `AutostartPlan` parser enforce reviewed status, trigger/launch references, activation request fields, stdin-only delivery, no restart, duplicate replay policy, and secret-looking value rejection. SAAWSD reuses the parser through `pub(in crate::engine::runtime)` visibility without creating a public launch surface. | `saawtl_source_enforces_trigger_only_stdin_launch`; focused runtime rejection test. | JSON schema is broad for some fields; runtime parser owns semantic checks. |
| SAAWTL-3 | passed_after_fix | `worker::launch_from_trigger` is admin/internal, high-risk, system-ledger idempotent, and requires `worker.activate` plus `worker.launch`; runtime rejects missing trigger causal context and target idempotency. | `worker_trigger_launch_rejects_direct_calls_and_unreviewed_context`. | Causal trigger metadata is trusted engine context, not model payload. |
| SAAWTL-4 | passed_after_fix | Trigger launch calls `worker::issue_activation` and `worker::launch_activation` with `saawtl:issue:<attempt-id>` and `saawtl:launch:<attempt-id>` keys. | `worker_trigger_launch_dispatch_issues_stdin_launch_once_and_replays_attempt`. | Worker id agreement is proven after activation issue and before process start. |
| SAAWTL-5 | passed_after_fix | Attempt id hashes autostart plan id, trigger id, and target idempotency key; duplicate delivery returns existing idempotency outcome/attempt without second supervisor start. | Focused replay assertion on fake supervisor start count. | Concurrency collision handling relies on the engine ledger and deterministic resource id. |
| SAAWTL-6 | passed_after_fix | `worker_trigger_launch_attempt` records requested, activation-issued, launch-starting, ready-pending, and failed states with redacted errors and id/key fingerprints only. | Static schema gate plus attempt payload assertions. | Attempt payload keeps activation/process ids by design. |
| SAAWTL-7 | passed_after_fix | Response reports ready-pending/starting process state; SAAWA hello/register remains the only callable readiness transition. | Existing SAAWO readiness tests plus SAAWTL process payload assertion. | No post-ready payload replay is implemented. |
| SAAWTL-8 | passed_after_fix | External activation workers still call `validate_activation_trigger_registration`; public/provider surfaces contain no trigger-launch names. | Static boundary checks. | Future provider/export additions must keep these names internal. |
| SAAWTL-9 | passed_after_fix | No scheduler, interval, spawn loop, restart policy, launchd/SMAppService, service-manager, or deploy path was added. | Static forbidden-string/path checks. | A future scheduler requires a successor scorecard. |
| SAAWTL-10 | passed_after_fix | Runtime reuses SAAWBH process-memory bundle vault and stdin launch. Attempt/process payloads exclude activation bundle JSON. | Focused sentinel assertions and SAAWBH invariants. | First issue caller still receives the live bundle inside the immediate invocation result, as inherited from SAAWA/SAAWBH. |
| SAAWTL-11 | passed_after_fix | Closeout commands include focused SAAWTL/SAAWBH/SAAWO/SAAWA tests, primitive trace, integration, full CI, personal-info guard, iOS project drift, and git hygiene. | Final closeout log in commit message/final response. | Full CI duration is high; focused tests were used while iterating. |

## Verification Notes

- `worker_trigger_launch_dispatch_issues_stdin_launch_once_and_replays_attempt` proves reviewed trigger dispatch creates one attempt, one activation issue, one stdin consume, and one process start, then replays by target idempotency key without a duplicate start.
- `worker_trigger_launch_rejects_direct_calls_and_unreviewed_context` proves direct calls without trigger causal context fail closed.
- `worker_trigger_launch_rejects_wrong_policy_before_issue_or_start` proves a non-`stdin_activation_bundle_v1` reviewed launch plan is rejected before attempt creation or process start.
- `self_adapting_agent_worker_trigger_launch_invariants.rs` statically verifies docs/README/CI parity, resource schema registration, primitive contract markers, forbidden surface absence, and inventory coverage.

## Relationship To Predecessor Campaigns

- SAAWA remains the only activation issuance and readiness contract.
- SAAWO remains the only direct-exec process supervision contract.
- SAAWBH remains the only live activation-bundle custody and stdin handoff contract.
- SAAWTL adds trigger-created composition over those paths; it does not duplicate token minting, process supervision, or readiness routing.
- SAAWSD adds a successor schedule-to-trigger layer over SAAWTL. It records safe
  scheduled ticks and enqueues `trigger::dispatch`; it does not change
  SAAWTL's trigger causal guard, activation issue, vault consume, process start,
  or readiness boundaries.
