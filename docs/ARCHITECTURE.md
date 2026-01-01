# Tron Agent - Architecture

## System Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         User Interfaces                              │
├──────────────────────┬──────────────────────┬──────────────────────┤
│     Terminal UI      │      Web Chat        │     Mobile PWA       │
│   (React/Ink CLI)    │     (React SPA)      │     (React)          │
└──────────┬───────────┴──────────┬───────────┴──────────┬───────────┘
           │                      │                      │
           │ stdin/stdout         │ WebSocket            │ WebSocket
           │                      │                      │
           ▼                      ▼                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        RPC Protocol Layer                            │
│   JSON messages over stdio (TUI) or WebSocket (Web/Mobile)          │
└─────────────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Session Orchestrator                            │
│   - Multi-session management                                         │
│   - Agent lifecycle (spawn, run, abort)                              │
│   - Event routing                                                    │
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
│                        Persistence Layer                             │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                 │
│   │  Sessions   │  │   Ledger    │  │  Handoffs   │                 │
│   │   (JSONL)   │  │ (Markdown)  │  │  (SQLite)   │                 │
│   └─────────────┘  └─────────────┘  └─────────────┘                 │
└─────────────────────────────────────────────────────────────────────┘
```

## Package Structure

### @tron/core

Core agent logic, tools, memory, hooks, skills.

```
packages/core/src/
├── agent/
│   ├── tron-agent.ts      # Main agent class
│   ├── turn-executor.ts   # Single turn execution
│   └── types.ts           # Agent types
├── providers/
│   ├── anthropic.ts       # Claude provider
│   ├── openai.ts          # GPT provider
│   ├── google.ts          # Gemini provider
│   └── factory.ts         # Provider factory
├── tools/
│   ├── read.ts            # File read
│   ├── write.ts           # File write
│   ├── edit.ts            # File edit
│   ├── bash.ts            # Shell execution
│   └── types.ts           # Tool interfaces
├── memory/
│   ├── ledger-manager.ts  # Working memory
│   ├── handoff-manager.ts # Episodic memory
│   ├── sqlite-store.ts    # SQLite persistence
│   └── types.ts           # Memory types
├── hooks/
│   ├── hook-engine.ts     # Hook execution
│   ├── hook-discovery.ts  # Find user hooks
│   └── builtin/           # Built-in hooks
├── skills/
│   ├── skill-loader.ts    # SKILL.md parser
│   ├── skill-registry.ts  # Skill storage
│   ├── skill-executor.ts  # Skill runner
│   └── builtin/           # Built-in skills
├── commands/
│   ├── command-router.ts  # /command routing
│   ├── command-parser.ts  # Argument parsing
│   └── builtin/           # Built-in commands
├── context/
│   ├── context-loader.ts  # AGENTS.md loading
│   └── hierarchy.ts       # Merge strategy
├── session/
│   ├── session-manager.ts # Session CRUD
│   └── types.ts           # Session types
├── rpc/
│   ├── handler.ts         # RPC command handler
│   └── types.ts           # RPC message types
├── auth/
│   ├── oauth.ts           # OAuth flow
│   ├── token-store.ts     # Credential storage
│   └── refresh.ts         # Token refresh
└── index.ts               # Public API
```

### @tron/server

WebSocket server and session orchestration.

```
packages/server/src/
├── index.ts               # Server entry
├── orchestrator.ts        # Session orchestrator
├── websocket.ts           # WebSocket handler
└── health.ts              # Health endpoints
```

### @tron/tui

Terminal UI using React/Ink.

```
packages/tui/src/
├── cli.ts                 # CLI entry
├── app.tsx                # Main app
├── components/
│   ├── Header.tsx
│   ├── MessageList.tsx
│   ├── InputArea.tsx
│   ├── StatusBar.tsx
│   └── ...
└── auth/
    └── oauth-cli.ts       # OAuth in terminal
```

### @tron/chat-web

Web chat interface.

```
packages/chat-web/src/
├── App.tsx                # Main app
├── components/
│   ├── ChatContainer.tsx
│   ├── MessageList.tsx
│   ├── PromptInput.tsx
│   └── ...
├── hooks/
│   ├── useWebSocket.ts
│   ├── useSession.ts
│   └── useAgent.ts
└── main.tsx               # Entry point
```

## Data Flow

### Agent Turn

```
User Message
     │
     ▼
┌─────────────────┐
│  RPC Handler    │ ← Parse request
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Hook: user_prompt │ ← Skill suggestions
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  TronAgent.run  │ ← Start agent loop
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   LLM Stream    │ ← Stream response
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Tool Calls?    │──No──▶ Return response
└────────┬────────┘
         │ Yes
         ▼
┌─────────────────┐
│ Hook: pre_tool  │ ← Validate/block
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Execute Tool    │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Hook: post_tool │ ← Index changes
└────────┬────────┘
         │
         ▼
    Loop back to LLM
```

### Session Fork

```
Original Session
     │
     ├── sess_abc123.jsonl
     │   ├── msg 0: user
     │   ├── msg 1: assistant
     │   ├── msg 2: user
     │   ├── msg 3: assistant
     │   └── msg 4: user
     │
     ▼
┌─────────────────┐
│  Fork Session   │ ← fromIndex=3
└────────┬────────┘
         │
         ▼
Forked Session
     │
     └── sess_xyz789.jsonl
         ├── msg 0: user
         ├── msg 1: assistant
         └── msg 2: user
         (metadata: parentSessionId=abc123)
```

### Memory Flow

```
Session Start
     │
     ▼
┌─────────────────┐
│ Load Ledger     │ ← Read ledger.md
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Search Handoffs │ ← FTS5 query
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Inject Context  │ ← Add to system prompt
└────────┬────────┘
         │
         ▼
    ... session runs ...
         │
         ▼
┌─────────────────┐
│ Update Ledger   │ ← Save current state
└────────┬────────┘
         │
         ▼
Session End
     │
     ▼
┌─────────────────┐
│ Create Handoff  │ ← Summarize session
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Extract Lessons │ ← Pattern recognition
└─────────────────┘
```

## Key Interfaces

### Session

```typescript
interface Session {
  id: string;
  workingDirectory: string;
  messages: Message[];
  model: string;
  provider: string;
  status: 'active' | 'ended' | 'failed';
  metadata: {
    createdAt: Date;
    endedAt?: Date;
    parentSessionId?: string;
  };
}
```

### Message

```typescript
type Message = UserMessage | AssistantMessage | ToolResultMessage;

interface UserMessage {
  role: 'user';
  content: string | Content[];
  timestamp?: number;
}

interface AssistantMessage {
  role: 'assistant';
  content: AssistantContent[];
  usage?: TokenUsage;
  thinking?: string;
}

interface ToolResultMessage {
  role: 'toolResult';
  toolCallId: string;
  content: Content[];
  isError?: boolean;
}
```

### Tool

```typescript
interface AgentTool<TParams = unknown, TDetails = unknown> {
  name: string;
  label: string;
  description: string;
  parameters: TSchema;
  execute: (
    toolCallId: string,
    params: TParams,
    signal: AbortSignal,
    onUpdate?: (update: string) => void
  ) => Promise<AgentToolResult<TDetails>>;
}
```

### Hook

```typescript
interface Hook {
  id: string;
  event: HookEvent;
  priority: number;
  matcher?: RegExp;
  handler: (context: HookContext) => Promise<HookResult>;
}

type HookEvent =
  | 'session_start'
  | 'session_end'
  | 'pre_tool_use'
  | 'post_tool_use'
  | 'pre_compact'
  | 'user_prompt'
  | 'stop';

interface HookResult {
  action: 'continue' | 'block' | 'modify';
  message?: string;
  modifications?: Record<string, unknown>;
}
```

### Handoff

```typescript
interface Handoff {
  id: string;
  sessionId: string;
  timestamp: Date;
  summary: string;
  codeChanges: CodeChange[];
  currentState: string;
  nextSteps: string[];
  blockers: string[];
  patterns: string[];
  metadata?: Record<string, unknown>;
}
```

## Design Decisions

### Why JSONL for Sessions?

- Append-only is crash-safe
- Easy to inspect with jq
- Streaming-friendly
- Git-friendly diffs

### Why SQLite for Handoffs?

- FTS5 for full-text search
- ACID transactions
- Zero-config deployment
- Portable single file

### Why Markdown for Ledger?

- Human-readable
- Agent can edit directly
- Version-controllable
- Supports rich formatting

### Why React/Ink for TUI?

- Component model for UI
- Same mental model as web
- Good for complex layouts
- Hot reload in dev

### Why Separate Packages?

- Independent deployability
- Clear boundaries
- Testable in isolation
- Different release cycles
