# Development

<!--
PURPOSE: Everything needed to develop, test, and deploy Tron.
AUDIENCE: Developers modifying the codebase.

AGENT MAINTENANCE:
- Update commands if scripts/tron changes
- Update port numbers if they change
- Add test cases when features are added
- Last verified: 2026-01-20
-->

## Commands

| Command | Purpose |
|---------|---------|
| `tron setup` | First-time project setup |
| `tron dev` | Build, test, start beta server |
| `tron deploy` | Build, test, deploy to production |
| `tron status` | Show service status |

## Setup

```bash
./scripts/tron setup
```

Installs Bun, dependencies, builds packages, creates config directories.

## Development Workflow

```bash
tron dev
```

Builds all packages, runs tests, starts beta server on:
- WebSocket: `localhost:8082`
- Health: `localhost:8083`

## Testing

```bash
bun run test           # Run all tests
bun run test:watch     # Watch mode
```

**Known Issue:** Vitest may fail 1 test file with heap memory error (pre-existing Vitest issue).

### Manual Test Sequence

```bash
# 1. Clean slate
rm -rf ~/.tron

# 2. Setup and start
./scripts/tron setup
tron dev

# 3. In another terminal
bun run dev:tui

# 4. Test interaction
"Hello, read the README.md file"

# 5. Test commands
/help
/context

# 6. Exit and verify
/exit
ls ~/.tron/db/
```

### Test Checklist

**Tools:**
- [ ] `read` returns file contents
- [ ] `write` creates files
- [ ] `edit` modifies files
- [ ] `bash` executes commands
- [ ] Dangerous commands blocked

**Sessions:**
- [ ] New session creates DB entry
- [ ] Resume works (`tron -c`)
- [ ] Graceful exit saves state

**Skills:**
- [ ] Load from `~/.tron/skills/`
- [ ] Load from `.claude/skills/`
- [ ] `@skill-name` reference works

## Production

### Initial Install

```bash
tron install
```

Creates launchd service, symlinks CLI to `~/.local/bin/tron`.

### Deploy Updates

```bash
git pull
tron deploy
```

Production runs on:
- WebSocket: `localhost:8080`
- Health: `localhost:8081`

### Service Management

```bash
tron status      # Status and health
tron start       # Start service
tron stop        # Stop service
tron restart     # Restart service
tron logs        # Query logs
tron rollback    # Revert to previous deploy
```

## Troubleshooting

### Port in Use

```bash
kill $(lsof -t -i :8082)
```

### Native Module Errors

```bash
cd node_modules/.bun/better-sqlite3@*/node_modules/better-sqlite3
rm -rf build
PYTHON=/opt/homebrew/bin/python3 npx node-gyp rebuild --release
```

### PATH Issues

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

## File Locations

| Location | Purpose |
|----------|---------|
| `~/.tron/db/` | SQLite databases |
| `~/.tron/skills/` | Global skills |
| `~/.tron/rules/` | Global context |
| `.claude/skills/` | Project skills |
| `.claude/AGENTS.md` | Project context |
