# Developer Experience / Repo Hygiene / Automation Inventory

This inventory maps contributor workflow surfaces that DXRHA depends on. It is
paired with `developer-experience-repo-hygiene-automation-inventory.tsv`, which
is machine-checked by
`developer_experience_repo_hygiene_automation_invariants`.

## Taxonomy

- `setup`: first-run and local home seeding paths.
- `dev_server`: `tron dev` foreground/background takeover and stop/resume flows.
- `local_ci`: local `scripts/tron ci` and focused helper commands.
- `github_ci`: GitHub Actions jobs, path filters, and explicit static gates.
- `static_gate`: Rust invariant targets that enforce workflow truth.
- `generated_project`: XcodeGen-owned project files and drift policy.
- `version_release`: version mirror and release-note helper checks.
- `personal_info_guard`: username, home-path, and secret leakage guards.
- `docs_upkeep`: README, CONTRIBUTING, PR template, and package docs.
- `predecessor_inventory`: older scorecard inventories that must classify new
  retained artifacts.
- `branch_handoff`: branch naming, stale branch quarantine, and status proof so
  another thread can continue without chat history.
- `ignored_artifact`: ignored build/cache/generated outputs and tracked ignored
  file checks.
- `tests`: focused invariant and platform test surfaces.
- `release_boundary`: deploy/manual-release boundary documentation and guards.

## Required Handoff Facts

- Current implementation branch:
  `codex/developer-experience-repo-hygiene-automation-current`.
- Base commit:
  `485819810382db7f763196b8305426e1f3f8a839`.
- Stale branch:
  `codex/developer-experience-repo-hygiene-automation` at `9ef779cf5`,
  quarry-only.
- Pickup command:
  `git status --short`.
- Local closeout target:
  `cargo test --manifest-path packages/agent/Cargo.toml --test developer_experience_repo_hygiene_automation_invariants -- --nocapture`.
- Broad closeout:
  `scripts/tron ci fmt check clippy test`,
  `scripts/personal-info-guard.sh`, version helper checks, release-note helper
  tests, XcodeGen drift check, `git diff --check`,
  `git ls-files -ci --exclude-standard`, and `git status --short`.

The durable TSV rows below are intentionally specific. They let another worker
or reviewer see what owns setup, dev-server takeover, CI parity, generated
project discipline, ignored artifacts, branch handoff, and docs upkeep without
reconstructing the chat.
