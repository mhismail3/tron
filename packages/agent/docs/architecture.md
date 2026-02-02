# Agent Architecture

## Overview

The agent package (`@tron/agent`) is the core backend for Tron. It handles:
- LLM communication via providers (Anthropic, OpenAI, Google)
- Tool execution (read, write, edit, bash, grep, etc.)
- Event-sourced session persistence
- Context management and compaction
- Sub-agent spawning and coordination
- WebSocket server for clients

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Event Store Orchestrator                          │
│   - Multi-session management                                         │
│   - Agent lifecycle (spawn, run, abort)                              │
│   - Event routing and persistence                                    │
└─────────────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        TronAgent Core                                │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                 │
│   │   Provider  │  │    Tools    │  │   Context   │                 │
│   │  (LLM API)  │  │ read/write/ │  │   loader    │                 │
│   │             │  │ edit/bash   │  │             │                 │
│   └─────────────┘  └─────────────┘  └─────────────┘                 │
└─────────────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     Event Store (SQLite)                             │
│   - Immutable event log with tree structure                          │
│   - Session state reconstruction via ancestor traversal              │
│   - Fork/rewind operations                                           │
└─────────────────────────────────────────────────────────────────────┘
```

## Package Structure

The package is organized into 8 top-level directories following a layered architecture:

```
src/
├── core/                    # Foundation Layer
│   ├── types/               # Shared type definitions
│   ├── di/                  # Dependency injection infrastructure
│   ├── utils/               # Shared utilities
│   ├── errors/              # Error types and handling
│   └── constants.ts         # Version, name constants
│
├── infrastructure/          # Cross-Cutting Concerns
│   ├── logging/             # Pino-based logging with SQLite transport
│   ├── settings/            # Configuration, feature flags
│   ├── auth/                # API key management
│   ├── communication/       # Inter-agent messaging bus
│   ├── usage/               # Token/cost tracking
│   └── events/              # Event store, SQLite backend
│
├── llm/                     # LLM Provider Layer
│   └── providers/           # LLM adapters
│       ├── anthropic/       # Claude provider
│       ├── google/          # Gemini provider
│       ├── openai/          # GPT/o1/o3 provider
│       └── base/            # Shared infrastructure
│
├── context/                 # Context Management
│   ├── system-prompts/      # System prompt templates
│   ├── rules-tracker.ts     # AGENTS.md/rules tracking
│   └── compaction/          # Context compaction
│
├── runtime/                 # Agent Execution
│   ├── agent/               # TronAgent, turn execution
│   ├── orchestrator/        # Multi-session orchestration
│   │   ├── persistence/     # Event store orchestrator
│   │   ├── session/         # Session context, managers
│   │   └── controllers/     # Browser, notification, worktree
│   └── services/            # Session, context services
│
├── capabilities/            # Agent Capabilities
│   ├── tools/               # Tool implementations
│   │   ├── fs/              # Filesystem (read, write, edit)
│   │   ├── browser/         # Browser automation
│   │   ├── subagent/        # Sub-agent spawning
│   │   ├── ui/              # User interaction (ask, notify, todo)
│   │   ├── system/          # Bash, thinking
│   │   └── search/          # Code search
│   ├── extensions/          # Extensibility
│   │   ├── hooks/           # PreToolUse, PostToolUse hooks
│   │   ├── skills/          # Skill loader, registry
│   │   └── commands/        # Custom commands
│   ├── guardrails/          # Safety guardrails
│   └── todos/               # Task management
│
├── interface/               # External Interfaces
│   ├── server.ts            # TronServer entry point
│   ├── http/                # HTTP server (Hono)
│   ├── gateway/             # WebSocket gateway
│   ├── rpc/                 # RPC protocol, handlers
│   └── ui/                  # RenderAppUI components
│
├── platform/                # Platform Integrations
│   ├── session/             # Session, worktree management
│   │   └── worktree/        # Git worktree isolation
│   ├── external/            # External services
│   │   ├── browser/         # Playwright browser service
│   │   └── apns/            # Apple Push Notifications
│   ├── deployment/          # Self-deployment
│   ├── productivity/        # Canvas, task tools
│   └── transcription/       # Speech-to-text
│
└── __fixtures__/            # Test utilities
```

### Dependency Flow

```
interface/  ← Entry points (server, gateway, rpc)
    │
runtime/    ← Agent execution
    │
    ├── capabilities/  (tools, extensions)
    ├── context/       (message management)
    └── platform/      (session, external)
    │
llm/        ← LLM providers
    │
infrastructure/  ← Logging, events, settings
    │
core/       ← Types, utilities
```

## Event Sourcing

All state is stored as immutable events forming a tree via `parentId` references.

### Event Structure

```typescript
interface BaseEvent {
  id: string;              // UUID v7 (time-sortable)
  parentId: string | null; // Previous event (null for root)
  sessionId: string;
  sequence: number;        // Monotonic within session
  type: string;            // Discriminator
  timestamp: string;       // ISO 8601
  payload: Record<string, unknown>;
}
```

### Event Tree

```
[session.start] ← root (parentId=null)
      │
[message.user]
      │
[message.assistant]
      │
[message.user]  ← FORK POINT
      │         \
[message.a]    [session.fork] ← New branch
```

### Sessions as Pointers

Sessions don't store messages directly. They hold:
- `rootEventId`: First event (session.start)
- `headEventId`: Current position

State is reconstructed by walking ancestors from head to root.

### Key Event Types

| Type | Payload |
|------|---------|
| `session.start` | workingDirectory, model, provider |
| `session.end` | reason, summary |
| `message.user` | content, turn |
| `message.assistant` | content, tokenUsage |
| `tool.call` | name, arguments |
| `tool.result` | content, isError, duration |
| `subagent.spawn` | sessionId, task, model |
| `subagent.complete` | sessionId, result, tokenUsage |

### Operations

**Fork:** Create new session branching from any event. New session's root = fork event with parentId pointing to branch point.

**Rewind:** Move session's headEventId back. Events after become orphaned (preserved in DB).

## Database Schema

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

## Tool Execution Flow

```
User message → TronAgent.run() → LLM generates response
                                        │
                    ├── Text only → Return response
                    │
                    └── Tool calls → For each tool:
                        ├── PreToolUse hook (can block)
                        ├── Execute tool
                        ├── PostToolUse hook
                        └── Loop back to LLM
```

## Context Loading

Hierarchical loading with multi-directory support:

1. Project: `.claude/AGENTS.md` or `.tron/AGENTS.md`
2. Subdirectory: `subdir/AGENTS.md` files (path-scoped)

## Providers

Providers are organized into modular directories for maintainability:

| Provider | Models | Directory |
|----------|--------|-----------|
| Anthropic | Claude 3.5/4 variants | `providers/anthropic/` |
| Google | Gemini 2.x | `providers/google/` |
| OpenAI | GPT-4o, o1, o3 | `providers/openai.ts` |

Each modular provider directory contains:
- `index.ts` - Public exports
- `*-provider.ts` - Core provider class
- `message-converter.ts` - Message format conversion
- `types.ts` - Provider-specific types

Token usage is normalized across providers via `token-normalizer.ts`.

## Dependency Injection

Settings are injected via the `SettingsProvider` interface rather than global access:

```typescript
import { getSettingsProvider } from '../di/index.js';

// In factory functions
const settings = getSettingsProvider();
const apiConfig = settings.get('api');
```

This enables testing with mock settings and avoids global state issues.

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| SQLite | Single file, ACID, FTS5, portable |
| Event sourcing | Auditability, fork/rewind, reproducibility |
| Multi-directory | Support both Claude Code and Tron conventions |
| WebSocket | Bidirectional, real-time streaming |
