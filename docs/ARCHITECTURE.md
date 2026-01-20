# Architecture

<!--
PURPOSE: System architecture overview for developers.
AUDIENCE: Developers needing to understand how Tron works.

AGENT MAINTENANCE:
- Update diagrams if package structure changes
- Update interface definitions if types change
- Verify package paths match actual codebase structure
- Last verified: 2026-01-20
-->

## System Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         User Interfaces                              │
├──────────────────────┬──────────────────────┬──────────────────────┤
│     Terminal UI      │      Web Chat        │     iOS App          │
│   (React/Ink CLI)    │     (React SPA)      │     (SwiftUI)        │
└──────────┬───────────┴──────────┬───────────┴──────────┬───────────┘
           │                      │                      │
           │ Direct               │ WebSocket            │ WebSocket
           │                      │                      │
           ▼                      ▼                      ▼
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
│   │   Provider  │  │    Tools    │  │   Hooks     │                 │
│   │  (LLM API)  │  │ read/write/ │  │ lifecycle   │                 │
│   │             │  │ edit/bash   │  │ events      │                 │
│   └─────────────┘  └─────────────┘  └─────────────┘                 │
│                                                                      │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                 │
│   │   Skills    │  │  Commands   │  │  Context    │                 │
│   │  registry   │  │   router    │  │   loader    │                 │
│   └─────────────┘  └─────────────┘  └─────────────┘                 │
└─────────────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     Event Store (SQLite)                             │
│   - Immutable event log                                              │
│   - Session state reconstruction                                     │
│   - Fork/rewind operations                                           │
│   - Full-text search (FTS5)                                          │
└─────────────────────────────────────────────────────────────────────┘
```

## Packages

### @tron/core

Core agent logic, tools, and event storage.

```
packages/core/src/
├── agent/           # TronAgent, turn execution
├── providers/       # Anthropic, OpenAI, Google
├── tools/           # read, write, edit, bash, grep, find
├── events/          # Event store, SQLite backend
├── hooks/           # Hook engine, discovery
├── skills/          # Skill loader, registry
├── context/         # AGENTS.md loader, system prompts
└── subagents/       # Sub-agent spawning and tracking
```

### @tron/server

WebSocket server and session orchestration.

```
packages/server/src/
├── index.ts                    # Server entry
├── event-store-orchestrator.ts # Session management
├── websocket-handler.ts        # WebSocket protocol
└── health-server.ts            # Health endpoints
```

### @tron/tui

Terminal UI using React/Ink.

```
packages/tui/src/
├── cli.ts           # CLI entry point
├── app.tsx          # Main React component
└── components/      # UI components
```

### @tron/chat-web

Web chat interface (React SPA).

```
packages/chat-web/src/
├── App.tsx          # Main app
├── components/      # UI components
├── hooks/           # React hooks
└── store/           # State management
```

### @tron/ios-app

iOS application (SwiftUI).

```
packages/ios-app/Sources/
├── App/             # App entry, state
├── Views/           # SwiftUI views
├── ViewModels/      # View models
├── Services/        # RPC client, event sync
└── Database/        # Local SQLite cache
```

## Key Concepts

### Event Sourcing

All state changes are recorded as immutable events. Session state is reconstructed by replaying events from root to head. See [event-system.md](./event-system.md) for details.

### Tool Execution Flow

```
User message
    │
    ▼
TronAgent.run()
    │
    ▼
LLM generates response
    │
    ├── Text only → Return response
    │
    └── Tool calls → For each tool:
        │
        ├── PreToolUse hook (can block)
        ├── Execute tool
        ├── PostToolUse hook (can log)
        └── Loop back to LLM
```

### Context Loading

Context files are loaded hierarchically:
1. Global: `~/.tron/rules/AGENTS.md`
2. Project: `.claude/AGENTS.md` or `.tron/AGENTS.md`
3. Directory: Subdirectory AGENTS.md files

Both `.claude/` and `.tron/` directories are checked for compatibility.

## Key Interfaces

### Session

```typescript
interface Session {
  id: string;
  workspaceId: string;
  rootEventId: string;      // First event
  headEventId: string;      // Current position
  status: 'active' | 'ended';
  model: string;
  provider: string;
}
```

### Event

```typescript
interface BaseEvent {
  id: string;               // UUID v7 (time-sortable)
  parentId: string | null;  // Previous event (null for root)
  sessionId: string;
  sequence: number;         // Monotonic within session
  type: string;             // Event type discriminator
  timestamp: string;        // ISO 8601
  payload: Record<string, unknown>;
}
```

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| SQLite for events | Single file, ACID, FTS5, portable |
| Event sourcing | Auditability, fork/rewind, reproducibility |
| React/Ink for TUI | Component model, hot reload |
| Separate packages | Clear boundaries, independent testing |
| Multi-directory compat | Support both Claude Code and Tron conventions |
