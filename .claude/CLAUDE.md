# Tron Project Guidelines

## Rules

1. **Code, tests, and docs ship together.** Every change must include updated tests and updated documentation in the same commit. Outdated docs and missing tests are bugs.
2. **Root cause fixes only.** Trace the real cause — no bandaid fixes.
3. **Use `@self-inspect` skill** to investigate issues. Query `~/.tron/system/db/` directly — don't guess.
4. **Follow established patterns.** Read the relevant module's `mod.rs` docs before implementing new features.

## Commands

```bash
# REQUIRED before completing any task
cd packages/agent && cargo build --release && cargo test -- --quiet

# iOS
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme TronMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Settings Parity

Every server setting (`~/.tron/system/settings.json`) must have a 1-to-1 corresponding control in the iOS settings UI. When adding a new setting to the Rust agent (`settings/types/`), also add:
1. Decode in `RPCTypes+Settings.swift` (`ServerSettings`)
2. Update struct in `RPCTypes+Settings.swift` (`ServerSettingsUpdate`)
3. Property in `SettingsState.swift` (load, reset, build reset update)
4. UI control in the appropriate settings page (`Views/Settings/Pages/`)

No setting should exist only on the server or only in the iOS UI.

## Deployment

- **NEVER run `tron deploy`** — production deployments are manual-only by the user.
- Use `tron dev` variants to manage the beta server during development.
- You may run `tron dev`, `tron dev-build`, etc. but never `tron deploy` or any production deployment command.

## Documentation

Path-scoped rules in `.claude/rules/` load automatically.

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
- `packages/ios-app/docs/apns.md` — push notification setup

### Progressive Disclosure Upkeep

After completing work in any area, update the progressive disclosure docs for that area before finishing. Scale the effort to the current state:

- **Weak area** (stale `mod.rs`, missing submodule table, no invariants): Explore the surrounding modules, write a proper `mod.rs` doc block with submodule table, document key entry points and invariants. Look at neighboring modules too — if you're fixing `runtime/hooks/mod.rs`, glance at `runtime/agent/mod.rs` and `runtime/orchestrator/mod.rs`.
- **Strong area** (already has good docs): Just update based on your changes — add new modules to the submodule table, update invariants, adjust descriptions that your changes invalidated.

This is a standing task on every session, not a one-time effort. The goal is that the docs ratchet forward — every session leaves the area slightly better documented than it was found.
