# Tron Build & Deployment Guide

This guide covers the complete build pipeline for Tron, including three deployment tiers: Beta (development), Prod (personal production), and Public (release).

## Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Build Tiers](#build-tiers)
4. [Development Workflow](#development-workflow)
5. [Production Deployment](#production-deployment)
6. [Public Releases](#public-releases)
7. [Server Management](#server-management)
8. [Feature Flags](#feature-flags)
9. [Troubleshooting](#troubleshooting)

---

## Overview

Tron uses a 3-tier build system:

| Tier | Purpose | Features | Auto-Server |
|------|---------|----------|-------------|
| **Beta** | Development | All + debug tools | No |
| **Prod** | Personal use | All features | Yes |
| **Public** | Distribution | Stable only | Yes |

### Directory Structure

```
~/.tron/
├── install/
│   └── prod/           # Production installation
├── logs/               # Server logs
├── sessions/           # Session data
├── memory/             # Memory databases
└── settings.json       # User configuration

~/Downloads/projects/tron/
├── packages/           # Source packages
├── scripts/            # Build & deploy scripts
├── releases/           # Public release artifacts
└── .workspaces/        # Development workspaces
```

---

## Quick Start

### Development (Beta)

```bash
# Start development server
npm run dev

# Or use the full command
./scripts/dev.sh
```

### Production Deployment

```bash
# Build and deploy prod
npm run deploy

# Check status
npm run server:status
```

### Using tron-manage

The unified management CLI:

```bash
./scripts/tron-manage help         # Show all commands
./scripts/tron-manage dev          # Start development
./scripts/tron-manage deploy prod  # Deploy production
./scripts/tron-manage server status
```

---

## Build Tiers

### Beta (Development)

**Purpose**: Local development with hot-reload and full debugging.

```bash
# Start development
npm run dev

# With watch mode
./scripts/build.sh beta --watch

# Create a feature workspace
./scripts/dev.sh workspace feature-x
```

**Features enabled**:
- All experimental features
- Debug toolbar
- Performance profiling
- Hot-reload
- Source maps

**Environment**:
```bash
NODE_ENV=development
TRON_BUILD_TIER=beta
TRON_DEV=1
```

### Prod (Personal Production)

**Purpose**: Your personal production installation with all features.

```bash
# Build and install
npm run deploy

# Or manually
./scripts/build.sh prod --install
./scripts/deploy.sh prod install
```

**Features enabled**:
- All experimental features
- No debug toolbar
- No hot-reload
- Optimized builds

**Installation location**: `~/.tron/install/prod/`

**Binary location**: `~/.local/bin/tron`

### Public (Distribution)

**Purpose**: Public release for Homebrew or other distribution.

```bash
# Create release
npm run release

# With Homebrew formula
./scripts/tron-manage release --homebrew
```

**Features enabled**:
- Stable features only
- No experimental features
- Minified builds
- No source maps

**Output**: `releases/tron-X.X.X.tar.gz`

---

## Development Workflow

### Starting Development

```bash
# Quick start
npm run dev

# Equivalent to
./scripts/dev.sh start
```

### Development Workspaces

Create isolated workspaces for feature development:

```bash
# Create/switch to a workspace
./scripts/dev.sh workspace feature-auth

# List all workspaces
./scripts/dev.sh list

# Clean a workspace
./scripts/dev.sh clean -w feature-auth
```

Workspaces use git worktrees when possible, providing:
- Isolated branches
- Independent changes
- Easy switching

### Testing

```bash
# Run tests once
npm test

# Watch mode
npm run test:watch
./scripts/dev.sh test

# Type checking
npm run typecheck
./scripts/dev.sh typecheck
```

### Building

```bash
# Build all packages
npm run build

# Clean build
./scripts/build.sh beta --clean

# Build specific tier
./scripts/build.sh prod
./scripts/build.sh public
```

---

## Production Deployment

### First-Time Setup

```bash
# 1. Build and install
npm run deploy

# 2. Verify installation
tron --version
npm run server:status
```

### Upgrading

```bash
# Pull latest changes
git pull

# Rebuild and reinstall
./scripts/deploy.sh prod upgrade

# Or manually
npm run deploy
```

### Uninstalling

```bash
npm run deploy:uninstall

# Or
./scripts/deploy.sh prod uninstall
```

**Note**: This preserves `~/.tron` data. To fully remove:

```bash
npm run deploy:uninstall
rm -rf ~/.tron
```

---

## Public Releases

### Creating a Release

```bash
# 1. Ensure tests pass
npm test

# 2. Update version in package.json
# 3. Create release
npm run release
```

This creates:
- `releases/tron-X.X.X/` - Release directory
- `releases/tron-X.X.X.tar.gz` - Tarball
- `releases/tron-X.X.X.sha256` - Checksum

### Homebrew Formula

```bash
./scripts/tron-manage release --homebrew
```

Creates `releases/homebrew/tron.rb` with proper SHA256.

### Publishing

1. Push to GitHub
2. Create GitHub release with tarball
3. Update Homebrew tap with new formula

---

## Server Management

### Starting/Stopping

```bash
# Start server
npm run server:start

# Stop server
npm run server:stop

# Restart
./scripts/deploy.sh prod restart
```

### Status

```bash
npm run server:status
```

Shows:
- Binary installation status
- Service configuration
- Server running status
- Health check status

### Logs

```bash
# Tail logs
npm run server:logs

# Direct access
tail -f ~/.tron/logs/server-stderr.log
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

## Feature Flags

### Overview

Features are controlled per-tier:

```typescript
import { isFeatureEnabled, getBuildTier } from '@tron/core';

// Check tier
const tier = getBuildTier(); // 'beta' | 'prod' | 'public'

// Check feature
if (isFeatureEnabled('experimentalModelSwitcher')) {
  // Show model switcher
}
```

### Available Flags

| Feature | Beta | Prod | Public |
|---------|------|------|--------|
| `experimentalModelSwitcher` | ✓ | ✓ | ✗ |
| `experimentalMemory` | ✓ | ✓ | ✗ |
| `experimentalPlugins` | ✓ | ✓ | ✗ |
| `experimentalMultiAgent` | ✓ | ✓ | ✗ |
| `experimentalVoice` | ✓ | ✓ | ✗ |
| `debugToolbar` | ✓ | ✗ | ✗ |
| `performanceProfiling` | ✓ | ✗ | ✗ |
| `hotReload` | ✓ | ✗ | ✗ |

### Environment Overrides

```bash
# Force tier
TRON_BUILD_TIER=beta tron

# Force development mode
TRON_DEV=1 tron

# Force public mode
TRON_PUBLIC=1 tron
```

---

## Troubleshooting

### Build Issues

**TypeScript errors**:
```bash
npm run typecheck
# Fix errors, then rebuild
npm run build
```

**Clean rebuild**:
```bash
npm run clean
npm install
npm run build
```

### Server Issues

**Server won't start**:
```bash
# Check logs
npm run server:logs

# Check ports
lsof -i :8080
lsof -i :8081
```

**Port conflicts**:
```bash
# Use different ports
TRON_WS_PORT=9000 TRON_HEALTH_PORT=9001 tron --server
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

### Development Issues

**Hot reload not working**:
```bash
# Ensure using dev script
npm run dev

# Check NODE_ENV
echo $NODE_ENV  # Should be 'development'
```

**Workspace issues**:
```bash
# List worktrees
git worktree list

# Clean broken workspace
./scripts/dev.sh clean -w broken-workspace
```

---

## Command Reference

### npm Scripts

| Command | Description |
|---------|-------------|
| `npm run dev` | Start development server |
| `npm run build` | Build all packages |
| `npm run build:prod` | Build production |
| `npm run build:public` | Build public release |
| `npm run deploy` | Deploy production |
| `npm run deploy:uninstall` | Remove installation |
| `npm run server:start` | Start server |
| `npm run server:stop` | Stop server |
| `npm run server:status` | Show status |
| `npm run server:logs` | Tail logs |
| `npm run release` | Create public release |
| `npm run manage` | Open tron-manage CLI |

### tron-manage Commands

```bash
./scripts/tron-manage dev              # Development
./scripts/tron-manage dev workspace X  # Create workspace
./scripts/tron-manage dev list         # List workspaces
./scripts/tron-manage build            # Build beta
./scripts/tron-manage build prod       # Build prod
./scripts/tron-manage build public     # Build public
./scripts/tron-manage deploy           # Deploy prod
./scripts/tron-manage deploy uninstall # Uninstall
./scripts/tron-manage server start     # Start server
./scripts/tron-manage server stop      # Stop server
./scripts/tron-manage server status    # Show status
./scripts/tron-manage release          # Create release
./scripts/tron-manage release --homebrew  # With formula
```
