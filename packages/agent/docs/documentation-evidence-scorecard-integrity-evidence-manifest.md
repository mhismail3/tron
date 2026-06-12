# Documentation / Evidence / Scorecard Integrity Evidence Manifest

This manifest records source-audit evidence, command evidence, failed attempts,
and residual risk for the current-lineage DESI slice. The branch is
`codex/documentation-evidence-scorecard-integrity-current`, based on
`687dc1e1f4b51701452f2ba25c92f34bc018a950`. The older
`codex/documentation-evidence-scorecard-integrity` branch at
`f931c3126a2ee62940f42512278715c9c65c2079` is stale branch quarry-only
evidence.

## Source Audit

| Surface | Evidence | Outcome |
| --- | --- | --- |
| Binding slice list | DESI-0 | The operator-provided original plan names Documentation / Evidence / Scorecard Integrity as original remaining meta-slice 10, after Developer Experience / Repo Hygiene / Automation and before runtime readiness. |
| Current lineage | DESI-0 | `git merge-base --is-ancestor 687dc1e1f HEAD` returned exit 0 before edits; HEAD was `687dc1e1f4b51701452f2ba25c92f34bc018a950`. |
| Stale branch quarantine | DESI-0 | Existing `codex/documentation-evidence-scorecard-integrity` at `f931c3126a2ee62940f42512278715c9c65c2079` is recorded as quarry-only and not used as completion evidence. |
| Active closeout surfaces | DESI-1 | README, AGENTS, CI, PR template, local quality script, platform docs, scorecards, evidence manifests, inventories, invariant targets, and predecessor inventories were enumerated from the current tracked tree. |
| Active docs truthfulness | DESI-2 | README intro and engine protocol sections had stale cleanup-in-progress wording; README and `packages/agent/src/engine/mod.rs` now state retained current behavior. |
| Historical evidence boundary | DESI-2,DESI-8 | Older evidence manifests retain red/green provenance, old failures, and old branch names only as historical evidence; DESI inventory classifies those artifacts explicitly. |
| Evidence provenance | DESI-3 | DESI invariant parses retained scorecards and requires companion evidence manifests with command results or source-grounded rationale, rejecting recorded-later placeholders. |
| Scorecard arithmetic | DESI-4 | DESI invariant parses all retained `*scorecard.md` files, validates closed status vocabulary, continuous row numbering, and exact 100-point totals. |
| Inventory coverage | DESI-5 | DESI inventory TSV covers retained docs/evidence/scorecard/gate boundaries; predecessor inventories now classify DESI artifacts. |
| README and docs sync | DESI-6 | README living-doc map, testing target list, HRA ownership summary, PR checklist, and engine progressive docs include the current DESI surface. |
| Local/GitHub static gates | DESI-7 | `scripts/tron.d/quality.sh` and `.github/workflows/ci.yml` run `documentation_evidence_scorecard_integrity_invariants` in the same order. |
| Deploy automation residue | DESI-8 | DESI invariant rejects `tron deploy`, `auto-deploy`, and `cmd_auto_deploy` from active local/GitHub quality docs. |
| Branch handoff | DESI-9 | Scorecard, inventory, and this manifest record branch name, base commit, stale branch policy, and pickup status command. |

## Row Evidence

| Row | Status | Change summary | Verification | Residuals |
| --- | --- | --- | --- | --- |
| DESI-0 | passed | Verified baseline ancestry, created `codex/documentation-evidence-scorecard-integrity-current`, and quarantined the stale DESI branch. | `git merge-base --is-ancestor 687dc1e1f HEAD` returned exit 0; branch refs recorded in scorecard and inventory. | None. |
| DESI-1 | passed | Added structured Markdown and TSV inventories for active and historical documentation/evidence surfaces. | DESI invariant checks TSV schema, accepted surface kinds, tracked paths, classification vocabulary, and row-to-scorecard coverage. | None. |
| DESI-2 | passed | Rewrote stale active README/source-doc cleanup wording to current-state prose while preserving historical evidence. | DESI invariant rejects specific stale active wording and checks present-tense replacement text. | Historical evidence remains append-style. |
| DESI-3 | passed | Added companion-evidence and command-result integrity checks for retained scorecards. | DESI invariant verifies every retained scorecard has a companion evidence manifest and concrete result/rationale text. | Older historical evidence can still preserve red proof. |
| DESI-4 | passed | Added arithmetic/status parser for retained scorecards. | DESI invariant checks every retained scorecard totals 100, has continuous numeric rows, and uses closed statuses. | None. |
| DESI-5 | passed | Added DESI rows to predecessor inventories and machine-checked DESI inventory coverage. | DESI and predecessor invariant targets verify the retained-path classifications. | None. |
| DESI-6 | passed | Updated README, PR template, HRA inventory summary, and engine module docs. | DESI invariant and affected predecessor targets check README/static-gate references. | None. |
| DESI-7 | passed | Wired the DESI target into local quality and GitHub static gates. | DESI and DXRHA invariants parse local/GitHub target order and require parity. | None. |
| DESI-8 | passed | Added negative guards for active stale wording, evidence placeholders, unresolved scorecard statuses, unclassified inventory rows, and deploy automation residue. | DESI invariant exercises the negative guards over active surfaces. | Historical/quarry artifacts are allowed only through explicit inventory classification. |
| DESI-9 | passed | Recorded branch, handoff, stale branch quarantine, and remote pickup facts. | DESI invariant checks branch/handoff markers and base-before-quarry ordering. | None. |
| DESI-10 | passed | Ran focused and broad closeout commands, staged intended files, and recorded final status evidence for handoff. | Verification log below records exact commands and results. | None known. |

## Verification Log

| Command | Result | Notes |
| --- | --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | passed, exit 0 | Rust formatting check passed. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | passed, exit 0 | Compile check passed with pre-existing warnings only. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture` | passed, exit 0 | DESI invariant target passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test developer_experience_repo_hygiene_automation_invariants -- --nocapture` | passed, exit 0 | DXRHA target passed after DESI local/GitHub target insertion and predecessor rows. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test ios_thin_client_generic_runtime_shell_invariants -- --nocapture` | passed, exit 0 | IOSTC target passed after predecessor rows. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test release_install_upgrade_rollback_discipline_invariants -- --nocapture` | passed, exit 0 | RIURD target passed after predecessor rows. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test configuration_profile_environment_discipline_invariants -- --nocapture` | passed, exit 0 | CPE target passed after predecessor rows. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test performance_resource_governance_invariants -- --nocapture` | passed, exit 0 | PERF target passed after predecessor rows. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture` | passed, exit 0 | PPACD target passed after predecessor rows. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test data_integrity_storage_evolution_migration_discipline_invariants -- --nocapture` | passed, exit 0 | DSEMD target passed after predecessor rows. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture` | passed, exit 0 | ODA target passed after predecessor rows. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | passed, exit 0 | SACB target passed after predecessor rows. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture` | passed, exit 0 | CSD target passed after predecessor rows. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture` | passed, exit 0 | SOL target passed after predecessor rows. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture` | passed, exit 0 | TPC target passed after predecessor rows. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture` | passed, exit 0 | HRA target passed after ownership-map rows. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --nocapture` | passed, exit 0 | PCC target passed after retained-file rows. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_saa_authorship_teardown_cleanup_invariants -- --nocapture` | passed, exit 0 | Off-plan authorship teardown cleanup target passed after DESI classification rows. |
| `scripts/tron ci fmt check clippy test` | passed, exit 0 | Broad local CI passed. |
| `scripts/personal-info-guard.sh` | passed, exit 0 | Full personal-info guard passed. |
| `cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | passed, exit 0 | iOS generated project drift check passed. |
| `git diff --check` | passed, exit 0 | Whitespace hygiene passed. |
| `git ls-files -ci --exclude-standard` | passed, exit 0 | Tracked ignored-file audit returned no paths. |
| `git status --short` | passed, exit 0 | Final pre-commit status review confirmed all intended files were staged and no unstaged entries remained. |

## Failed Attempts And Fixes

- `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture`
  initially returned exit 101. The red findings were useful: the generic
  scorecard parser assumed every retained scorecard used DESI's five-column
  table shape, the handoff phrase required by the guard was not exact, and the
  DESI scorecard quoted stale README wording that the active-doc guard rejected.
  Fixes made the generic parser accept older wider scorecard tables by reading
  the first four columns, added the exact handoff sentence, and described the
  stale README finding without repeating the rejected phrase.
- The focused DESI rerun returned exit 101 once more because Markdown line
  wrapping split the handoff and retained-substrate phrases across lines. The
  fix added an unwrapped handoff guarantee to the inventory and normalized
  whitespace before checking the README retained-substrate sentence.
- A shell log wrapper used zsh's read-only `status` variable before four
  predecessor cargo targets could be trusted. The wrapper was corrected to use
  `rc`, and the same required cargo commands were rerun successfully.
- `cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture`
  returned exit 101 after DESI added five static-gate rows to the CSD TSV. The
  fix updated the CSD inventory summary and the CSD row-count guard from 121 to
  126 rows.
- `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture`
  returned exit 101 after DESI added four docs rows and one test row to the TPC
  retention TSV. The fix updated the TPC Markdown summary counts to 100 docs
  rows and 481 test rows.
- `cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_saa_authorship_teardown_cleanup_invariants -- --nocapture`
  returned exit 101 because new DESI active evidence and TSV prose used an
  uppercase retired-residue acronym. The fix replaced that prose with neutral
  off-plan authorship teardown wording while keeping lowercase target paths and
  exact command names intact.

## Residual Risk

DESI intentionally classifies historical evidence instead of rewriting old
red/green provenance. Those files may still contain old branch names, old
failures, or closed-row transition text. Active current docs and closeout
artifacts are guarded against unresolved placeholders and stale open-loop
wording.
