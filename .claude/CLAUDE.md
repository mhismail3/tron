# Tron Project Guidelines

## Rules

1. **Code, tests, and docs ship together.** Every change must include updated tests and updated documentation in the same commit. Outdated docs and missing tests are bugs.
2. **Root cause fixes only.** Trace the real cause — no bandaid fixes.
3. **Use `@tron-db` skill** to investigate issues. Query `~/.tron/db/` directly — don't guess.
4. **Follow established patterns.** Read `packages/agent/docs/patterns.md` before implementing new features.
5. **NEVER use `bun test`** — it invokes Bun's built-in runner, not vitest. ALWAYS use `bun run test`.

## Commands

```bash
# REQUIRED before completing any task
bun run build && bun run test

# Agent only
bun run --cwd packages/agent build
bun run --cwd packages/agent test
bun run --cwd packages/agent typecheck

# iOS
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme TronMobile -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

## Documentation

Read the relevant docs before working on a subsystem. Path-scoped rules in `.claude/rules/` load automatically.

- `packages/agent/docs/architecture.md` — system overview, event sourcing, package structure
- `packages/agent/docs/api.md` — WebSocket protocol, RPC methods, error codes
- `packages/agent/docs/customization.md` — settings, skills, prompts, hooks
- `packages/agent/docs/development.md` — setup, testing, debugging
- `packages/agent/docs/patterns.md` — registry, factory, type-safe enums, error hierarchy
- `packages/ios-app/docs/architecture.md` — SwiftUI, MVVM, coordinator, event plugins
- `packages/ios-app/docs/development.md` — Xcode setup, builds, testing
- `packages/ios-app/docs/events.md` — event plugin system
- `packages/ios-app/docs/apns.md` — push notification setup
