# Tron

**A persistent, dual-interface coding agent with memory-first architecture**

Tron is a production-quality AI coding agent that supports both terminal UI and chat interfaces as first-class citizens. It features sophisticated memory management for maintaining context across sessions, multi-model support, and a comprehensive hook system for extensibility.

## Features

- **Dual Interface**: Terminal UI for developers, web/mobile chat for everyone
- **Memory-First Architecture**: Four-level memory hierarchy with lossless context preservation
- **Always-On Service**: Runs persistently on your server for instant access
- **Multi-Model Support**: Claude (with Max OAuth), OpenAI, Google, and more
- **Comprehensive Hooks**: Lifecycle events for customization and automation
- **Productivity Tools**: Task tracking, inbox monitoring, notes integration

## Architecture

```
tron/
├── packages/
│   ├── core/       # Agent loop, memory, hooks, tools, providers
│   ├── server/     # WebSocket server for dual-interface support
│   ├── tui/        # Terminal user interface
│   └── chat-web/   # Web chat interface
├── docs/           # Documentation
│   └── skills.md   # Skills system guide
├── .tron/          # User configuration and data
│   ├── skills/     # Built-in and custom skills
│   ├── hooks/      # User-defined hooks
│   ├── sessions/   # Session persistence
│   └── memory/     # Episodic memory and learnings
└── thoughts/       # Session-scoped working memory
```

## Quick Start

**One-command setup:**

```bash
./scripts/setup.sh
```

This will:
- Check prerequisites (Node.js 20+)
- Install Bun if needed
- Install all dependencies
- Build all packages
- Create default configuration

**Manual setup:**

```bash
# Install Bun (if not already installed)
curl -fsSL https://bun.sh/install | bash

# Install dependencies and build
bun install
bun run build

# Start the TUI
bun run dev:tui

# Start the server (for chat interfaces)
bun run dev:server
```

**Why Bun?**
- ⚡ **3-6x faster** package installation than npm/pnpm/yarn
- 🗄️ **Built-in SQLite** (bun:sqlite) 3-6x faster than better-sqlite3
- 🚀 **Native TypeScript** support without transpilation
- 📦 **Workspace support** with automatic dependency resolution
- ✅ **Zero configuration** - works out of the box with monorepos

**Note:** This project uses Bun exclusively. The `preinstall` hook prevents accidental use of npm or yarn.

## Memory Architecture

Tron uses a four-level memory hierarchy:

1. **Immediate (In-Context)**: Current task, recent messages
2. **Session (Ledger)**: Goal, focus, decisions, working files
3. **Project (Handoffs)**: Past sessions with FTS5 search
4. **Global (Learnings)**: Cross-project patterns

The key insight: **Clear, don't compact**. Save state to a ledger, wipe context, resume fresh.

## Skills

Skills are reusable context packages that extend Tron's capabilities. Create a `SKILL.md` file with optional YAML frontmatter:

```markdown
---
autoInject: true
tags: [rules, typescript]
---
TypeScript coding standards for this project.

## Rules

- Use strict mode
- No `any` types
- Prefer `const` over `let`
```

**Locations:**
- `~/.tron/skills/` — Global skills (all projects)
- `.tron/skills/` — Project skills (override global)

**Usage:**
- Auto-inject skills (`autoInject: true`) are included in every prompt
- Reference skills explicitly with `@skill-name` in prompts

**Frontmatter options:**
| Option | Type | Description |
|--------|------|-------------|
| `autoInject` | boolean | Include in every prompt |
| `version` | string | Semantic version |
| `tools` | string[] | Associated tools |
| `tags` | string[] | Categorization tags |

See [docs/skills.md](docs/skills.md) for the complete guide.

## System Prompt Customization

Customize Tron's core identity and behavior using `SYSTEM.md` files:

**Locations:**
- `~/.tron/SYSTEM.md` — Global default prompt (all projects)
- `.tron/SYSTEM.md` — Project-specific prompt (overrides global)

**Priority:**
1. Programmatic `systemPrompt` parameter (highest)
2. Project `.tron/SYSTEM.md`
3. Global `~/.tron/SYSTEM.md`
4. Built-in default prompt (fallback)

**Example `SYSTEM.md`:**
```markdown
You are Tron, a specialized TypeScript assistant for this project.

You have access to these tools:
- read, write, edit: File operations
- bash: Execute commands
- grep, find: Search and discovery

Guidelines:
- Follow project's TypeScript strict mode
- Prefer composition over inheritance
- Write tests for all new features
```

**Best practices:**
- Keep prompts concise (<1000 tokens recommended)
- Focus on project-specific patterns and constraints
- Avoid redundant information (tools are described elsewhere)
- Update as project conventions evolve

## Development

This project uses **Bun** and follows strict Test-Driven Development:

```bash
# Run tests in watch mode
bun run test:watch

# Check types
bun run typecheck

# Check coverage
bun run test:coverage

# Lint code
bun run lint

# Clean build artifacts
bun run clean
```

### Working with workspace packages

```bash
# Build a specific package
cd packages/core && bun run build

# Run dev for a specific package
cd packages/tui && bun run dev

# Install a dependency to a specific package
bun add some-package --cwd packages/server
```

### Bun Performance Benefits

- **Installation**: 70% faster than pnpm, 3x faster than npm
- **Script execution**: Native binary execution without Node.js overhead
- **SQLite operations**: Use `bun:sqlite` for 3-6x faster database queries
- **TypeScript**: Direct execution without transpilation step

## Configuration

Create `~/.tron/settings.json`:

```json
{
  "model": "claude-sonnet-4-20250514",
  "providers": {
    "anthropic": {
      "auth": "oauth"
    }
  },
  "autoCompaction": false,
  "cleanupPeriodDays": 99999
}
```

## License

MIT

## Credits

Built on insights from:
- [pi-mono](https://github.com/badlogic/pi-mono) by Mario Zechner
- [Continuous-Claude-v2](https://github.com/parcadei/Continuous-Claude-v2)
- [Letta](https://docs.letta.com/)
- [AgentFS](https://github.com/tursodatabase/agentfs)
