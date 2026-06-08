# Post-AHA Adversarial Closeout Evidence Manifest

Current score: **6/100**

Status: **active**

Branch: `codex/primitive-engine-teardown`

## Summary

This manifest records red/green proof for the post-AHA adversarial closeout
campaign. PAC-0 intentionally adds failing gates before fixes so the closeout
work is driven by executable evidence instead of the external Downloads plan.

## Evidence Table

| ID | Status | Change summary | Verification | Residuals | Commit |
|----|--------|----------------|--------------|-----------|--------|
| PAC-0 | passed_after_fix | Created the scorecard, evidence manifest, README links, and intentionally red static gate target for the PAC findings. | Red proof captured by `cargo test --manifest-path packages/agent/Cargo.toml --test post_aha_adversarial_closeout_invariants -- --nocapture`; see PAC-0 red proof below. | Closed; PAC-1 through PAC-10 own the remaining red gates. | `1d1aa2f34` |
| PAC-1 | pending | Pending. | Pending. | Mac generated-project policy still needs repair. | pending |
| PAC-2 | pending | Pending. | Pending. | README/AGENTS source-truth paths still need repair. | pending |
| PAC-3 | pending | Pending. | Pending. | Runtime docs and database inventory still need parity proof. | pending |
| PAC-4 | pending | Pending. | Pending. | Mac launch-agent and subprocess ownership still need physical moves. | pending |
| PAC-5 | pending | Pending. | Pending. | Mac SourceGuard-style coverage still needs implementation. | pending |
| PAC-6 | pending | Pending. | Pending. | iOS hierarchy and mirrored tests still need expansion. | pending |
| PAC-7 | pending | Pending. | Pending. | Rust docs and 890+ LOC split-plan rows still need proof. | pending |
| PAC-8 | pending | Pending. | Pending. | Local/GitHub CI parity still needs PAC target wiring. | pending |
| PAC-9 | pending | Pending. | Pending. | AHA provenance, privacy scope, and residue wording policy still need durable proof. | pending |
| PAC-10 | pending | Pending. | Pending. | Final closeout verification has not run. | pending |

## PAC-0 Red Proof

Command:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_aha_adversarial_closeout_invariants -- --nocapture
```

Result: exit 101 on 2026-06-08. The target compiled without warnings and ran
10 tests: 1 passed and 9 failed intentionally.

Expected setup proof:

- `post_aha_adversarial_closeout_scorecard_stays_formalized`

Expected red findings:

- `mac_generated_project_policy_is_truthful`: Mac generated project policy is
  still asserted as a tracked diff in older workflows/gates.
- `documented_source_truth_paths_exist_or_use_supported_globs`: README/AGENTS
  still contain stale canonical source paths.
- `startup_domains_and_database_inventory_match_runtime_truth`: README still
  claims startup registers `context`, and database docs need full runtime table
  parity.
- `mac_launch_agent_and_subprocess_have_physical_owners`: launch-agent and
  subprocess code still live under `Server/Health`.
- `mac_source_guards_cover_wrapper_contracts`: Mac SourceGuard-style tests do
  not yet exist.
- `ios_transport_and_chat_tests_mirror_production_owners`: Retry/WebSocket and
  Chat tests are not fully mirrored under production-owner folders.
- `rust_progressive_docs_and_loc_split_plans_are_current`: top-level Rust docs
  and 890+ LOC split-plan rows need expansion.
- `local_and_github_ci_run_the_same_static_closeout_targets`: local and GitHub
  test target lists are not aligned and do not yet include PAC.
- `aha_provenance_privacy_and_residue_policy_are_in_repo`: AHA plan provenance,
  privacy scan scope, and fallback/compatibility wording policy need durable
  in-repo proof.

## Residual Risk Log

- PAC-1 through PAC-10 remain open by design after PAC-0. No row will be marked
  complete until its guard, docs, targeted verification, and evidence are green.
