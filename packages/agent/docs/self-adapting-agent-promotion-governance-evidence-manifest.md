# Self-Adapting Agent Promotion Governance Evidence Manifest

Branch: `codex/self-adapting-agent-promotion-governance`
Baseline commit: `e781a6aef263327d82f666611cb975a71e67e2ee`
Status: **complete**

## Baseline Evidence

- Checkout started clean at `e781a6aef263327d82f666611cb975a71e67e2ee`.
- The prior Self-Adapting Agent Authorship scorecard was complete at 100/100
  and already proved generated artifacts, patch proposals, materialized files,
  and generated UI remain resources rather than live worker registrations.
- No repo-managed first-party skills directory existed at
  `packages/agent/skills/`.

## Row Evidence

| Row | Status | Evidence | Verification | Residual Risk | Commit |
|---|---|---|---|---|---|
| SAPG-0 | passed_after_fix | Added SAPG scorecard/evidence docs and the `self_adapting_agent_promotion_governance_invariants` closeout target. | Static harness checks baseline text, README links, local CI, and GitHub CI wiring. | Closed. | this slice |
| SAPG-1 | passed_after_fix | Inventory covered `engine::promote`, public `/engine` schemas, socket DTOs, catalog mutation, resource definitions, resource wrappers, generated UI, and worker boundaries. | Static target checks changed root paths and promotion source markers. | Future new promotion-like paths must join this inventory. | this slice |
| SAPG-2 | passed_after_fix | Promote schemas require decision/evidence/candidate/reason/idempotency fields; socket DTOs forward them; transport no longer strips promote `idempotencyKey`. | Contract static gate and `promote_transport_response_schema_matches_engine_promote_result` cover request/response shape. | Clients must be updated to send the new fields. | this slice |
| SAPG-3 | passed_after_fix | Added `promotion_governance` validator for accepted final decisions, accepted verified evidence, resource scope compatibility, admin-only system-scoped governance refs, and decision/evidence/candidate linkage. | `engine_promote_requires_governance_authority_and_session_ownership` exercises missing governance and valid governed promotion; `engine_promote_workspace_rejects_system_governance_refs_for_non_admin` proves workspace actors cannot borrow system governance refs. | Link semantics are intentionally narrow and can be expanded only through this gate. | this slice plus SAASTC cleanup |
| SAPG-4 | passed_after_fix | Workspace/system authority split is enforced in the validator while preserving session provenance ownership checks. | Workspace cross-session, cross-workspace, and system non-admin regressions fail before mutation; admin system promotion passes. | Admin policy remains the existing `ActorKind::Admin/System` boundary. | this slice |
| SAPG-5 | passed_after_fix | Added `capability_definition` typed resource kind and candidate allow-list covering artifacts, capability definitions, materialized files, patch proposals, generated UI, and agent rules. | Static gate checks resource definitions and `CANDIDATE_KINDS`; runtime tests use capability-definition and materialized-file candidates. | Candidate semantics remain resource-backed, not live runtime registration. | this slice |
| SAPG-6 | passed_after_fix | Patch proposal and materialized-file lifecycle wrappers remain resource-only; `engine::promote` is the only catalog visibility widening path. | SAA fixture plus SAPG static gate prove no bypass through file/resource promotion wrappers. | Applying a patch remains separately governed by existing resource/file authority. | this slice |
| SAPG-7 | passed_after_fix | Generated UI stays a `ui_surface` candidate resource and no product UI or auto-enable path was added. | SAA generated UI guards plus SAPG candidate static gate cover the retained boundary. | Rich UI rendering remains bounded by the existing `ui_surface` schema. | this slice |
| SAPG-8 | passed_after_fix | Agent runtime grants still exclude promotion, worker registration, trigger creation, and worker write authority. | Static gate checks the grant source and external worker token validation markers. | Future worker registration slices must use existing worker authority, not this promote gate. | this slice |
| SAPG-9 | passed_after_fix | Promotion result and promoted function metadata echo redacted governance refs for replay/audit. | Runtime test asserts response refs and function `promotionGovernance` metadata. | Catalog change rows carry subject/revision; detailed refs live on the function snapshot. | this slice |
| SAPG-10 | passed_after_fix | PET/SAC/SAA invariant targets stay in the closeout suite, and SAPG adds provider/worker/static gates. | Local and GitHub closeout lists include SAPG beside the existing cross-campaign targets. | Closed for this slice. | this slice |
| SAPG-11 | passed_after_fix | Code, tests, docs, README updates, validation, clean status, and commit are delivered together. | Verification log below records focused and full checks. | Closed. | this slice |

## Verification Log

| Command | Result | Notes |
|---|---|---|
| `cargo test --manifest-path packages/agent/Cargo.toml promote --lib -- --nocapture` | passed | Focused promotion unit coverage passed: 6 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_promotion_governance_invariants -- --nocapture` | passed | SAPG static gates passed: 6 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_authorship_invariants -- --nocapture` | passed | SAA regression target passed: 15 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | passed | SACB regression target passed: 17 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture` | passed | Trace/replay regression target passed: 8 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture` | passed | Serial integration target passed: 2 tests. |
| `scripts/tron ci fmt check clippy test` | passed | Full local CI passed after splitting the new promotion-governance tests out of the large `meta_primitives.rs` file. |
| `scripts/personal-info-guard.sh` | passed | Personal-info literal guard passed. |
| `git diff --check` | passed | Whitespace check passed. |
| `git status --short` | passed_after_commit | Clean state verified after the closeout commit. |

## Closeout

Generated artifacts, patch proposals, materialized files, generated UI surfaces,
and capability definitions remain resource-backed candidates. No production
deploy command is run, no provider-visible promotion tool is added, and no
generated worker is launched by this slice.
