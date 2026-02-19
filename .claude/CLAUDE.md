# Tron Project Guidelines

## Rules

1. **Code, tests, and docs ship together.** Every change must include updated tests and updated documentation in the same commit. Outdated docs and missing tests are bugs.
2. **Root cause fixes only.** Trace the real cause — no bandaid fixes.
3. **Use `@tron-db` skill** to investigate issues. Query `~/.tron/database/` directly — don't guess.
4. **Follow established patterns.** Read the relevant crate's `lib.rs` and `mod.rs` docs before implementing new features.

## Commands

```bash
# REQUIRED before completing any task
cd packages/agent && cargo build --release && cargo test --workspace

# iOS
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme TronMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Documentation

Path-scoped rules in `.claude/rules/` load automatically.

### Rust Agent (self-documenting)

The codebase uses progressive disclosure — documentation lives in the code:

- **Crate level**: `lib.rs` — purpose, dependencies, module overview
- **Module level**: `mod.rs` — submodule table, entry points, key invariants
- **File level**: `// INVARIANT:` markers for critical correctness constraints
- **Workspace overview**: `crates/tron-agent/src/main.rs`

### iOS App

- `packages/ios-app/docs/architecture.md` — SwiftUI, MVVM, coordinator, event plugins
- `packages/ios-app/docs/development.md` — Xcode setup, builds, testing
- `packages/ios-app/docs/events.md` — event plugin system
- `packages/ios-app/docs/apns.md` — push notification setup
