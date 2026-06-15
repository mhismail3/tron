# iOS Affordance Restoration Map Evidence Manifest

Branch: `codex/ios-affordance-restoration-map-current`

Old reference: `ad5e484722c6f7abbe764126409494026216ad92`

Baseline: `a0b80c7d204cf9349a5f647ecbc58a8a37735e15`

## Evidence Summary

- The prerequisite emerald restoration was committed before this branch so the
  map starts from a clean IOSAC visual baseline.
- `git diff --name-status ad5e484722c6f7abbe764126409494026216ad92..HEAD --
  packages/ios-app` was used as the old-path source for deleted and renamed iOS
  paths.
- The old-path census found 848 deleted or renamed old iOS paths: 567 source
  paths, 266 tests, 2 docs, and 13 old `.claude/rules` paths.
- The inventory groups all old paths by user-facing affordance or structural
  evidence family; the static gate verifies every old path is covered.
- No Swift source, Xcode project, iOS DTO, server protocol, database migration,
  provider tool, or runtime feature was changed by this goal.

## Failed Attempts And Fixes

- Initial planning risk: treating old iOS directories as a simple Phase 1
  backlog would have mixed current shell plumbing with backend-dependent product
  panels. Fix: the inventory uses `phase1_local_native`,
  `phase1_server_fact`, `phase1_review_only`, `phase2_agent_execution`,
  `superseded_current_shell`, and `reject_candidate` classifications.
- Initial coverage risk: file-by-file TSV rows would be noisy and easy to
  review poorly. Fix: grouped rows are allowed only because the invariant checks
  each deleted or renamed old path against explicit coverage patterns.
- Phase 2 drift risk: deferring agent-loop work could lose the old parity
  backlog. Fix: the map includes a durable Phase 2 anchor and the invariant
  checks the full deferred bucket vocabulary.

## Validation Commands

| Command | Status | Notes |
| --- | --- | --- |
| `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture` | passed | 6 tests passed, including artifact wiring, score total, TSV vocabulary, 848 old-path coverage, Phase 2 anchor, and local/GitHub target parity. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture` | passed | 8 tests passed; pre-restoration backlog and absence guards remain intact. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test ios_self_adapting_agent_cockpit_baseline_invariants -- --nocapture` | passed | 11 tests passed; cockpit and emerald theme baseline remain intact. |
| `scripts/personal-info-guard.sh` | passed | Full scan reported no personal-info leaks in source. |
| `git diff --check` | passed | No whitespace errors. |
| `git ls-files -ci --exclude-standard` | passed | No ignored tracked files reported. |

## Handoff

The first recommended implementation slice after this map is
`phase1_slice_1`: chat composer affordance and menu sheet restoration. It
should present the old input bar, attachment, skills, prompt, and queue concepts
to the user as a first-principles review packet before any Swift changes are
made.
