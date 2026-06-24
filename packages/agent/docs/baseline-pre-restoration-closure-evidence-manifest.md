# Baseline Pre-Restoration Closure Evidence Manifest

Status: `complete`

Branch: `codex/baseline-pre-restoration-closure-current`

Baseline: `1545da37d3c6186fbc6613789bae3d4a5481f976`

Invariant target:
`packages/agent/tests/baseline_pre_restoration_closure_invariants.rs`

## Evidence Ledger

| Row | Result | Change or proof | Evidence | Follow-up |
| --- | --- | --- | --- | --- |
| BPRC-0 | passed | Created the BPRC branch from `1545da37d3c6186fbc6613789bae3d4a5481f976` and recorded iii worker/function/trigger alignment as the pre-restoration baseline target. | `git status --short`; `git rev-parse HEAD`; `git merge-base --is-ancestor 1545da37d3c6186fbc6613789bae3d4a5481f976 HEAD`. | Closed. |
| BPRC-1 | passed | Updated active README and iOS architecture wording from teardown-branch language to current primitive-baseline language. | `baseline_pre_restoration_closure_invariants` checks BPRC references and active-doc wording. | Historical evidence remains classified rather than rewritten. |
| BPRC-2 | passed | Added 24 restoration backlog rows to the BPRC TSV, covering every feature-index bucket. | BPRC invariant requires `BPRC-FEATURE-01` through `BPRC-FEATURE-24`, `future_restoration`, and `not_in_baseline`. | Future slices consume one row at a time. |
| BPRC-3 | passed | Added absence guards for old product domains, repo-managed skills, fixed iOS product panel roots, successor runtime claims, and provider-visible tool widening. | BPRC invariant scans domain roots, iOS roots, skill path, README/docs wording, and capability contract shape. | New successor work must update guards deliberately. |
| BPRC-4 | passed | Audited active stale/residue terms and retained only classified historical or future-restoration wording. | BPRC invariant rejects active unresolved markers and unscoped successor claims in BPRC artifacts and root docs. | No source deletion was required in this docs/static-gate closure. |
| BPRC-5 | passed | Recorded the engine substrate readiness boundary and iii-aligned worker/function/trigger contract. | BPRC inventory rows for engine fabric, runtime, catalog, resources, capability contract, and iOS runtime surfaces. | Self-adapting runtime remains a future feature slice. |
| BPRC-6 | passed | Recorded iOS current-baseline parity without adding fixed UI. | BPRC scorecard and inventory cite IOSTC-backed surfaces; no Swift source changes were made. | Simulator rerun remains required if Swift/protocol/UI changes later. |
| BPRC-7 | passed | Wired BPRC into local and GitHub static closeout gates. | BPRC invariant parses `scripts/tron.d/quality.sh` and `.github/workflows/ci.yml` and requires identical target order. | Closed. |
| BPRC-8 | passed | Added BPRC inventory and TSV covering all BPRC artifacts, references, substrate rows, and backlog rows. | BPRC invariant parses TSV header, row count, classifications, tracked paths, and row coverage. | Closed. |
| BPRC-9 | passed | Added the pre-restoration entry contract. | Inventory and README contain the required module owner, schemas, authority, iOS parity, tests, docs, migration, rollback, and no-hardcoded-harness proof requirements. | Every future restoration slice must satisfy it. |
| BPRC-10 | passed | Ran focused and broad closeout verification and left a clean branch handoff. | Commands listed below. | Closed. |

## Verification Commands

| Command | Result | Notes |
| --- | --- | --- |
| `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture` | passed | BPRC invariant target passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture` | passed | DESI predecessor invariant passed after BPRC artifact additions. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test self_sufficient_agent_runtime_readiness_invariants -- --nocapture` | passed | SSARR predecessor invariant passed after BPRC wording/classification. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_minimality_closure_invariants -- --nocapture` | passed | PMC predecessor invariant passed after BPRC closeout target wiring. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test ios_thin_client_generic_runtime_shell_invariants -- --nocapture` | passed | IOSTC predecessor invariant passed; no Swift source changes were made. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test developer_experience_repo_hygiene_automation_invariants -- --nocapture` | passed | DXRHA local/GitHub gate parity passed. |
| `scripts/tron ci fmt check clippy test` | passed | Full Rust CI passed with BPRC in the closeout target set. |
| `scripts/personal-info-guard.sh` | passed | Full personal-info guard passed. |
| `cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | passed | XcodeGen drift check passed. |
| `git diff --check` | passed | No whitespace errors. |
| `git ls-files -ci --exclude-standard` | passed | No ignored tracked artifacts. |
| `git status --short` | passed | Final worktree clean after commit. |

## Failed Attempts And Fixes

- Initial scope review found that the existing baseline had a feature index but
  no machine-readable restoration backlog. Fixed by adding 24 `BPRC-FEATURE-*`
  TSV rows and invariant coverage.
- The active README and iOS architecture docs still described the branch as a
  primitive teardown branch. Fixed by moving active wording to current
  primitive-baseline language while preserving historical scorecards as
  evidence.
- `self_sufficient_agent_runtime_readiness_invariants` initially rejected the
  feature index as successor vocabulary without SSARR classification. Fixed by
  classifying the feature index and BPRC artifact family as future-restoration
  backlog/static-gate evidence, not live successor implementation.
- Full CI initially failed in `primitive_code_cleanup_invariants` because the
  PCC file inventory did not yet classify the BPRC artifacts and the feature
  index repeated retired iOS product-panel names. Fixed by adding PCC inventory
  rows for the feature index and BPRC artifacts and replacing the literal panel
  names with a generic retired-panel category.
- Full CI then failed in `hierarchical_rearchitecture_invariants` because the
  HRA file inventory and ownership map did not yet classify the BPRC artifacts.
  Fixed by adding HRA rows for the feature index and BPRC artifacts.
- Full CI then failed in `security_authority_capability_boundaries_invariants`
  because the SACB security-marker inventory did not yet classify the BPRC
  artifacts. Fixed by adding SACB rows for the feature index and BPRC artifacts
  as static/backlog authority guards with no secret custody.
- Full CI then failed in the off-plan-authorship cleanup invariant because BPRC
  and feature-index wording reused stale successor terms. Fixed by rewording
  those scope boundaries to current restoration-backlog terminology without
  changing behavior.

## iOS No-Source-Change Rationale

BPRC is a baseline closure and certification goal. The supported iOS current
surface is already covered by IOSTC and the current retained UI roots:
`Capabilities`, `Chat`, `Components`, `Onboarding`, `RuntimeSurfaces`,
`Settings`, `System`, and `Theme`. No Swift source change is required until a
future restoration slice introduces a new protocol or UI behavior.

## Residual Risk

This goal certifies the baseline before restoration; it does not prove any
future feature is safe to restore. Each future feature bucket must satisfy the
pre-restoration entry contract and run its own focused server/iOS/regression
checks.
