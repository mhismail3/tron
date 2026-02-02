# Tron Project Guidelines

## CRITICAL: Documentation-First Approach

**Before undertaking ANY task related to this codebase, you MUST:**

1. **Read the relevant package documentation** to establish baseline understanding
2. **Consult path-scoped rules** when working on specific subsystems
3. **Update documentation** after any architectural changes (same commit as code)

These docs are the **living source of truth** for how the system works. They must be kept accurate.

---

## Package Documentation Index

### Agent Package (`packages/agent/docs/`)

| Document | Purpose | Read When |
|----------|---------|-----------|
| **architecture.md** | System overview, package structure, dependency flow, event sourcing, key patterns (registry, factory, component extraction) | Starting any agent work; understanding how components fit together |
| **api.md** | WebSocket protocol, RPC methods, event types, error codes, authentication | Working on client integration, RPC handlers, or debugging API issues |
| **customization.md** | Settings, skills, system prompts, context rules, hooks system | Implementing hooks, adding skills, modifying configuration |
| **development.md** | Setup, commands, testing, debugging, adding new components | Setting up dev environment, writing tests, adding features |
| **patterns.md** | Registry, factory, component extraction, type-safe enums, error hierarchy, fail-open patterns | Implementing new features; ensuring consistency with established patterns |

### iOS App Package (`packages/ios-app/docs/`)

| Document | Purpose | Read When |
|----------|---------|-----------|
| **architecture.md** | App structure, MVVM pattern, coordinator pattern, event plugin system, data flow | Starting any iOS work; understanding SwiftUI/state management |
| **development.md** | Xcode setup, build configurations, testing, debugging, common tasks | Setting up iOS dev environment, running tests, adding screens |
| **events.md** | Event plugin system, transformer, dispatch, adding new events | Working on event handling, adding new event types |
| **apns.md** | Push notification setup, Apple Developer config, troubleshooting | Setting up or debugging push notifications |

### Path-Scoped Rules

Rules in `.claude/rules/` load automatically when editing matching files:

| Rule | Applies To | Key Information |
|------|------------|-----------------|
| `packages/agent/.claude/rules/events.md` | Event store, message reconstruction | Event structure, reconstruction flow, truncation |
| `packages/agent/.claude/rules/tools.md` | Tool implementations | Adding tools, hook integration, known pitfalls |
| `packages/agent/.claude/rules/orchestrator.md` | Session management, turn execution | Lifecycle, event persistence, handlers |
| `packages/agent/.claude/rules/providers.md` | LLM providers | Adding providers, message conversion |
| `packages/agent/.claude/rules/subagents.md` | Sub-agent spawning | Coordination, state management |
| `packages/agent/.claude/rules/context.md` | Context loading, compaction | AGENTS.md loading, path-scoped rules |

---

## CRITICAL RULES - ALWAYS FOLLOW

### 1. Documentation Maintenance

**Docs are a living source of truth.** After ANY architectural change:

1. Update relevant documentation in the SAME commit as code changes
2. Check if path-scoped rules need updates
3. Run verification commands listed in rule files

**Never let docs drift from reality.** Outdated docs are worse than no docs.

### 2. Root Cause Analysis

**NEVER apply bandaid fixes.** When you find a bug, ALWAYS:

1. Analyze the code and trace call paths to identify the TRUE root cause
2. Understand WHY the bug exists, not just WHERE it manifests
3. Fix the underlying issue robustly, even if it requires more effort

### 3. Debugging with Database Logs

**Source of truth for all agent sessions is `$HOME/.tron/db/`**. The databases contain:
- `events` table: All session events (messages, tool calls, results)
- `logs` table: All application logs with timestamps and context

**ALWAYS use the `@tron-db` skill** (`.claude/skills/tron-db/`) when the user asks to investigate an issue. Query the database directly — do not guess.

### 4. Build & Test Verification

**ALWAYS run before completing any task:**
```bash
bun run build && bun run test
```
Do not mark work as complete until both succeed. If tests fail, fix them.

### 5. Test-Driven Development

**Prioritize zero regressions.** When making changes:

1. Write or update tests FIRST when adding features
2. Run existing tests BEFORE and AFTER changes
3. If refactoring, ensure test coverage exists before touching code
4. Never commit code that introduces test failures

### 6. Follow Established Patterns

Before implementing new features, read `packages/agent/docs/patterns.md` to understand:

- **Registry Pattern** - For centralized dispatch with validation
- **Factory Pattern** - For consistent object construction
- **Component Extraction** - For decomposing large classes
- **Type-Safe Enums** - For compile-time string validation
- **Typed Error Hierarchy** - For semantic error handling
- **Fail-Open** - For non-critical extension points

New code should follow these patterns for consistency.

---

## Quick Reference

### Commands

```bash
# Full build + test (REQUIRED before completing tasks)
bun run build && bun run test

# Agent-specific
bun run --cwd packages/agent build
bun run --cwd packages/agent test
bun run --cwd packages/agent typecheck

# iOS-specific
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme TronMobile -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

### Key File Locations

```
~/.tron/
├── db/                 # SQLite databases (source of truth)
├── auth.json           # API keys and OAuth tokens
├── settings.json       # User settings
└── skills/             # Global skills

packages/agent/
├── docs/               # Agent documentation (READ FIRST)
├── src/                # Source code
└── .claude/rules/      # Path-scoped rules (auto-loaded)

packages/ios-app/
├── docs/               # iOS documentation (READ FIRST)
├── Sources/            # Source code
└── .claude/rules/      # Path-scoped rules (auto-loaded)
```

### Database Queries

```bash
# Recent events for a session
sqlite3 ~/.tron/db/prod.db "SELECT sequence, type, substr(payload, 1, 100) FROM events WHERE session_id='sess_xxx' ORDER BY sequence"

# Recent sessions
sqlite3 ~/.tron/db/prod.db "SELECT id, status, model FROM sessions ORDER BY rowid DESC LIMIT 5"

# Application logs
sqlite3 ~/.tron/db/prod.db "SELECT timestamp, level, message FROM logs ORDER BY timestamp DESC LIMIT 20"
```
