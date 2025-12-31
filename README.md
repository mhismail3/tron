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
├── .tron/          # User configuration and data
│   ├── skills/     # Built-in and custom skills
│   ├── hooks/      # User-defined hooks
│   ├── sessions/   # Session persistence
│   └── memory/     # Episodic memory and learnings
└── thoughts/       # Session-scoped working memory
```

## Quick Start

```bash
# Install dependencies
npm install

# Build all packages
npm run build

# Run tests
npm test

# Start the TUI
npm run dev:tui

# Start the server (for chat interfaces)
npm run dev:server
```

## Memory Architecture

Tron uses a four-level memory hierarchy:

1. **Immediate (In-Context)**: Current task, recent messages
2. **Session (Ledger)**: Goal, focus, decisions, working files
3. **Project (Handoffs)**: Past sessions with FTS5 search
4. **Global (Learnings)**: Cross-project patterns

The key insight: **Clear, don't compact**. Save state to a ledger, wipe context, resume fresh.

## Development

This project follows strict Test-Driven Development:

```bash
# Run tests in watch mode
npm run test:watch

# Check types
npm run typecheck

# Check coverage
npm run test:coverage
```

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
