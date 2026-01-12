# Migration to Bun

This document outlines the comprehensive migration from pnpm to Bun completed on 2026-01-12.

## What Changed

### Package Manager
- **Before**: pnpm with pnpm-workspace.yaml
- **After**: Bun with native workspace support in package.json

### Performance Improvements
- **Installation**: 70% faster than pnpm, 3x faster than npm
- **SQLite**: Bun's built-in `bun:sqlite` is 3-6x faster than better-sqlite3
- **TypeScript**: Native execution without transpilation overhead

### File Changes

#### Added
- `scripts/build-workspace.sh` - Robust build script for all workspace packages
- `bun.lockb` - Bun's binary lockfile (faster, more reliable)

#### Removed
- `.npmrc` - No longer needed (Bun doesn't use npm config)
- `pnpm-workspace.yaml` - Replaced by package.json workspaces field
- `pnpm-lock.yaml` - Replaced by bun.lockb

#### Modified
- `package.json` - Updated packageManager, workspaces, and all scripts
- `scripts/setup.sh` - Auto-installs Bun, uses Bun commands
- `README.md` - Updated documentation with Bun instructions

## Setup on a New Machine

**One command:**
```bash
./scripts/setup.sh
```

Or manually:
```bash
# Install Bun
curl -fsSL https://bun.sh/install | bash

# Install dependencies
bun install

# Build all packages
bun run build
```

## Command Equivalents

| pnpm command | Bun command |
|--------------|-------------|
| `pnpm install` | `bun install` |
| `pnpm add <pkg>` | `bun add <pkg>` |
| `pnpm run <script>` | `bun run <script>` |
| `pnpm --filter @pkg run build` | `cd packages/pkg && bun run build` |
| `pnpm store prune` | Automatic - Bun manages cache |

## Future Considerations

### Better-sqlite3
The project still uses `better-sqlite3` for Node.js compatibility. Consider migrating to Bun's native `bun:sqlite` API for better performance:

```typescript
// Current (works with Node.js and Bun)
import Database from 'better-sqlite3';

// Future (Bun-only, 3-6x faster)
import { Database } from 'bun:sqlite';
```

## Verification

Test the complete setup:
```bash
# Clean slate
bun run clean

# Fresh install
bun install

# Build
bun run build

# Run tests
bun test

# Start dev server
bun run dev:tui
```

## Rollback

If needed, revert to pnpm:
```bash
git revert HEAD
npm install -g pnpm
pnpm install
```

## Sources

- [Bun Workspaces Documentation](https://bun.com/docs/pm/workspaces)
- [Bun SQLite Documentation](https://bun.com/docs/runtime/sqlite)
- [Bun Filter CLI](https://bun.com/docs/pm/filter)
- [Package Manager Comparison 2026](https://dev.to/pockit_tools/pnpm-vs-npm-vs-yarn-vs-bun-the-2026-package-manager-showdown-51dc)
