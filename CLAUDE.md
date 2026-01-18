# Tron Project Guidelines

## Native Module Issues (better-sqlite3)

This project uses `better-sqlite3` which requires native compilation. There's a known issue where bun's node-gyp may pick up the wrong Node.js version.

### Symptoms
- Tests fail with: `NODE_MODULE_VERSION X. This version of Node.js requires NODE_MODULE_VERSION Y`
- The mismatch happens when Homebrew's Node.js is used for compilation but nvm's Node.js runs the tests

### Fix
Rebuild better-sqlite3 with the correct Node.js (the one from nvm):

```bash
cd node_modules/.bun/better-sqlite3@11.10.0/node_modules/better-sqlite3
rm -rf build
PATH="/Users/moose/.nvm/versions/node/v24.12.0/bin:/opt/homebrew/bin:/usr/bin:/bin" \
  PYTHON=/opt/homebrew/bin/python3 \
  /Users/moose/.nvm/versions/node/v24.12.0/bin/npx node-gyp rebuild --release
```

### Prevention
When running `bun install --force`, set PATH to prioritize nvm's node:
```bash
PYTHON=/opt/homebrew/bin/python3 PATH="/Users/moose/.nvm/versions/node/v24.12.0/bin:/opt/homebrew/bin:/usr/bin:/bin:/Users/moose/.bun/bin" bun install --force
```

## Testing

### Run all tests
```bash
bun run test
```

### Known Issues
- Vitest has a pre-existing memory issue that may cause 1 test file to fail with "Worker terminated due to reaching memory limit: JS heap out of memory". This is a known issue and not related to code changes.

## Project Structure

- `packages/core` - Core event system, SQLite storage, types, sub-agent tools
- `packages/server` - EventStoreOrchestrator, tools, agent orchestration
- `packages/tui` - Terminal UI and CLI
- `packages/chat-web` - Web chat interface
- `packages/ios-app` - iOS application

## Database Migrations

Schema migrations are in `packages/core/src/events/sqlite/migrations/versions/`. When adding new columns:
1. Add to the base schema in `v001-initial.ts` for fresh databases
2. Create incremental migration for existing databases if needed

## Key Sub-Agent Files

- `packages/core/src/subagents/subagent-tracker.ts` - Tracks sub-agents and manages pending results
- `packages/core/src/tools/spawn-subsession.ts` - In-process spawning
- `packages/core/src/tools/spawn-tmux-agent.ts` - Out-of-process spawning
- `packages/core/src/tools/query-subagent.ts` - Querying sub-agent state
- `packages/core/src/tools/wait-for-subagent.ts` - Blocking wait for completion
- `packages/server/src/event-store-orchestrator.ts` - Orchestrates sub-agent lifecycle

See `~/.tron/CLAUDE.md` for sub-agent usage documentation.
