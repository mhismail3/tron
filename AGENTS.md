# Tron Project Guidelines

## Rules

1. **Code, tests, and docs ship together.** Every change must include updated tests and updated documentation in the same commit. Outdated docs and missing tests are bugs.
2. **Keep the documentation hierarchy accurate.** The root `README.md` is the concise project front door. Detailed, source-backed behavior belongs in the technical reference and concern-owned docs: see [Documentation maintenance](#documentation-maintenance) below.
3. **Root cause fixes only.** Trace the real cause — no bandaid fixes.
4. **Use `@self-inspect` skill** to investigate issues. Query `~/.tron/internal/database/` directly — don't guess.
5. **Follow established patterns.** Read the relevant module's `mod.rs` docs before implementing new features.
6. **User info lives in `MEMORY.md`, secrets in vault.** Never hardcode personal info (names, emails, handles, domains) anywhere in code, tests, or skill docs. User-specific values belong in `~/.tron/memory/MEMORY.md` (auto-loaded into every session) or detail files under `~/.tron/memory/rules/`. Skill-owned secrets go in `~/.tron/workspace/vault/` through the `vault` skill; Tron-owned provider auth lives in `~/.tron/profiles/auth.json`. Regression-guarded by `workspace_has_no_personal_info_literals` in `packages/agent/src/shared/foundation/paths/`.

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

Every server setting lives in profile TOML: managed defaults under `[settings]` in `~/.tron/profiles/default/profile.toml`, with sparse user overrides under `[settings]` in `~/.tron/profiles/user/profile.toml`. Each setting must have a 1-to-1 corresponding control in the iOS settings UI. When adding a new setting to the Rust agent (`packages/agent/src/domains/settings/profile/types/`), also add:
1. Decode in `packages/ios-app/Sources/Engine/Protocol/Settings/EngineProtocolTypes+Settings.swift` (`ServerSettings`)
2. Update struct in `packages/ios-app/Sources/Engine/Protocol/Settings/EngineProtocolTypes+Settings.swift` (`ServerSettingsUpdate`)
3. Property in `packages/ios-app/Sources/Session/Chat/State/SettingsState.swift` (load, reset, build reset update)
4. UI control in the appropriate settings page (`packages/ios-app/Sources/UI/Settings/Pages/`)

No setting should exist only on the server or only in the iOS UI.

## Managed Skills

The primitive branch does not ship repo-managed first-party skills under
`packages/agent/skills/`. Do not reintroduce that directory, skill-copy wiring,
or built-in skill prompt context. Future skills must be agent-authored state or
generated runtime behavior with a source-owned contract, not bootstrap harness
behavior.

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

## Documentation maintenance

Documentation follows progressive disclosure:

1. `README.md` is the short GitHub front door: product purpose, system shape,
   quick start, primary validation, and links onward. Keep it under 250 lines.
2. `packages/agent/docs/project-reference.md` is the detailed cross-cutting
   reference for CLI, capabilities, protocol, events, settings, auth, storage,
   installation, and release behavior.
3. Rust `mod.rs` docs, iOS/Mac architecture docs, source contracts, migrations,
   and tests are the implementation-level truth.
4. Git history records completed audits. Current claims must live with their
   source owner, owning documentation, or focused boundary tests.

Whenever you touch a source-backed surface, update its owning docs in the same
commit:

| You changed... | Update... |
|----------------|-----------|
| Product purpose, supported clients, setup, or primary developer workflow | `README.md` |
| Rust module ownership | the nearest `mod.rs`; update `project-reference.md` only if the cross-cutting architecture changed |
| CLI commands | `scripts/tron --help`, command-owning docs/comments, `CONTRIBUTING.md` when contributor workflow changes, and `project-reference.md` |
| Capability contracts or provider-visible operations | domain contract docs and tests, plus `project-reference.md` when the public model surface changes |
| Events, settings, auth, database schema, paths, installation, or release behavior | the source-owning docs/tests and the matching `project-reference.md` section |
| iOS or Mac top-level architecture | the package architecture docs; update the root README only when the product-level map changes |

Canonical source roots include
`packages/agent/src/domains/settings/profile/types/`,
`packages/agent/src/domains/auth/credentials/`,
`packages/agent/src/shared/protocol/events/`, and
`packages/agent/src/shared/foundation/paths/`.

Do not turn the root README back into generated API documentation, a file tree,
an audit ledger, or a release runbook. Link to the durable owner instead. If a
feature is removed, remove its active documentation in the same commit.
