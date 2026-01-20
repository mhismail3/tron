# Testing Guide

<!--
PURPOSE: Testing checklist and procedures for QA.
AUDIENCE: Developers and QA testing Tron features.

AGENT MAINTENANCE:
- Update test procedures when features change
- Add new test cases for new features
- Keep file locations current
- Last verified: 2026-01-20
-->

## Running Tests

```bash
# Run all tests
bun run test

# Watch mode
bun run test:watch

# Single package
bun run test --filter @tron/core
```

**Known Issue:** Vitest may fail 1 test file with heap memory error. This is a pre-existing Vitest issue.

## Feature Test Checklist

### Authentication

- [ ] OAuth login flow completes
- [ ] Tokens saved to `~/.tron/auth.json`
- [ ] Token refresh works when expired
- [ ] Auth status command works
- [ ] Logout clears tokens

### Session Management

- [ ] New session creates database entry
- [ ] Session ID displayed in UI
- [ ] Resume latest session works (`tron -c`)
- [ ] Resume specific session works (`tron -r <id>`)
- [ ] Graceful exit saves state

### TUI Features

- [ ] Slash command menu appears on `/`
- [ ] Arrow keys navigate menu
- [ ] `/help` shows commands
- [ ] `/clear` clears messages
- [ ] History navigation (up/down)
- [ ] Streaming text displays
- [ ] Token counts update

### Tools

- [ ] `read` - Returns file contents with line numbers
- [ ] `write` - Creates new file
- [ ] `edit` - Modifies existing file
- [ ] `bash` - Executes commands
- [ ] `grep` - Finds content
- [ ] `find` - Locates files
- [ ] Dangerous commands blocked (`rm -rf /`)

### Skills

- [ ] Skills load from `~/.tron/skills/`
- [ ] Skills load from `.claude/skills/`
- [ ] `@skill-name` reference works
- [ ] Auto-inject skills included in context

### Context Loading

- [ ] Global context loads from `~/.tron/rules/`
- [ ] Project context loads from `.claude/` or `.tron/`
- [ ] `/context` shows loaded files

## Manual Test Sequence

```bash
# 1. Clean slate
rm -rf ~/.tron

# 2. Setup
./scripts/tron setup

# 3. Start dev server
tron dev

# 4. Start TUI (new terminal)
bun run dev:tui

# 5. Test basic interaction
"Hello, read the README.md file"
# Should stream response and read file

# 6. Test slash commands
/help
/context
/clear

# 7. Exit
/exit

# 8. Verify persistence
ls ~/.tron/db/

# 9. Resume
bun run dev:tui -- -c
# Should load previous messages
```

## File Locations Reference

| File | Location |
|------|----------|
| Auth tokens | `~/.tron/auth.json` |
| Settings | `~/.tron/settings.json` |
| Database | `~/.tron/db/prod.db` |
| Global skills | `~/.tron/skills/` |
| Global context | `~/.tron/rules/AGENTS.md` |
| Project context | `.claude/AGENTS.md` |
| Project skills | `.claude/skills/` |

## Hooks Testing

Create `.claude/hooks/pre-tool-use.ts`:

```typescript
export default {
  name: 'log-tools',
  type: 'PreToolUse',
  handler: async (context) => {
    console.log(`Tool: ${context.toolName}`);
    return { action: 'continue' };
  }
};
```

Verify hooks execute by watching console output.

## Error Handling

| Error | Test Method |
|-------|-------------|
| Auth error | Delete `~/.tron/auth.json`, run TUI |
| Network error | Disconnect network, send message |
| Rate limit | Send many rapid messages |

Errors should display in status bar and suggest fixes.
