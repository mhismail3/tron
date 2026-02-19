# Tron Project Guidelines

## Rules

1. **Code, tests, and docs ship together.** Every change must include updated tests and updated documentation in the same commit. Outdated docs and missing tests are bugs.
2. **Root cause fixes only.** Trace the real cause — no bandaid fixes.
3. **Use `@tron-db` skill** to investigate issues. Query `~/.tron/database/` directly — don't guess.
4. **Follow established patterns.** Read `packages/agent/docs/` before implementing new features.

## Commands

```bash
# REQUIRED before completing any task
cd packages/agent && cargo build --release && cargo test --workspace

# iOS
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme TronMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Documentation

Read the relevant docs before working on a subsystem. Path-scoped rules in `.claude/rules/` load automatically.

- `packages/agent/docs/architecture.md` — Rust server architecture
- `packages/ios-app/docs/architecture.md` — SwiftUI, MVVM, coordinator, event plugins
- `packages/ios-app/docs/development.md` — Xcode setup, builds, testing
- `packages/ios-app/docs/events.md` — event plugin system
- `packages/ios-app/docs/apns.md` — push notification setup
