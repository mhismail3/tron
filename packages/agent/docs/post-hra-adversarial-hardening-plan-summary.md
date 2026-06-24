# Post-HRA Adversarial Hardening Plan Summary

Status: `completed`

Provenance: summarized from `/Users/<USER>/Downloads/PLAN (1).md`, the
operator-provided plan that seeded the post-HRA adversarial hardening campaign.
The original Downloads path is not a durable repository dependency; this file
is the in-repo digest for future audits.

## Objective

Create and complete a new 100-point closeout campaign after HRA completion.
The campaign had to add red static gates before fixes, update code/tests/docs
together, checkpoint each phase, preserve honest residuals, and finish only
after the scorecard reached `100/100`, all new gates passed, full-repo
personal-info scanning passed, and the worktree was clean.

## Required Artifacts

- `packages/agent/docs/post-hra-adversarial-hardening-scorecard.md`
- `packages/agent/docs/post-hra-adversarial-hardening-evidence-manifest.md`
- `packages/agent/tests/post_hra_adversarial_hardening_invariants.rs`

## Campaign Rows

| ID | Area | Weight | Required outcome |
|----|------|--------|------------------|
| AHA-0 | Scorecard/evidence/red gates | 5 | Create scorecard and evidence artifacts, link README, add initially failing static gates, and record red proof. |
| AHA-1 | Personal-info/source identity | 12 | Make the full committed repo pass personal-info scanning by redacting historical home paths, replacing personal fixture paths and feedback identities, and guarding split handle/domain constructions. |
| AHA-2 | Deleted-doc/template residue | 10 | Remove deleted-doc, template, managed-skill, and stale active-scorecard wording from live docs and templates. |
| AHA-3 | CI/static-gate parity | 12 | Make docs/templates/iOS/Mac changes run Rust-owned static gates and make GitHub Rust CI match the local `scripts/tron ci test` harness shape. |
| AHA-4 | Xcode drift/Mac tests | 8 | Enforce tracked iOS project drift checks after XcodeGen and run focused Mac wrapper tests in CI while retaining Mac build-for-testing coverage. |
| AHA-5 | Rust module ownership | 10 | Remove production `#[path]` aliases, move provider/settings/orchestrator modules to physical owners, and avoid compatibility reexports. |
| AHA-6 | Rust docs/budgets | 6 | Expand progressive docs for ownership-critical Rust roots and add an 850 LOC warning band for near-budget files. |
| AHA-7 | iOS transport residue | 10 | Replace `MiscClient` with concrete `system`, `message`, and `logs` clients, update call sites/tests, and remove Git workflow residue without compatibility facades. |
| AHA-8 | iOS hierarchy/budgets/docs | 9 | Deepen iOS SourceGuard hierarchy checks, add Swift near-budget rows, refresh iOS docs/resource claims, and remove redundant availability annotations. |
| AHA-9 | Inventory/provenance integrity | 8 | Rename identity-style move maps to current ownership maps, reject open statuses in completed inventories, and replace external HRA plan dependency with an in-repo plan summary. |
| AHA-10 | Final adversarial closeout | 10 | Rerun all static gates, full Rust CI, full personal-info guard, XcodeGen checks, focused iOS/Mac tests, broad residue scans, and a fresh adversarial audit. |

## Interface Constraints

- iOS internal clients expose concrete `system`, `message`, and `logs`
  surfaces instead of `misc`; no `misc` compatibility property remains.
- Provider shared helpers live under `domains::model::providers::shared`.
- Settings profile loading lives under
  `domains::settings::profile::storage::loader`.
- Orchestrator exports keep the intentional narrow boundary without a
  module-inception owner name.
- Feedback recipients, release URLs, and repository URLs use generic tracked
  defaults, untracked local config, CI secrets, or runtime configuration.

## Verification Contract

The plan required red proof first, then focused Rust/iOS/Mac/workflow
verification, and final closeout with:

- `scripts/tron ci fmt check clippy test`
- HRA/PCC/AHA invariant targets
- full `scripts/personal-info-guard.sh`
- iOS XcodeGen drift checks and focused SourceGuard/client tests
- Mac XcodeGen generation and focused wrapper tests
- broad retired-term/residue scans
- a clean final worktree

## Residual State

The AHA campaign is completed in-repo. The durable source of truth is the
completed scorecard, evidence manifest, static gates, README links, inventories,
and this redacted plan summary. No live instruction depends on the original
Downloads file.
