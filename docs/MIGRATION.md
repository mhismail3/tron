# Bun Migration

<!--
PURPOSE: Documents the migration from pnpm to Bun (completed 2026-01-12).
AUDIENCE: Developers who need to understand why Bun and how to use it.

AGENT MAINTENANCE:
- This is a historical record, update only if Bun usage patterns change
- Last verified: 2026-01-20
-->

## Summary

Tron uses Bun as its package manager and runtime. Migration from pnpm completed 2026-01-12.

## Why Bun

- **70% faster** package installation than pnpm
- **Native TypeScript** execution without transpilation
- **Built-in SQLite** (3-6x faster than better-sqlite3, future consideration)

## Command Reference

| pnpm | Bun |
|------|-----|
| `pnpm install` | `bun install` |
| `pnpm add <pkg>` | `bun add <pkg>` |
| `pnpm run <script>` | `bun run <script>` |
| `pnpm --filter @pkg build` | `cd packages/pkg && bun run build` |

## Setup

```bash
# One command setup
./scripts/tron setup

# Or manually
curl -fsSL https://bun.sh/install | bash
bun install
bun run build
```

## Verification

```bash
bun run clean
bun install
bun run build
bun run test
```

## Notes

- Lock file is `bun.lockb` (binary, faster)
- Workspaces defined in root `package.json`
- Still using `better-sqlite3` for Node.js compatibility
