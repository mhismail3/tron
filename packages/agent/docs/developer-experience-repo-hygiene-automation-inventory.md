# Developer Experience Repo Hygiene Automation Inventory

Status: Complete

Base commit audited: `3cec727e19505aa4c58a18bcc4e54560c6829cce`

Branch audited: `codex/developer-experience-repo-hygiene-automation`

Machine-readable inventory: `packages/agent/docs/developer-experience-repo-hygiene-automation-inventory.tsv`

This inventory was built before DXRHA source edits. It covers the contributor
workflow surfaces named by the original hardening slice: setup, dev server,
tests, generated projects, docs, inventories, ignored-file hygiene, static
gates, branch/worktree handoff, and production automation safety.

## Surface Classes

| Class | Meaning |
|---|---|
| `cli_dispatch` | User-facing shell command dispatch, help, and subcommand modules. |
| `local_gate` | Local checks run by contributor commands or hooks. |
| `github_gate` | GitHub Actions jobs, path filters, release checks, or PR metadata. |
| `generated_artifact` | Generated-but-tracked or generated-but-ignored project files and mirrors. |
| `repo_hygiene` | Ignore policy, tracked ignored files, stale build/cache outputs, and local runtime boundaries. |
| `docs_workflow` | README, CONTRIBUTING, and platform workflow docs used by contributors. |
| `handoff` | Branch, worktree, remote pickup, and Codex local action assumptions. |
| `safety_boundary` | Production deploy, LaunchAgent, SMAppService, and `~/.tron` reset boundaries. |
| `dxrha_artifact` | This slice's scorecard, evidence, inventory, and invariant target. |

## Findings

- Baseline status was clean and the branch pointed at
  `3cec727e19505aa4c58a18bcc4e54560c6829cce`.
- `git ls-files -ci --exclude-standard` returned no tracked ignored files at
  inventory time.
- iOS XcodeGen output is tracked under `packages/ios-app/TronMobile.xcodeproj`
  and must be drift-checked with `xcodegen generate` plus `git diff --exit-code`.
- Mac XcodeGen output is intentionally ignored; CI checks that
  `packages/mac-app/TronMac.xcodeproj` exists after generation and remains
  ignored instead of drift-checking a tracked project.
- `scripts/tron.d/quality.sh` and `.github/workflows/ci.yml` currently own the
  same named Rust closeout target set, with serial handling for the integration
  test.
- The active contributor docs had two stale workflow claims at inventory time:
  `CONTRIBUTING.md` documented `scripts/tron dev stop` even though the CLI
  accepts `scripts/tron dev --stop`, and described `packages/mac-app` as
  "lands in Phase 5" even though the Mac wrapper is active source.
- Production automation stayed bounded at inventory time: no `tron deploy`
  dispatcher exists, automatic deploy watcher files are absent, and CI does not
  run `manual-deploy`, `tron install`, or production LaunchAgent mutation paths.

## Closeout Policy

DXRHA may tighten workflow docs, script help, static gates, inventories, and CI
target wiring. It must not add server APIs, public `/engine` surfaces, provider
features, scheduler/autostart behavior, product panels, repo-managed
`packages/agent/skills/`, production deploy automation, or new LaunchAgent /
SMAppService ownership paths.
