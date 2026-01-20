# Tron Build & Deployment Guide

This guide covers the build pipeline for Tron with two deployment modes: Beta (development) and Prod (production).

## Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Development (Beta)](#development-beta)
4. [Production Deployment](#production-deployment)
5. [Server Management](#server-management)
6. [Troubleshooting](#troubleshooting)

---

## Overview

Tron uses a unified CLI (`tron`) for all development and production workflows:

| Command | Purpose |
|---------|---------|
| `tron dev` | Build, test, start beta development server |
| `tron deploy` | Build, test, deploy to production |
| `tron install` | Initial production setup (launchd + CLI) |
| `tron rollback` | Restore to last deployed commit |
| `tron setup` | First-time project environment setup |

### Directory Structure

```
~/.tron/
├── app/                # Production installation
├── db/                 # SQLite databases (prod.db, beta.db)
├── logs/               # Server logs
├── sessions/           # Session data
├── memory/             # Memory databases
├── skills/             # User-defined skills
└── settings.json       # User configuration

~/Downloads/projects/tron/
├── packages/           # Source packages
├── scripts/
│   └── tron            # Unified CLI
└── ...
```

---

## Quick Start

### First-Time Setup

```bash
tron setup
```

### Development

```bash
tron dev
```

### Production

```bash
tron deploy
```

---

## Development (Beta)

**Purpose**: Local development with hot-reload and full debugging.

```bash
tron dev
```

This command:
1. Checks if beta port (8082) is already in use
2. Builds all workspace packages
3. Runs tests (prompts to continue on failure)
4. Checks/rebuilds native modules if needed
5. Starts the beta server

**Features enabled**:
- All experimental features
- Debug toolbar
- Hot-reload
- Source maps

**Environment**:
```bash
NODE_ENV=development
TRON_BUILD_TIER=beta
LOG_LEVEL=trace
```

**Ports**:
- Server: 8082
- Health: 8083

---

## Production Deployment

**Purpose**: Your personal production installation with all features.

### First-Time Setup

```bash
tron install
```

This creates:
- launchd service (auto-starts on login)
- CLI symlink at `~/.local/bin/tron`
- Production bundle at `~/.tron/app/`

### Deploying Updates

```bash
# Pull latest changes
git pull

# Rebuild and deploy
tron deploy
```

### Rollback

```bash
tron rollback
```

### Commands Summary

```bash
tron dev        # Build, test, start beta server
tron deploy     # Build, test, deploy to production
tron install    # Initial setup (launchd + CLI)
tron rollback   # Restore previous version
tron setup      # First-time project setup
```

**Installation location**: `~/.tron/app/`

**Binary location**: `~/.local/bin/tron`

**Ports**:
- Server: 8080
- Health: 8081

---

## Server Management

Use the `tron` CLI for all management tasks:

```bash
tron status     # Show service status and health
tron start      # Start production service
tron stop       # Stop production service
tron restart    # Restart production service
tron logs       # Query database logs
tron errors     # Show recent errors
tron uninstall  # Remove service (preserves data)
```

### Status

```bash
tron status
```

Shows:
- Production service status (running/stopped)
- Beta server status
- Health check status
- Deployed commit
- Service uptime

### Logs

```bash
# Query database logs (default: last 50)
tron logs

# Filter by level
tron logs -l error
tron logs -l warn -n 100

# Search logs
tron logs -q "connection"

# Filter by session
tron logs -s abc123

# Tail file logs
tron logs -t

# Query beta logs
tron logs beta -l info

# Write to file
tron logs -o errors.txt -l error
```

### Auto-Start (launchd)

Production installs auto-start on login via launchd:

```bash
# View service
launchctl list | grep tron

# Manual control
launchctl load ~/Library/LaunchAgents/com.tron.server.plist
launchctl unload ~/Library/LaunchAgents/com.tron.server.plist
```

---

## Troubleshooting

### Build Issues

**TypeScript errors**:
```bash
bun run typecheck
# Fix errors, then rebuild
bun run build
```

**Clean rebuild**:
```bash
bun run clean
bun install
bun run build
```

### Server Issues

**Server won't start**:
```bash
# Check logs
tron logs -l error

# Check ports
lsof -i :8080
lsof -i :8081
```

**Port conflicts**:
```bash
# Use different ports
TRON_WS_PORT=9000 TRON_HEALTH_PORT=9001 tron --server
```

**Beta server already running**:
```bash
# Kill existing beta server
kill $(lsof -t -i :8082)
```

### Installation Issues

**Binary not found**:
```bash
# Check PATH
echo $PATH | grep -q '.local/bin' || echo 'Add ~/.local/bin to PATH'

# Add to shell profile
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

**Permission denied**:
```bash
chmod +x ~/.local/bin/tron
```

### Native Module Issues

If you see `NODE_MODULE_VERSION` errors:

```bash
# The tron CLI handles this automatically, but you can force rebuild:
cd node_modules/.bun/better-sqlite3@*/node_modules/better-sqlite3
rm -rf build
PYTHON=/opt/homebrew/bin/python3 npx node-gyp rebuild --release
```

---

## npm Scripts Reference

| Command | Description |
|---------|-------------|
| `bun run build` | Build all packages |
| `bun run test` | Run tests |
| `bun run typecheck` | Type check |
| `bun run clean` | Clean build artifacts |
| `bun run dev:server` | Start dev server |
| `bun run dev:tui` | Start dev TUI |
| `bun run dev:chat` | Start dev chat web |

## CLI Reference

```
tron <command> [options]

Development Commands:
  dev        Build, test, and start beta development server
  setup      First-time project environment setup

Production Commands:
  deploy     Build, test, and deploy to production
  install    Initial production setup (launchd + CLI)
  rollback   Restore to last deployed commit

Service Commands:
  status     Show service status and health
  start      Start production service
  stop       Stop production service
  restart    Restart production service
  logs       Query database logs (use -h for options)
  errors     Show recent errors
  uninstall  Remove service (preserves data)

Ports:
  Production: WS 8080, Health 8081
  Beta:       WS 8082, Health 8083
```
