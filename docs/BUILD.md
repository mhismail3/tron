# Build & Deployment

<!--
PURPOSE: How to build, develop, and deploy Tron.
AUDIENCE: Developers working on or deploying Tron.

AGENT MAINTENANCE:
- Update port numbers if they change in scripts/tron
- Update command names if CLI commands change
- Keep troubleshooting section current with real issues
- Last verified: 2026-01-20
-->

## Quick Reference

| Command | Purpose |
|---------|---------|
| `tron dev` | Build, test, start beta server (ports 8082/8083) |
| `tron deploy` | Build, test, deploy to production |
| `tron setup` | First-time project setup |
| `tron status` | Show service status |

## First-Time Setup

```bash
./scripts/tron setup
```

This installs Bun, dependencies, builds all packages, and creates config directories.

## Development

```bash
tron dev
```

Builds all packages, runs tests, and starts the beta server. The beta server runs on:
- WebSocket: `localhost:8082`
- Health: `localhost:8083`

Environment: `NODE_ENV=development`, `LOG_LEVEL=trace`

## Production

### Initial Installation

```bash
tron install
```

Creates launchd service, symlinks CLI to `~/.local/bin/tron`, installs to `~/.tron/app/`.

### Deploying Updates

```bash
git pull
tron deploy
```

Builds, tests, and hot-swaps the production server. Ports:
- WebSocket: `localhost:8080`
- Health: `localhost:8081`

### Rollback

```bash
tron rollback
```

Reverts to the previously deployed commit.

## Service Management

```bash
tron status      # Service status and health
tron start       # Start service
tron stop        # Stop service
tron restart     # Restart service
tron logs        # Query logs (-l error, -n 100, -q "search")
tron errors      # Recent errors
tron uninstall   # Remove service (preserves data)
```

## Directory Structure

```
~/.tron/
├── app/          # Production installation
├── db/           # SQLite databases (prod.db, beta.db)
├── logs/         # Server logs
├── sessions/     # Session data
├── skills/       # User-defined skills
└── settings.json # Configuration
```

## Troubleshooting

### Port Already in Use

```bash
kill $(lsof -t -i :8082)
```

### Native Module Errors

If you see `NODE_MODULE_VERSION` mismatch:

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

## npm Scripts

| Script | Purpose |
|--------|---------|
| `bun run build` | Build all packages |
| `bun run test` | Run tests |
| `bun run clean` | Clean build artifacts |
| `bun run typecheck` | Type check |
