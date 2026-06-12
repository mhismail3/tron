# Self-Sufficient Agent Runtime Readiness Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**
Total weight: **100**

Current implementation branch: `codex/self-sufficient-agent-runtime-readiness-current`.
Baseline: `98b9a7eeb62afb9a844ffd7dd6cd8f591aab6de6`
(`docs: harden documentation evidence integrity`). `git merge-base
--is-ancestor 98b9a7eeb62afb9a844ffd7dd6cd8f591aab6de6 HEAD` is the lineage
gate for this slice.

Stale branch quarantine: `codex/self-sufficient-agent-runtime-readiness` at
`e62804694fa6578758d4f7e7c6cf12f334a13853` is quarry-only historical evidence.
It is not current-lineage completion evidence and must not be merged,
cherry-picked, or copied wholesale into this branch.

Scope quarantine: SSARR is a readiness audit only. It does not implement a
self-adapting agent, generated workers, learned rules, learned memory, tool
synthesis, agent-authored state systems, repo-managed skills, product-specific
iOS panels, scheduler/autostart surfaces, provider behavior, deploy/install
behavior, or a public capability-promotion product API.

| Row | Name | Points | Status | Closure |
| --- | --- | ---: | --- | --- |
| SSARR-0 | Baseline, lineage, and scope quarantine | 5 | passed | HEAD descends from DESI baseline `98b9a7eeb62afb9a844ffd7dd6cd8f591aab6de6`; stale branch `codex/self-sufficient-agent-runtime-readiness` is recorded as quarry-only; this scorecard states readiness-audit-only scope. |
| SSARR-1 | Extension-point inventory and ownership map | 10 | passed | Markdown and TSV inventories map every retained extension point relevant to generated workers, learned rules/memory, tool synthesis, and agent-authored state to the current owner, proof source, readiness status, risk/blocker, and no-implementation decision. |
| SSARR-2 | Generated-worker readiness without implementation | 10 | passed | Scheduler, queue, primitive, external-worker, session, and trace surfaces were audited as future extension points. Current blockers are explicit host lifecycle, authoring, activation, schedule, and policy design. Negative guards reject generated-worker runtime, schedule, activation, and authoring implementations. |
| SSARR-3 | Learned rules/memory readiness without repo-managed memory/skills | 10 | passed | State, resource, profile, session, and context boundaries were audited. Future learned rules/memory can be stored only as agent-owned state/resources with migration policy; repo-managed first-party skills and learned-memory stores remain absent. |
| SSARR-4 | Tool synthesis and capability boundary readiness | 10 | passed | The capability contract, primitive execution path, provider tool-call handling, public protocol, engine promotion, and authority boundaries were audited. Public `promote` remains user-owned engine visibility promotion, not tool synthesis or client-side catalog authoring. |
| SSARR-5 | Agent-authored state custody and migration readiness | 10 | passed | State/resource roots, traces, logs, database migrations, profile/runtime paths, and retention docs are mapped for future agent-authored state. Risks are future migration/versioning policy and custody review, not missing current primitive substrate. |
| SSARR-6 | Runtime orchestration, error, and auditability preconditions | 8 | passed | Provider loop, primitive execution, queues, triggers, external workers, shutdown/error handling, trace/log/replay evidence, and queue receipts cross-link ODA, DSEMD, PERF, CSD, and SOL proof without duplicating feature work. |
| SSARR-7 | Public protocol and iOS generic-shell readiness | 8 | passed | Public `/engine` and iOS generic runtime shell remain thin and generic. No iOS source changed; iOS validation for this docs/static-gate slice is XcodeGen drift checking, while source guards reject successor product panels. |
| SSARR-8 | Negative guards against accidental successor feature reintroduction and stale cruft | 10 | passed | The SSARR invariant scans active Rust, Swift, README, scripts, CI, and active docs for successor terms, classifies allowed historical/readiness hits, and rejects repo-managed skills, generated-worker runtime, learned-memory store, tool-synthesis runtime paths, public synthesis promotion claims, and iOS successor panels. |
| SSARR-9 | Static-gate/local-GitHub/README/evidence parity and handoff | 9 | passed | `self_sufficient_agent_runtime_readiness_invariants` is wired into local `scripts/tron.d/quality.sh`, GitHub `rust-static-gates`, README living-doc/testing sections, and predecessor inventories in the same closeout order as DESI. |
| SSARR-10 | Broad verification and final closeout | 10 | passed | Focused SSARR tests, affected predecessor invariants, broad local CI, personal-info guard, XcodeGen drift check, diff/ignored-file audits, and clean status are recorded in the evidence manifest before commit. |

## Readiness Verdict

The primitive engine is ready as a substrate for a future self-sufficient or
self-adapting runtime only if that future work enters through explicit new
scorecards and preserves the current boundaries:

- generated workers: use the existing external-worker, trigger, queue, grant,
  stream, and ledger substrate after a future host lifecycle and activation
  policy is designed;
- learned rules/memory: use agent-owned state/resources with explicit schema,
  migration, retention, and trust policy; do not reintroduce repo-managed
  memory/rule/skill planes;
- tool synthesis: treat synthesized tools as future catalog/resource/worker
  lifecycle work behind authority grants and schema/idempotency checks; do not
  widen the model-facing `execute` schema;
- agent-authored state: use the resource/state/session evidence substrate with
  auditable provenance, retention, migration, and cleanup contracts;
- iOS: render generic runtime data only, without fixed successor product panels.

This verdict is readiness evidence, not feature acceptance. Future successor
work still needs its own design, tests, docs, migration policy, and scorecard.
