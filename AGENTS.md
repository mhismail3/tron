# Tron Project Guidelines

## Rules

1. **Code, tests, and docs ship together.** Every change must include updated tests and updated documentation in the same commit. Outdated docs and missing tests are bugs.
2. **Keep `README.md` accurate.** The root `README.md` is the project's canonical reference and is wired up to drift quickly. Treat it like a load-bearing source file: see [README maintenance](#readme-maintenance) below for the specific cases that require an edit.
3. **Root cause fixes only.** Trace the real cause — no bandaid fixes.
4. **Use `@self-inspect` skill** to investigate issues. Query `~/.tron/internal/database/` directly — don't guess.
5. **Follow established patterns.** Read the relevant module's `mod.rs` docs before implementing new features.
6. **User info lives in `MEMORY.md`, secrets in vault.** Never hardcode personal info (names, emails, handles, domains) anywhere in code, tests, or skill docs. User-specific values belong in `~/.tron/memory/MEMORY.md` (auto-loaded into every session) or detail files under `~/.tron/memory/rules/`. Skill-owned secrets go in `~/.tron/workspace/vault/` through the `vault` skill; Tron-owned provider auth lives in `~/.tron/profiles/auth.json`. Regression-guarded by `workspace_has_no_personal_info_literals` in `packages/agent/src/shared/foundation/paths.rs`.

## Commands

```bash
# Default: run the smallest high-signal verification for the files you touched.
# Examples:
# - Rust implementation: cargo fmt --all -- --check && cargo check, plus targeted cargo test filters
# - iOS implementation: xcodegen generate, plus targeted xcodebuild tests for touched modules
# - Docs/rules-only edits: no build required; use git diff --check when useful

# Full Rust CI only for broad Rust/server changes, CI policy changes, or pre-commit checkpoints
scripts/tron ci fmt check clippy test

# iOS
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:<targeted-test>
```

Prefer fast, focused checks while iterating. Escalate to full suites when the change crosses module boundaries, alters shared contracts, touches release/build/test policy, or when a focused failure suggests wider risk.

## Settings Parity

Every server setting lives in profile TOML: managed defaults under `[settings]` in `~/.tron/profiles/default/profile.toml`, with sparse user overrides under `[settings]` in `~/.tron/profiles/user/profile.toml`. Each setting must have a 1-to-1 corresponding control in the iOS settings UI. When adding a new setting to the Rust agent (`settings/types/`), also add:
1. Decode in `Models/EngineProtocol/EngineProtocolTypes+Settings.swift` (`ServerSettings`)
2. Update struct in `Models/EngineProtocol/EngineProtocolTypes+Settings.swift` (`ServerSettingsUpdate`)
3. Property in `SettingsState.swift` (load, reset, build reset update)
4. UI control in the appropriate settings page (`Views/Settings/Pages/`)

No setting should exist only on the server or only in the iOS UI.

## Managed Skills

The primitive branch does not ship repo-managed first-party skills under
`packages/agent/skills/`. Do not reintroduce that directory, skill-copy wiring,
or built-in skill prompt context during the primitive teardown. Future skills
belong to a successor self-adapting-agent scorecard and must be agent-authored
state or generated runtime behavior, not bootstrap harness behavior.

## Deployment

- **NEVER run `tron deploy`** — production deployments are manual-only by the user.
- Use `tron dev` variants to manage the beta server during development.
- You may run `tron dev`, `tron ci`, etc. but never `tron deploy` or any production deployment command.

## Documentation

Path-scoped rules in `.Codex/rules/` load automatically.

### Rust Agent (self-documenting)

The codebase uses progressive disclosure — documentation lives in the code:

- **Library crate**: `packages/agent/src/lib.rs` — top-level module declarations
- **Module level**: `mod.rs` — submodule table, entry points, key invariants
- **File level**: `// INVARIANT:` markers for critical correctness constraints
- **Binary entry point**: `packages/agent/src/main.rs`

### iOS App

- `packages/ios-app/docs/architecture.md` — SwiftUI, MVVM, coordinator, event plugins
- `packages/ios-app/docs/development.md` — Xcode setup, builds, testing
- `packages/ios-app/docs/events.md` — event plugin system

### Progressive Disclosure Upkeep

After completing work in any area, update the progressive disclosure docs for that area before finishing. Scale the effort to the current state:

- **Weak area** (stale `mod.rs`, missing submodule table, no invariants): Explore the surrounding modules, write a proper `mod.rs` doc block with submodule table, document key entry points and invariants. Look at neighboring modules too — if you're fixing an agent runner module, glance at `domains/agent/mod.rs` and the relevant `domains/agent/runner/` module docs.
- **Strong area** (already has good docs): Just update based on your changes — add new modules to the submodule table, update invariants, adjust descriptions that your changes invalidated.

This is a standing task on every session, not a one-time effort. The goal is that the docs ratchet forward — every session leaves the area slightly better documented than it was found.

## README maintenance

The root `README.md` is the canonical project reference. Several sections are mechanically derived from code and **drift the moment you change the underlying source**. Whenever you touch any of the following, audit the matching README section in the same commit:

| You changed... | Update README section | Source-of-truth file |
|----------------|-----------------------|----------------------|
| `packages/agent/src/lib.rs` (top-level modules) | "Rust Modules" — both the tree and the table | `packages/agent/src/lib.rs` |
| `scripts/tron` dispatch table or any `cmd_*` function | "CLI Reference" | `scripts/tron` |
| `packages/agent/src/domains/tools/contract.rs` or tool implementation modules | "Tools" and "Engine Capabilities" | `packages/agent/src/domains/tools/` |
| Any domain `contract.rs` capability definition | "Engine Capabilities" and relevant domain docs | `packages/agent/src/domains/*/contract.rs` |
| `shared/protocol/events.rs` or session event payload modules | "Event System" — category and payload notes | `packages/agent/src/shared/protocol/events.rs`, `packages/agent/src/domains/session/event_store/types/` |
| `domains/settings/implementation/types/*.rs` (any field add/rename/default change) | "Settings" — `Key Configuration` JSON example | `packages/agent/src/domains/settings/implementation/types/` |
| `domains/auth/provider_credentials/` or `domains/model/providers/` | "Authentication" — provider table and precedence rules | `packages/agent/src/domains/auth/provider_credentials/`, `packages/agent/src/domains/model/providers/` |
| `domains/session/event_store/sqlite/migrations/*.sql` (new migration, table add/drop) | "Database Schema" — tables list | `packages/agent/src/domains/session/event_store/sqlite/migrations/` |
| `shared/foundation/paths.rs` (any new `dirs::*` constant or path helper) | "Install Directory" tree under Deployment | `packages/agent/src/shared/foundation/paths.rs` |
| `cmd_deploy` in `scripts/tron` | "Deployment → Deploy Pipeline" steps | `scripts/tron::cmd_deploy` |
| Adding/removing/renaming an iOS top-level `Sources/` directory | "iOS App → Architecture" tree | `packages/ios-app/Sources/` |

**Verification before commit**: when in doubt, grep the README for the symbol/path/method you changed and confirm every hit still matches reality. If a feature is being removed, also remove its README mention — do not leave aspirational or "planned" sections; they are indistinguishable from working code to a reader. The README's intro paragraph spells this out for the reader, and that promise is only true if every contributor honors it.

The current README was rewritten from scratch on 2026-04-09 to remove a substantial backlog of stale claims (a fictional 12-crate workspace, fictional embeddings/PARA/Memory subsystems, retired API method tables, and incorrect tool/CLI/event/setting/DB tables). Don't let it drift again.
