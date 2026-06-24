# Developer Experience / Repo Hygiene / Automation Evidence Manifest

This manifest records source-audit evidence, command evidence, and residual
risk for the current-lineage DXRHA slice. The branch is
`codex/developer-experience-repo-hygiene-automation-current`, based on
`485819810382db7f763196b8305426e1f3f8a839`. The older
`codex/developer-experience-repo-hygiene-automation` branch at `9ef779cf5` is
stale branch quarry-only evidence.

## Source Audit

| Surface | Evidence | Outcome |
| --- | --- | --- |
| Local closeout target list | `scripts/tron.d/quality.sh` contains `developer_experience_repo_hygiene_automation_invariants` before `primitive_trace_execution` and `integration`. | Local `scripts/tron ci test` includes the DXRHA target. |
| GitHub static gates | `.github/workflows/ci.yml` runs `cargo test --test developer_experience_repo_hygiene_automation_invariants -- --quiet` in the same position. | GitHub static gates mirror local closeout order. |
| Contributor CLI docs | `README.md`, `CONTRIBUTING.md`, and `.github/pull_request_template.md` describe `tron dev`, `tron dev --stop`, closeout checks, and manual-only deployment boundaries. | Contributor workflow is visible without chat history. |
| Generated iOS project | CI regenerates iOS with XcodeGen and checks `git diff --exit-code packages/ios-app/TronMobile.xcodeproj`. | The tracked iOS project remains drift-checked. |
| Generated Mac project | CI generates `TronMac.xcodeproj` and checks `git check-ignore -q packages/mac-app/TronMac.xcodeproj`. | The Mac project remains generated and ignored. |
| Mac helper path | `CONTRIBUTING.md` now matches `packages/mac-app/docs/development.md` and CI: helpers live under `Contents/Library/LoginItems/.../Contents/MacOS/tron`. | Stale `Contents/Resources/tron-agent` contributor guidance is removed. |
| Runtime state docs | README `~/.tron` tree and notes match `scripts/tron-lib.sh` seeding of profiles, workspace, memory, and internal runtime directories. | Runtime-state reset guidance is accurate. |
| Ignored artifacts | `.gitignore`, `packages/mac-app/.gitignore`, and the DXRHA invariant cover Rust targets, Xcode build output, `.xcresult`, DerivedData, script artifacts, Node modules, and helper binaries. | Tracked ignored files are guarded. |
| Version helpers | `.github/workflows/ci.yml`, `scripts/tron-version`, and `scripts/tron-release-notes` expose `version check`, `version test`, and release-notes self-test behavior. | Version/release helper drift is visible. |
| Branch handoff | Scorecard and inventory record current branch, stale branch quarantine, `git status --short`, and the rule that another thread can continue without chat history. | Remote pickup can start from durable artifacts. |

## Verification Log

| Command | Result | Notes |
| --- | --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | passed, exit 0 | Rust format gate for touched test code. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | passed, exit 0 | Workspace compile check; emitted the pre-existing 56 dead-code warnings. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test developer_experience_repo_hygiene_automation_invariants -- --nocapture` | passed, exit 0 | 10 DXRHA static/source-backed invariant tests passed; emitted the pre-existing 56 dead-code warnings. |
| `scripts/tron ci fmt check clippy test` | passed, exit 0 | Broad local Rust verification passed, including closeout target parity and the serial integration target. |
| `scripts/personal-info-guard.sh` | passed, exit 0 | Full personal-info guard reported no source leaks. |
| `scripts/tron version check` | passed, exit 0 | Version mirrors are in sync for `0.1.0-beta.7` / `v0.1` Beta 7. |
| `scripts/tron version test` | passed, exit 0 | Version helper self-tests passed. |
| `scripts/tron-release-notes --test` | passed, exit 0 | Release-notes helper self-test passed. |
| `cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | passed, exit 0 | iOS generated project drift check passed after iOS 26.5 simulator installation was confirmed. |
| `git diff --check` | passed, exit 0 | Whitespace hygiene passed. |
| `git ls-files -ci --exclude-standard` | passed, exit 0 | Tracked ignored-file audit returned no paths. |
| `git status --short` | passed, exit 0 | Pre-commit handoff showed only staged DXRHA changes in this worktree. |

## Residual Risk

The GitHub static-gates block still duplicates the local closeout target list by
design because GitHub needs explicit commands for readable failure output. DXRHA
reduces that risk by parsing both lists in the invariant and requiring exact
same-order parity. Release workflows remain manual/tag-triggered; DXRHA did not
change production deployment behavior.
