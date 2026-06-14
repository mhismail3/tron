# Baseline Pre-Restoration Closure Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**
Total weight: **100**

Current implementation branch: `codex/baseline-pre-restoration-closure-current`.
Baseline: `1545da37d3c6186fbc6613789bae3d4a5481f976`
(`Document primitive baseline feature delta`). `git merge-base --is-ancestor
1545da37d3c6186fbc6613789bae3d4a5481f976 HEAD` is the lineage gate for this
goal.

Reference architecture: [`iii-hq/iii`](https://github.com/iii-hq/iii). The
baseline alignment target is worker/function/trigger composability: every
restored capability must enter as worker-owned functions and triggers in the
live catalog, not as a hardcoded harness feature or fixed product panel. This
goal does not implement those restorations; it cleans and certifies the
baseline before restoration starts.

Scope quarantine: BPRC is cleanup, documentation, evidence, inventory, and
static-gate closure only. It does not implement self-updating runtime lifecycle,
runtime-authored worker launch, learned rules or memory, tool synthesis,
restored product domains, restored iOS product panels, MCP, worktree/git, web,
prompt library, notifications, voice notes, subagents, scheduler/autostart
surfaces, provider behavior changes, DB migrations, or deploy/install behavior.

| Row | Name | Points | Status | Closure |
| --- | --- | ---: | --- | --- |
| BPRC-0 | Baseline lineage, branch, and scope quarantine | 5 | passed | HEAD descends from `1545da37d3c6186fbc6613789bae3d4a5481f976`; branch, baseline, frozen prior baseline, iii-style worker/function/trigger target, and strict no-feature scope are recorded. |
| BPRC-1 | Active-doc truth cleanup | 10 | passed | Active README and iOS architecture wording now describe the current primitive baseline rather than an in-progress teardown; historical scorecards remain evidence, not active architecture authority. |
| BPRC-2 | Feature-index conversion into restoration backlog | 10 | passed | The BPRC inventory TSV contains 24 machine-readable restoration backlog rows, one per feature-index bucket, with old surface, current equivalent, dependencies, risk, server/iOS impact, restoration constraint, and `not_in_baseline` status. |
| BPRC-3 | Successor-feature absence guards | 10 | passed | The BPRC invariant rejects restored product domain roots, repo-managed skills, fixed iOS product-panel roots, runtime-authored worker claims, learned-memory/rule stores, tool-synthesis runtime claims, and provider-visible tool widening. |
| BPRC-4 | Baseline residue and dead-surface audit | 10 | passed | Active source/doc scans classify retained suspicious wording and guard against stale active placeholders; no additional deletion was safe without weakening predecessor evidence or current substrate contracts. |
| BPRC-5 | Engine substrate readiness statement | 8 | passed | The BPRC inventory and README record the foundational boundary: engine catalog, workers, functions, triggers, resources, grants, queues, streams, replay, and generic UI surfaces are substrate; restoration behavior remains future worker-owned module work. |
| BPRC-6 | iOS baseline parity and UX readiness audit | 10 | passed | The current iOS client baseline is verified through focused IOSTC coverage and the BPRC audit: onboarding/pairing, chat, reconstruction, settings/auth/model setup, diagnostics/logs, attachments, generic runtime surfaces, and reconnect/error states remain the supported surface. |
| BPRC-7 | Static-gate and CI parity | 8 | passed | `baseline_pre_restoration_closure_invariants` is wired into local `scripts/tron.d/quality.sh`, GitHub `rust-static-gates`, README testing docs, and the invariant enforces exact target-order parity. |
| BPRC-8 | Artifact inventory and provenance integrity | 8 | passed | The BPRC markdown/TSV inventory covers every active BPRC artifact, baseline reference, iii reference, feature index, README/static-gate path, key engine/iOS substrate path, and all 24 restoration backlog rows. |
| BPRC-9 | Pre-restoration entry contract | 9 | passed | The inventory defines the mandatory contract every future restoration slice must satisfy: worker/module owner, resource/event schema, authority policy, iOS parity decision, tests, docs, migration policy, rollback strategy, and no-hardcoded-harness proof. |
| BPRC-10 | Broad validation and frozen handoff | 12 | passed | Focused BPRC and predecessor invariants, full local Rust CI, personal-info guard, XcodeGen drift check, whitespace/ignored-file audits, clean status, commit, push, and post-cleanup branch/tag handoff are recorded in the evidence manifest. |

## Closure Verdict

The current baseline is certified for restoration planning only. The next
feature slice may restore one old feature bucket only if it enters through the
pre-restoration contract and preserves the worker/function/trigger model:
worker-owned functions and triggers registered into the live catalog, with
authority, evidence, replay, rollback, and iOS parity decisions recorded before
activation.
