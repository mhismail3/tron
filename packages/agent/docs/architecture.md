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

```
src/
├── agent/           # TronAgent, turn execution
├── providers/       # Anthropic, OpenAI, Google LLM adapters
├── tools/           # read, write, edit, bash, grep, find, subagent
│   ├── fs/          # Filesystem tools
│   ├── browser/     # Browser automation
│   ├── subagent/    # Sub-agent spawning
│   ├── ui/          # User interaction (ask, notify, todo)
│   └── system/      # Bash, thinking
├── events/          # Event store, SQLite backend, reconstruction
├── context/         # AGENTS.md loader, system prompts, compaction
├── orchestrator/    # Session lifecycle, turn management
├── gateway/         # WebSocket server, RPC handlers
├── hooks/           # PreToolUse, PostToolUse hooks
├── skills/          # Skill loader, registry
└── rpc/             # RPC protocol, handlers, schemas
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

1. Global: `~/.tron/rules/AGENTS.md`
2. Project: `.claude/AGENTS.md` or `.tron/AGENTS.md`
3. Subdirectory: `subdir/AGENTS.md` files

## Providers

| Provider | Models | File |
|----------|--------|------|
| Anthropic | Claude 3.5/4 variants | `providers/anthropic.ts` |
| OpenAI | GPT-4o, o1, o3 | `providers/openai.ts` |
| Google | Gemini 2.x | `providers/google.ts` |

Token usage is normalized across providers via `token-normalizer.ts`.

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| SQLite | Single file, ACID, FTS5, portable |
| Event sourcing | Auditability, fork/rewind, reproducibility |
| Multi-directory | Support both Claude Code and Tron conventions |
| WebSocket | Bidirectional, real-time streaming |
