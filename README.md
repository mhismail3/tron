# Tron

**A persistent, event-sourced AI coding agent with multi-client architecture**

Tron is an AI coding agent that runs as a persistent service, supporting multiple client interfaces (terminal, web, iOS). It features event-sourced session persistence, multi-model support, sub-agent spawning, and a comprehensive hook system.

## Table of Contents

- [Features](#features)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Packages](#packages)
- [Tools](#tools)
- [Event System](#event-system)
- [Customization](#customization)
- [Development](#development)
- [Deployment](#deployment)
- [iOS App](#ios-app)
- [API Reference](#api-reference)
- [License](#license)

---

## Features

- **Multi-Client Architecture**: Terminal UI, web chat, and iOS app connect to a single persistent server
- **Event-Sourced Persistence**: All state stored as immutable events with fork/rewind operations
- **Multi-Model Support**: Claude (Anthropic), GPT-4o (OpenAI), Gemini (Google)
- **Sub-Agent Spawning**: Spawn child agents for parallel task execution
- **Hook System**: PreToolUse/PostToolUse hooks for automation and safety
- **Skills System**: Reusable context packages for domain-specific knowledge
- **Context Compaction**: Intelligent context management to stay within token limits

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Client Interfaces                               │
├─────────────────────┬─────────────────────┬─────────────────────────────────┤
│   Terminal (TUI)    │     Web Chat        │          iOS App                │
│   packages/tui      │   packages/chat-web │      packages/ios-app           │
└─────────┬───────────┴─────────┬───────────┴─────────────┬───────────────────┘
          │                     │                         │
          └─────────────────────┼─────────────────────────┘
                                │ WebSocket (JSON-RPC 2.0)
                                ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Agent Server                                        │
│                       packages/agent                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │  Providers  │  │    Tools    │  │   Context   │  │    Orchestrator     │ │
│  │  Anthropic  │  │  read/write │  │   loader    │  │  Session lifecycle  │ │
│  │  OpenAI     │  │  edit/bash  │  │  compaction │  │  Turn management    │ │
│  │  Google     │  │  grep/find  │  │  skills     │  │  Event routing      │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────────────┘ │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Event Store (SQLite)                                 │
│   - Immutable event log with tree structure                                  │
│   - Fork/rewind operations                                                   │
│   - Session state reconstruction via ancestor traversal                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Package Structure

```
tron/
├── packages/
│   ├── agent/       # Core agent server (providers, tools, events, RPC)
│   ├── tui/         # Terminal user interface
│   ├── chat-web/    # React web chat interface
│   └── ios-app/     # SwiftUI iOS application
├── scripts/         # CLI and deployment scripts
└── .claude/         # Agent configuration
```

---

## Quick Start

### One-Command Setup

```bash
./scripts/tron setup
```

This will check prerequisites, install Bun, install dependencies, build all packages, and create default configuration.

### Manual Setup

```bash
# Install Bun (required)
curl -fsSL https://bun.sh/install | bash

# Install dependencies and build
bun install
bun run build

# Start the TUI
bun run dev:tui

# Or start the server for web/iOS clients
bun run dev:server
```

### Why Bun?

- **3-6x faster** package installation than npm/pnpm/yarn
- **Built-in SQLite** (bun:sqlite) for fast database operations
- **Native TypeScript** support without transpilation
- **Workspace support** with automatic dependency resolution

---

## Packages

### Agent (`packages/agent`)

The core backend server. Handles LLM communication, tool execution, and event persistence.

```
src/
├── agent/           # TronAgent, turn execution
├── providers/       # Anthropic, OpenAI, Google LLM adapters
├── tools/           # read, write, edit, bash, grep, subagent, etc.
├── events/          # Event store, SQLite backend, reconstruction
├── context/         # AGENTS.md loader, system prompts, compaction
├── orchestrator/    # Session lifecycle, turn management
├── gateway/         # WebSocket server, RPC handlers
├── hooks/           # PreToolUse, PostToolUse hooks
└── skills/          # Skill loader, registry
```

**Documentation:** See `packages/agent/docs/`

### TUI (`packages/tui`)

Terminal user interface for interactive sessions.

```bash
bun run dev:tui        # Development mode
bun run login          # Authenticate with Claude Max
```

### Chat Web (`packages/chat-web`)

React-based web interface.

```bash
bun run dev:chat       # Development server at localhost:5173
```

### iOS App (`packages/ios-app`)

Native SwiftUI app with real-time streaming, session management, and push notifications.

**Requirements:** Xcode 16+, iOS 18 SDK, XcodeGen

```bash
cd packages/ios-app
xcodegen generate
open TronMobile.xcodeproj
```

**Documentation:** See `packages/ios-app/docs/`

---

## Tools

### Filesystem Tools

| Tool | Description |
|------|-------------|
| `read` | Read file contents with line numbers |
| `write` | Write content to files |
| `edit` | Search and replace within files |
| `ls` | List directory contents |
| `find` | Find files by pattern |
| `grep` | Search file contents with regex |

### System Tools

| Tool | Description |
|------|-------------|
| `bash` | Execute shell commands with timeout |
| `ast_grep` | Structural code search with AST patterns |

### Browser Tools

| Tool | Description |
|------|-------------|
| `open_browser` | Open URLs in browser |
| `agent_web_browser` | Automated browser interaction |

### Sub-Agent Tools

| Tool | Description |
|------|-------------|
| `spawn_subagent` | Spawn child agent for parallel tasks |
| `query_subagent` | Check sub-agent status and progress |
| `wait_for_subagent` | Wait for sub-agent completion |

### UI Tools

| Tool | Description |
|------|-------------|
| `ask_user_question` | Prompt user for input |
| `notify_app` | Send push notification to mobile app |
| `todo_write` | Create/update task list |
| `render_app_ui` | Render custom UI in mobile app |

---

## Event System

Tron uses **event sourcing** for all state persistence. Events form a tree via `parentId` references, enabling fork/rewind operations.

### Event Structure

```typescript
interface BaseEvent {
  id: string;              // UUID v7 (time-sortable)
  parentId: string | null; // Previous event (null for root)
  sessionId: string;
  sequence: number;        // Monotonic within session
  type: string;            // Event discriminator
  timestamp: string;       // ISO 8601
  payload: Record<string, unknown>;
}
```

### Event Types

| Type | Description |
|------|-------------|
| `session.start` | Session created |
| `session.end` | Session ended |
| `session.fork` | Session forked from another |
| `message.user` | User message |
| `message.assistant` | Assistant response |
| `tool.call` | Tool invoked |
| `tool.result` | Tool completed |
| `subagent.spawn` | Sub-agent created |
| `subagent.complete` | Sub-agent finished |
| `context.compaction` | Context compacted |

### Database Schema

```sql
CREATE TABLE events (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  parent_id TEXT,
  sequence INTEGER NOT NULL,
  depth INTEGER NOT NULL DEFAULT 0,
  type TEXT NOT NULL,
  timestamp TEXT NOT NULL,
  payload TEXT NOT NULL,
  workspace_id TEXT NOT NULL
);

CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  head_event_id TEXT,
  root_event_id TEXT,
  status TEXT DEFAULT 'active',
  model TEXT NOT NULL,
  provider TEXT NOT NULL,
  working_directory TEXT NOT NULL
);

CREATE TABLE workspaces (
  id TEXT PRIMARY KEY,
  path TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL
);
```

---

## Customization

### Settings

**Location:** `~/.tron/settings.json`

```json
{
  "models": {
    "default": "claude-sonnet-4-20250514",
    "defaultMaxTokens": 4096
  },
  "tools": {
    "bash": { "defaultTimeoutMs": 300000 }
  },
  "server": {
    "wsPort": 8080,
    "healthPort": 8081
  }
}
```

| Setting | Default | Description |
|---------|---------|-------------|
| `models.default` | `claude-opus-4-5-20251101` | Default model |
| `models.defaultMaxTokens` | `4096` | Max output tokens |
| `tools.bash.defaultTimeoutMs` | `120000` | Command timeout |
| `tools.read.defaultLimitLines` | `2000` | Lines per read |
| `server.wsPort` | `8080` | WebSocket port |
| `server.healthPort` | `8081` | Health endpoint |

### Environment Variables

| Variable | Overrides |
|----------|-----------|
| `TRON_WS_PORT` | `server.wsPort` |
| `TRON_HEALTH_PORT` | `server.healthPort` |
| `TRON_DEFAULT_MODEL` | `models.default` |
| `TRON_LOG_LEVEL` | Logging verbosity |

### Skills

Skills are reusable context packages with optional YAML frontmatter.

**Locations:**
- `~/.tron/skills/` — Global (all projects)
- `.claude/skills/` or `.tron/skills/` — Project (higher precedence)

**Creating a skill:**

```bash
mkdir -p ~/.tron/skills/my-rules
cat > ~/.tron/skills/my-rules/SKILL.md << 'EOF'
---
autoInject: true
tags: [rules, typescript]
---
Project coding standards.

- Use strict TypeScript
- No `any` types
- Write tests for new code
EOF
```

**Usage:** Reference with `@skill-name` in prompts:

```
@api-design Create a new endpoint for users
```

**Frontmatter options:**

| Option | Type | Description |
|--------|------|-------------|
| `autoInject` | boolean | Include in every prompt |
| `version` | string | Semantic version |
| `tools` | string[] | Associated tools |
| `tags` | string[] | Categorization |

### System Prompt

Custom system prompts override the built-in default.

**Priority order:**
1. Programmatic `systemPrompt` parameter
2. Project `.claude/SYSTEM.md` or `.tron/SYSTEM.md`
3. Global `~/.tron/SYSTEM.md`
4. Built-in default

### Context Rules

Path-scoped instructions loaded into every prompt.

| Location | Scope |
|----------|-------|
| `.claude/AGENTS.md` | Project |
| `subdir/AGENTS.md` | Subdirectory (loads when working in that path) |

### Hooks

Hooks allow custom logic before/after tool execution.

**PreToolUse** — Runs before a tool executes. Can block or modify.

```typescript
// .claude/hooks/pre-tool-use.ts
export default async function(tool: ToolCall) {
  if (tool.name === 'bash' && tool.arguments.command.includes('rm -rf')) {
    return { blocked: true, reason: 'Dangerous command blocked' };
  }
  return { proceed: true };
}
```

**PostToolUse** — Runs after a tool completes. Can log or transform.

```typescript
// .claude/hooks/post-tool-use.ts
export default async function(tool: ToolCall, result: ToolResult) {
  console.log(`Tool ${tool.name} completed in ${result.duration}ms`);
}
```

---

## Development

### Commands

```bash
# Build all packages
bun run build

# Run all tests
bun run test

# Watch mode
bun run test:watch

# Type check
bun run typecheck

# Lint
bun run lint

# Clean build artifacts
bun run clean
```

### Package-Specific Commands

```bash
# Agent
bun run --cwd packages/agent build
bun run --cwd packages/agent test

# TUI
bun run dev:tui

# Web Chat
bun run dev:chat

# iOS (requires Xcode)
cd packages/ios-app && xcodegen generate && open TronMobile.xcodeproj
```

### Database Debugging

```bash
# Query events
sqlite3 ~/.tron/db/prod.db "SELECT type, substr(payload, 1, 100) FROM events ORDER BY rowid DESC LIMIT 10"

# Query sessions
sqlite3 ~/.tron/db/prod.db "SELECT id, status, model FROM sessions ORDER BY rowid DESC LIMIT 5"
```

---

## Deployment

### Install as Service

```bash
./scripts/tron install
```

Creates a launchd service, installs `tron` CLI to `~/.local/bin/`, and starts the server.

### Service Management

```bash
tron status      # Show service status, health, deployed commit
tron start       # Start production service
tron stop        # Stop production service
tron restart     # Restart production service
tron logs        # Tail production logs
tron errors      # Show error log
```

### Deploy Updates

```bash
tron deploy      # Test → build → deploy with commit tracking
tron rollback    # Restore to last deployed commit
```

### Dual Environment

Run beta and production simultaneously:

| Environment | WebSocket | Health | Database |
|-------------|-----------|--------|----------|
| Production | 8080 | 8081 | `~/.tron/db/prod.db` |
| Beta | 8082 | 8083 | `~/.tron/db/beta.db` |

```bash
tron dev         # Run beta server (Ctrl+C to stop)
```

### Logs

```
~/.tron/logs/
├── prod/        # Production logs
└── beta/        # Beta logs
```

Format: `YYYY-MM-DD-HH-<tier>-server.log`
Retention: 90 days (auto-cleanup)

---

## iOS App

### Setup

```bash
brew install xcodegen
cd packages/ios-app
xcodegen generate
open TronMobile.xcodeproj
```

### Build Configurations

| Config | Server | Use Case |
|--------|--------|----------|
| Debug-Beta | localhost:8082 | Development |
| Release-Beta | localhost:8082 | TestFlight |
| Debug-Prod | localhost:8080 | Production testing |
| Release-Prod | localhost:8080 | App Store |

### Features

- Real-time chat with streaming responses
- Session management (create, fork, resume)
- Event-sourced state reconstruction
- Push notifications for background alerts
- Voice transcription input

### Push Notifications

Requires Apple Developer account with APNS key. See `packages/ios-app/docs/apns.md`.

---

## API Reference

### WebSocket Connection

```
ws://localhost:8080  (production)
ws://localhost:8082  (development)
```

All messages use JSON-RPC 2.0 format.

### RPC Methods

#### Session Management

| Method | Params | Returns |
|--------|--------|---------|
| `session.create` | `{ workingDirectory, model }` | `{ sessionId }` |
| `session.list` | `{ workspaceId?, limit? }` | `{ sessions }` |
| `session.get` | `{ sessionId }` | `{ session }` |
| `session.fork` | `{ sessionId, eventId? }` | `{ newSessionId }` |
| `session.delete` | `{ sessionId }` | `{ success }` |

#### Agent Control

| Method | Params | Returns |
|--------|--------|---------|
| `agent.message` | `{ sessionId, content, attachments? }` | Stream of events |
| `agent.abort` | `{ sessionId }` | `{ aborted }` |
| `agent.respond` | `{ sessionId, response }` | Stream of events |

#### Model

| Method | Params | Returns |
|--------|--------|---------|
| `model.list` | `{}` | `{ models }` |
| `model.switch` | `{ sessionId, model }` | `{ success }` |

### Event Notifications

Server sends notifications for real-time updates:

```typescript
// Text streaming
{ method: "agent.text_delta", params: { sessionId, delta } }

// Tool lifecycle
{ method: "agent.tool_start", params: { sessionId, toolName, toolId } }
{ method: "agent.tool_end", params: { sessionId, toolId, result } }

// Turn complete
{ method: "agent.turn_complete", params: { sessionId, tokenUsage } }

// Sub-agent events
{ method: "subagent.spawn", params: { parentSessionId, subagentSessionId, task } }
{ method: "subagent.complete", params: { subagentSessionId, result } }
```

### Health Endpoint

```
GET http://localhost:8081/health  (production)
GET http://localhost:8083/health  (development)

Response: { status: "ok", version: "1.0.0" }
```

---

## File Locations

```
~/.tron/
├── db/                 # SQLite databases (prod.db, beta.db)
├── logs/               # Server logs
├── settings.json       # Global settings
├── SYSTEM.md           # Global system prompt
├── skills/             # Global skills
└── rules/
    └── AGENTS.md       # Global context rules

.claude/                # Project config (or .tron/)
├── CLAUDE.md           # Project context rules
├── SYSTEM.md           # Project system prompt
└── skills/             # Project skills
```

---

## License

MIT

---

## Credits

Built on insights from:
- [pi-mono](https://github.com/badlogic/pi-mono) by Mario Zechner
- [Continuous-Claude-v2](https://github.com/parcadei/Continuous-Claude-v2)
- [Letta](https://docs.letta.com/)
- [AgentFS](https://github.com/tursodatabase/agentfs)
