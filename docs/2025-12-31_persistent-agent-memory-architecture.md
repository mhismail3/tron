# Persistent Agent Architecture: Memory, Context, and Multi-Model Testing

**Date:** 2025-12-31
**Status:** published
**Tags:** llm, agent, memory, context-management, persistence, multi-model, always-on

## Summary

This research report analyzes state-of-the-art approaches to building **persistent, always-on AI coding agents** with sophisticated memory management. The goal is to design an agent that:

1. **Runs persistently** on a home server (Mac Mini) for instant access
2. **Tests new models** as they release to evaluate capabilities
3. **Maintains rich memory** across sessions with lossless context preservation
4. **Supports dual interfaces** (terminal + chat) as first-class citizens

This report synthesizes learnings from Continuous-Claude-v2, Letta, AgentFS, and community best practices into a cohesive architecture.

---

## Table of Contents

1. [The Context Problem](#1-the-context-problem)
2. [Memory Architecture Patterns](#2-memory-architecture-patterns)
3. [The Continuous-Claude Approach](#3-the-continuous-claude-approach)
4. [Letta's Memory Blocks](#4-lettas-memory-blocks)
5. [AgentFS: SQLite as Agent Runtime](#5-agentfs-sqlite-as-agent-runtime)
6. [Episodic Memory & Vector Search](#6-episodic-memory--vector-search)
7. [Hook System Design](#7-hook-system-design)
8. [Always-On Service Architecture](#8-always-on-service-architecture)
9. [Multi-Model Testing Framework](#9-multi-model-testing-framework)
10. [Implementation Recommendations](#10-implementation-recommendations)
11. [Unified Architecture Design](#11-unified-architecture-design)

---

## 1. The Context Problem

### The Compaction Death Spiral

Every LLM-based agent faces the same fundamental constraint: **limited context windows**. When conversations exceed the window, systems must compress or summarize. The problem:

```
Session 1: Full context (100% signal)
    ↓ compact
Session 2: Summary of context (70% signal)
    ↓ compact
Session 3: Summary of summary (40% signal)
    ↓ compact
Session 4: Hallucination territory (<20% signal)
```

Each compaction loses detail. After multiple compactions, the agent works with "a summary of a summary," causing:
- Forgotten architectural decisions
- Contradictory code patterns
- Repeated failed approaches
- Loss of project-specific conventions

### The Industry Response

Different systems take different approaches:

| System | Approach | Trade-off |
|--------|----------|-----------|
| Claude Code | Auto-compact at threshold | Lossy, invisible |
| Cursor | Per-request context injection | No cross-request memory |
| Continuous-Claude | Clear + ledger reload | Manual, but lossless |
| Letta | Memory blocks + archival | Complex, but comprehensive |
| AgentFS | SQLite snapshots | Heavy, but auditable |

### The Core Insight

> **"Clear, don't compact. Save state to a ledger, wipe context, resume fresh."**
> — Continuous-Claude philosophy

The solution isn't better compression—it's **controlled context clearing** with **lossless state persistence**.

---

## 2. Memory Architecture Patterns

### Four-Level Memory Hierarchy

Based on research across multiple systems, effective agent memory follows a four-level hierarchy:

```
┌─────────────────────────────────────────────────────────────────┐
│  Level 1: IMMEDIATE (In-Context)                                │
│  • System prompt + current task                                 │
│  • Most recent N messages                                       │
│  • Active file contents                                         │
│  Token budget: 60-80% of context window                        │
├─────────────────────────────────────────────────────────────────┤
│  Level 2: SESSION (Working Memory)                              │
│  • Ledger: current goal, focus, next steps                     │
│  • Modified files list                                          │
│  • Pending decisions                                            │
│  Persisted to: thoughts/ledgers/                               │
├─────────────────────────────────────────────────────────────────┤
│  Level 3: PROJECT (Episodic Memory)                             │
│  • Past session handoffs                                        │
│  • Commit reasoning history                                     │
│  • Successful/failed patterns                                   │
│  Persisted to: SQLite + FTS5 index                             │
├─────────────────────────────────────────────────────────────────┤
│  Level 4: GLOBAL (Institutional Memory)                         │
│  • Cross-project learnings                                      │
│  • Model-specific quirks                                        │
│  • Personal preferences                                         │
│  Persisted to: ~/.agent/learnings/                             │
└─────────────────────────────────────────────────────────────────┘
```

### Memory Operations

Each level supports specific operations:

| Level | Read | Write | Search | Compact |
|-------|------|-------|--------|---------|
| Immediate | Automatic | Automatic | N/A | Yes (lossy) |
| Session | On session start | On clear/end | No | No |
| Project | On demand | On handoff | Yes (FTS5) | Archive |
| Global | On session start | On learning extraction | Yes | No |

---

## 3. The Continuous-Claude Approach

### Core Philosophy

Continuous-Claude treats context as a **renewable resource** rather than a scarce limitation:

1. Work with fresh context + loaded ledger (high signal)
2. Use hooks to index artifacts during work
3. Before compaction triggers, create handoff
4. `/clear` wipes context, preserves ledger
5. Reload fresh context + ledger state
6. Resume with full signal integrity

### The Ledger System

The **continuity ledger** (`thoughts/ledgers/CONTINUITY_*.md`) is working memory within a session:

```markdown
# Continuity Ledger

## Goal
Build dual-interface coding agent with memory support

## Constraints
- Must work with Claude Max OAuth
- Terminal + chat as first-class interfaces
- Always-on service on Mac Mini

## Done
- [x] Researched pi-mono architecture
- [x] Documented OAuth flow

## Now
Implementing memory persistence layer

## Next
- [ ] Design hook system
- [ ] Build session manager
- [ ] Test multi-model switching

## Key Decisions
- Using SQLite for state (portable, auditable)
- RPC protocol for dual-interface (from pi)
- Event streaming for observability

## Working Files
- src/memory/ledger.ts
- src/hooks/session-start.ts
```

Before running `/clear`:
> "Update the ledger, I'm about to clear"

The `SessionStart` hook automatically reloads this on the next session.

### Handoff Documents

**Handoffs** transfer detailed context between sessions:

```markdown
# Handoff: 2025-12-31T16:45:00

## Session Summary
Implemented OAuth flow for Claude Max, tested token refresh

## Code Changes
- `src/auth/oauth.ts:45-120` - PKCE implementation
- `src/auth/refresh.ts:1-50` - Token refresh logic

## Current State
OAuth working, need to integrate with streaming

## Blockers
None

## Next Steps
1. Wire OAuth tokens into Anthropic client
2. Test streaming with Max subscription
3. Add token expiry handling

## Patterns Discovered
- OAuth tokens expire with 5-minute buffer
- Must use `authToken` not `apiKey` for OAuth
```

### Artifact Index (FTS5)

A SQLite database indexes all handoffs for cross-session search:

```sql
-- Schema
CREATE VIRTUAL TABLE handoffs USING fts5(
  session_id,
  timestamp,
  summary,
  code_changes,
  patterns,
  content
);

-- Search past sessions
SELECT * FROM handoffs
WHERE handoffs MATCH 'OAuth refresh token'
ORDER BY rank;
```

This enables queries like:
> "Recall what was tried for authentication bugs"

---

## 4. Letta's Memory Blocks

### Two-Tier Architecture

Letta distinguishes between:

1. **In-Context Memory (Core Blocks)**: Always visible, actively managed
2. **Out-of-Context Memory (Archival)**: Retrieved on demand via search

### Memory Blocks

Blocks are structured sections the agent can read AND write:

```typescript
interface MemoryBlock {
  name: string;           // "user_preferences"
  content: string;        // Current state
  limit: number;          // Max tokens for this block
  lastUpdated: Date;
}

// Agent tools for self-management
interface MemoryTools {
  memory_replace(block: string, search: string, replace: string): void;
  memory_insert(block: string, content: string): void;
  memory_rethink(block: string, newContent: string): void;
}
```

**Key insight**: Agents decide autonomously when to update memory—this is learned behavior, not hardcoded.

### Block Types

| Block | Purpose | Update Frequency |
|-------|---------|------------------|
| `persona` | Agent identity/style | Rarely |
| `human` | User preferences/context | When user info changes |
| `project` | Current project state | Per session |
| `scratchpad` | Working notes | Frequently |

### Archival Memory

For unlimited storage with semantic search:

```typescript
interface ArchivalMemory {
  insert(content: string, metadata?: object): string;  // Returns ID
  search(query: string, limit?: number): ArchivalEntry[];
  delete(id: string): void;
}

interface ArchivalEntry {
  id: string;
  content: string;
  embedding: number[];  // For semantic search
  metadata: object;
  timestamp: Date;
}
```

---

## 5. AgentFS: SQLite as Agent Runtime

### Core Concept

AgentFS stores the entire agent runtime in a single SQLite file:

```
agent.db
├── files/          (POSIX-like filesystem)
├── kv/             (Key-value store)
└── toolcalls/      (Audit trail)
```

### Benefits

1. **Auditability**: Query complete agent history with SQL
2. **Reproducibility**: `cp agent.db snapshot.db` for exact state capture
3. **Portability**: Single file moves between machines

### Schema (Conceptual)

```sql
-- Filesystem
CREATE TABLE files (
  path TEXT PRIMARY KEY,
  content BLOB,
  mime_type TEXT,
  created_at TIMESTAMP,
  modified_at TIMESTAMP
);

-- Key-Value Store
CREATE TABLE kv (
  key TEXT PRIMARY KEY,
  value JSON,
  expires_at TIMESTAMP
);

-- Tool Call Audit
CREATE TABLE toolcalls (
  id TEXT PRIMARY KEY,
  tool_name TEXT,
  arguments JSON,
  result JSON,
  duration_ms INTEGER,
  timestamp TIMESTAMP,
  session_id TEXT
);
```

### Use Cases

```typescript
// Snapshot before risky operation
await db.exec("VACUUM INTO 'backup.db'");

// Query what happened in last session
const calls = await db.all(`
  SELECT tool_name, arguments, result
  FROM toolcalls
  WHERE session_id = ?
  ORDER BY timestamp
`, [lastSessionId]);

// Rollback to previous state
await fs.copyFile('backup.db', 'agent.db');
```

---

## 6. Episodic Memory & Vector Search

### The Episodic Memory Plugin

Jesse Vincent's `episodic-memory` plugin enables semantic search over past sessions:

```
~/.claude/projects/          (Raw session logs - JSONL)
        ↓ archive hook
~/.config/superpowers/conversations-archive/
        ↓ embed + index
SQLite with vector search
        ↓ MCP tool
Accessible in Claude workflows
```

### Implementation Components

1. **Archive Hook**: Preserves conversation logs at session start
2. **Vector Database**: SQLite with semantic search (likely sqlite-vss)
3. **CLI Tool**: Search and format past conversations
4. **MCP Integration**: Exposes memory to Claude as tools
5. **Skill Module**: Instructs Claude when to search history

### Retention Configuration

```json
// ~/.claude/settings.json
{
  "cleanupPeriodDays": 99999  // Keep logs forever (default: 30)
}
```

### Search Patterns

```typescript
// Semantic search for similar past problems
const results = await episodicMemory.search(
  "authentication flow with OAuth tokens",
  { limit: 5, minSimilarity: 0.7 }
);

// Full-text search for exact terms
const results = await episodicMemory.fts(
  "PKCE verifier challenge",
  { limit: 10 }
);
```

---

## 7. Hook System Design

### Hook Types (10 Events)

Based on Continuous-Claude's implementation:

| Hook | Trigger | Use Case |
|------|---------|----------|
| `SessionStart` | New session or `/clear` | Load ledger, handoffs |
| `SessionEnd` | Session closes | Extract learnings, cleanup |
| `PreToolUse` | Before tool execution | Validation, type-checking |
| `PostToolUse` | After tool execution | Index changes, track state |
| `PreCompact` | Before auto-compaction | Auto-handoff generation |
| `UserPromptSubmit` | Every user message | Skill suggestions, warnings |
| `Stop` | Agent completes | Finalize state |
| `SubagentStop` | Subagent completes | Capture reports |
| `Notification` | System notifications | External triggers |

### Hook Implementation Pattern

```typescript
// Hook receives JSON, returns JSON control signal
interface HookInput {
  event: string;
  sessionId: string;
  context: {
    toolName?: string;
    arguments?: object;
    result?: object;
    userMessage?: string;
    tokenUsage?: number;
  };
}

interface HookOutput {
  action: "continue" | "block" | "modify";
  message?: string;  // Inject into context
  modifiedArgs?: object;  // For PreToolUse
}

// Example: Context warning hook
async function userPromptHook(input: HookInput): Promise<HookOutput> {
  const usage = input.context.tokenUsage || 0;
  const percentage = (usage / MAX_TOKENS) * 100;

  if (percentage > 80) {
    return {
      action: "continue",
      message: `⚠️ Context at ${percentage.toFixed(1)}%. Consider creating handoff.`
    };
  }

  return { action: "continue" };
}
```

### Pre-Bundled JavaScript Pattern

Continuous-Claude uses pre-bundled JS with shell wrappers:

```bash
#!/bin/bash
# session-start-continuity.sh
exec node "$HOME/.claude/hooks/dist/session-start.js" "$@"
```

This enables:
- Zero runtime dependencies
- Fast execution (no package resolution)
- Easy distribution (just copy files)

### The TypeScript Preflight Pattern

```typescript
// PreToolUse hook for .ts files
async function typescriptPreflight(input: HookInput): Promise<HookOutput> {
  if (input.context.toolName !== "Edit") return { action: "continue" };

  const filePath = input.context.arguments?.path;
  if (!filePath?.endsWith('.ts')) return { action: "continue" };

  // Run type checker
  const { exitCode, stderr } = await exec('tsc --noEmit');

  if (exitCode !== 0) {
    return {
      action: "block",
      message: `Type errors found:\n${stderr}\nFix before editing.`
    };
  }

  return { action: "continue" };
}
```

---

## 8. Always-On Service Architecture

### Design Goals

1. **Persistent**: Survives reboots, runs 24/7
2. **Multi-Session**: Handles multiple concurrent conversations
3. **Observable**: Full state visibility for debugging
4. **Accessible**: Both terminal and chat interfaces

### System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Mac Mini Server                               │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    Agent Supervisor                          │   │
│  │  (launchd/systemd - restarts on crash)                      │   │
│  └─────────────────────────────────────────────────────────────┘   │
│         │                                                           │
│         ▼                                                           │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    Session Manager                           │   │
│  │  • Spawns agent processes                                   │   │
│  │  • Routes WebSocket connections                             │   │
│  │  • Manages session lifecycle                                │   │
│  │  • Handles graceful shutdown                                │   │
│  └─────────────────────────────────────────────────────────────┘   │
│         │                    │                    │                 │
│         ▼                    ▼                    ▼                 │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐          │
│  │  Session 1    │  │  Session 2    │  │  Session N    │          │
│  │  (RPC mode)   │  │  (RPC mode)   │  │  (RPC mode)   │          │
│  │               │  │               │  │               │          │
│  │  SQLite DB    │  │  SQLite DB    │  │  SQLite DB    │          │
│  │  Memory Mgr   │  │  Memory Mgr   │  │  Memory Mgr   │          │
│  └───────────────┘  └───────────────┘  └───────────────┘          │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
         ▲                    ▲                    ▲
         │                    │                    │
         │ WebSocket          │ WebSocket          │ Direct
         │                    │                    │
┌────────┴────────┐  ┌───────┴────────┐  ┌───────┴────────┐
│  Chat Client    │  │  Chat Client   │  │  Terminal      │
│  (iPhone PWA)   │  │  (Web)         │  │  (SSH)         │
└─────────────────┘  └────────────────┘  └────────────────┘
```

### Process Management (launchd)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.agent-server</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/node</string>
        <string>/opt/agent/server.js</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/var/log/agent/stdout.log</string>

    <key>StandardErrorPath</key>
    <string>/var/log/agent/stderr.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>NODE_ENV</key>
        <string>production</string>
    </dict>
</dict>
</plist>
```

### Session State Persistence

Each session maintains its own SQLite database:

```
~/.agent/
├── sessions/
│   ├── session-abc123.db    (AgentFS-style)
│   ├── session-def456.db
│   └── session-ghi789.db
├── memory/
│   ├── episodic.db          (Vector search)
│   └── learnings/           (Cross-session patterns)
├── config/
│   ├── auth.json            (OAuth tokens)
│   ├── models.json          (Model registry)
│   └── settings.json        (Preferences)
└── logs/
    └── server.log
```

### Health Monitoring

```typescript
interface ServerHealth {
  uptime: number;
  activeSessions: number;
  memoryUsage: NodeJS.MemoryUsage;
  lastError?: Error;
  modelStatus: Record<string, "available" | "rate-limited" | "error">;
}

// Expose via HTTP endpoint
app.get('/health', (req, res) => {
  res.json(getServerHealth());
});

// Optional: Push to monitoring service
setInterval(() => {
  metrics.gauge('agent.active_sessions', activeSessions.size);
  metrics.gauge('agent.memory_mb', process.memoryUsage().heapUsed / 1024 / 1024);
}, 60000);
```

---

## 9. Multi-Model Testing Framework

### Model Registry

```typescript
interface ModelConfig {
  id: string;
  provider: "anthropic" | "openai" | "google" | "mistral" | "local";
  name: string;
  contextWindow: number;
  supportsTools: boolean;
  supportsStreaming: boolean;
  supportsThinking?: boolean;
  costPer1kInput: number;
  costPer1kOutput: number;
  auth: "api_key" | "oauth";
  endpoint?: string;  // For custom endpoints
}

const modelRegistry: ModelConfig[] = [
  {
    id: "claude-sonnet-4-20250514",
    provider: "anthropic",
    name: "Claude Sonnet 4",
    contextWindow: 200000,
    supportsTools: true,
    supportsStreaming: true,
    supportsThinking: true,
    costPer1kInput: 0.003,
    costPer1kOutput: 0.015,
    auth: "oauth"
  },
  {
    id: "gpt-4o",
    provider: "openai",
    name: "GPT-4o",
    contextWindow: 128000,
    supportsTools: true,
    supportsStreaming: true,
    costPer1kInput: 0.005,
    costPer1kOutput: 0.015,
    auth: "api_key"
  },
  // ... more models
];
```

### Model Switching Mid-Session

```typescript
// RPC command
interface SwitchModelCommand {
  type: "switch_model";
  modelId: string;
  preserveContext: boolean;  // Convert messages if needed
}

// Handler
async function switchModel(session: Session, cmd: SwitchModelCommand) {
  const newModel = modelRegistry.find(m => m.id === cmd.modelId);
  if (!newModel) throw new Error(`Unknown model: ${cmd.modelId}`);

  // Check auth
  const auth = await getAuthForProvider(newModel.provider);
  if (!auth) throw new Error(`No auth for ${newModel.provider}`);

  // Convert context if needed (e.g., Claude thinking → text for OpenAI)
  if (cmd.preserveContext) {
    session.messages = convertMessagesForProvider(
      session.messages,
      session.model.provider,
      newModel.provider
    );
  }

  session.model = newModel;
  session.emit('model_switched', { from: oldModel.id, to: newModel.id });
}
```

### Model Evaluation Framework

```typescript
interface ModelEvaluation {
  modelId: string;
  task: string;
  metrics: {
    latencyMs: number;
    tokensUsed: { input: number; output: number };
    cost: number;
    toolCallsSuccessRate: number;
    codeQualityScore?: number;  // If applicable
  };
  transcript: Message[];
  timestamp: Date;
}

// Run evaluation task
async function evaluateModel(modelId: string, task: EvalTask): Promise<ModelEvaluation> {
  const session = await createSession({ modelId, ephemeral: true });
  const startTime = Date.now();

  // Execute task
  for await (const event of session.run(task.prompt)) {
    // Collect metrics
  }

  return {
    modelId,
    task: task.name,
    metrics: {
      latencyMs: Date.now() - startTime,
      tokensUsed: session.tokenUsage,
      cost: session.totalCost,
      toolCallsSuccessRate: calculateToolSuccessRate(session.toolCalls),
    },
    transcript: session.messages,
    timestamp: new Date()
  };
}
```

### New Model Testing Workflow

```
1. Model Release Announced
         ↓
2. Add to Model Registry
   - Context window, pricing, capabilities
         ↓
3. Run Standard Eval Suite
   - File operations (read/write/edit)
   - Bash execution
   - Multi-step reasoning
   - Code generation quality
         ↓
4. Compare with Baseline
   - Speed, cost, quality metrics
   - Store in evaluation DB
         ↓
5. Optionally Set as Default
```

---

## 10. Implementation Recommendations

### Phase 1: Core Memory Layer

Start with the essential memory infrastructure:

```typescript
// memory/ledger.ts
interface Ledger {
  goal: string;
  constraints: string[];
  done: string[];
  now: string;
  next: string[];
  decisions: Array<{ choice: string; reason: string }>;
  workingFiles: string[];
  lastUpdated: Date;
}

class LedgerManager {
  private ledgerPath: string;

  async load(): Promise<Ledger>;
  async save(ledger: Ledger): Promise<void>;
  async update(partial: Partial<Ledger>): Promise<void>;
}
```

```typescript
// memory/handoff.ts
interface Handoff {
  sessionId: string;
  timestamp: Date;
  summary: string;
  codeChanges: Array<{ file: string; description: string }>;
  currentState: string;
  blockers: string[];
  nextSteps: string[];
  patterns: string[];
}

class HandoffManager {
  private db: Database;  // SQLite with FTS5

  async create(handoff: Handoff): Promise<string>;
  async search(query: string, limit?: number): Promise<Handoff[]>;
  async getRecent(n?: number): Promise<Handoff[]>;
}
```

### Phase 2: Hook System

Implement the hook infrastructure:

```typescript
// hooks/manager.ts
type HookEvent =
  | "session_start"
  | "session_end"
  | "pre_tool_use"
  | "post_tool_use"
  | "pre_compact"
  | "user_prompt";

interface HookHandler {
  event: HookEvent;
  matcher?: string;  // Tool name pattern
  handler: (input: HookInput) => Promise<HookOutput>;
  timeout?: number;
}

class HookManager {
  private hooks: Map<HookEvent, HookHandler[]> = new Map();

  register(hook: HookHandler): void;
  async trigger(event: HookEvent, context: object): Promise<HookOutput[]>;
}
```

### Phase 3: Session Manager with Memory Integration

```typescript
// session/manager.ts
class SessionManager {
  private sessions: Map<string, AgentSession> = new Map();
  private ledgerManager: LedgerManager;
  private handoffManager: HandoffManager;
  private hookManager: HookManager;

  async createSession(options: SessionOptions): Promise<AgentSession> {
    const session = new AgentSession(options);

    // Load memory on start
    const ledger = await this.ledgerManager.load();
    const recentHandoff = await this.handoffManager.getRecent(1);

    // Inject into context
    session.injectContext({
      ledger,
      handoff: recentHandoff[0],
    });

    // Register hooks
    session.on('pre_compact', () => this.autoHandoff(session));
    session.on('end', () => this.extractLearnings(session));

    this.sessions.set(session.id, session);
    return session;
  }

  private async autoHandoff(session: AgentSession): Promise<void> {
    const handoff = await session.generateHandoff();
    await this.handoffManager.create(handoff);
  }
}
```

### Phase 4: Always-On Server

```typescript
// server/index.ts
import { WebSocketServer } from 'ws';
import { SessionManager } from './session/manager';
import { RpcHandler } from './rpc/handler';

class AgentServer {
  private wss: WebSocketServer;
  private sessionManager: SessionManager;
  private rpcHandler: RpcHandler;

  async start(port: number): Promise<void> {
    this.wss = new WebSocketServer({ port });

    this.wss.on('connection', (ws, req) => {
      const sessionId = this.extractSessionId(req);
      const session = this.sessionManager.getOrCreate(sessionId);

      // Bridge WebSocket to RPC
      ws.on('message', async (data) => {
        const command = JSON.parse(data.toString());
        const response = await this.rpcHandler.handle(session, command);
        ws.send(JSON.stringify(response));
      });

      // Stream events to client
      session.on('*', (event) => {
        ws.send(JSON.stringify({ type: 'event', payload: event }));
      });
    });

    console.log(`Agent server running on port ${port}`);
  }
}

// Entry point
const server = new AgentServer();
server.start(3000);
```

### Phase 5: Multi-Model Support

```typescript
// models/provider.ts
interface LLMProvider {
  id: string;
  stream(context: Context, options: StreamOptions): AsyncIterable<StreamEvent>;
  complete(context: Context, options: StreamOptions): Promise<Message>;
}

class AnthropicProvider implements LLMProvider {
  // OAuth + API key support
}

class OpenAIProvider implements LLMProvider {
  // API key support
}

class ProviderFactory {
  static create(config: ModelConfig, auth: AuthCredentials): LLMProvider {
    switch (config.provider) {
      case "anthropic": return new AnthropicProvider(config, auth);
      case "openai": return new OpenAIProvider(config, auth);
      // ... more providers
    }
  }
}
```

---

## 11. Unified Architecture Design

### Complete System Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              ALWAYS-ON SERVER                                │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │                         Session Manager                                │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                   │ │
│  │  │  Session 1  │  │  Session 2  │  │  Session N  │                   │ │
│  │  │             │  │             │  │             │                   │ │
│  │  │  ┌───────┐  │  │  ┌───────┐  │  │  ┌───────┐  │                   │ │
│  │  │  │ Agent │  │  │  │ Agent │  │  │  │ Agent │  │                   │ │
│  │  │  │ Loop  │  │  │  │ Loop  │  │  │  │ Loop  │  │                   │ │
│  │  │  └───────┘  │  │  └───────┘  │  │  └───────┘  │                   │ │
│  │  │      │      │  │      │      │  │      │      │                   │ │
│  │  │  ┌───────┐  │  │  ┌───────┐  │  │  ┌───────┐  │                   │ │
│  │  │  │ Tools │  │  │  │ Tools │  │  │  │ Tools │  │                   │ │
│  │  │  └───────┘  │  │  └───────┘  │  │  └───────┘  │                   │ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘                   │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                          │                                                  │
│  ┌───────────────────────┴───────────────────────────────────────────────┐ │
│  │                         Memory Layer                                   │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │ │
│  │  │   Ledger    │  │  Handoffs   │  │  Episodic   │  │  Learnings  │  │ │
│  │  │  Manager    │  │   (FTS5)    │  │  (Vector)   │  │   (Global)  │  │ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘  │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                          │                                                  │
│  ┌───────────────────────┴───────────────────────────────────────────────┐ │
│  │                          Hook System                                   │ │
│  │  SessionStart │ PreToolUse │ PostToolUse │ PreCompact │ SessionEnd    │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                          │                                                  │
│  ┌───────────────────────┴───────────────────────────────────────────────┐ │
│  │                        Provider Layer                                  │ │
│  │  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌───────────┐          │ │
│  │  │ Anthropic │  │  OpenAI   │  │  Google   │  │  Local    │          │ │
│  │  │  (OAuth)  │  │ (API Key) │  │  (OAuth)  │  │ (Ollama)  │          │ │
│  │  └───────────┘  └───────────┘  └───────────┘  └───────────┘          │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
              │                              │                    │
              │ WebSocket                    │ WebSocket          │ Direct
              │                              │                    │
     ┌────────┴────────┐          ┌─────────┴────────┐   ┌──────┴──────┐
     │  Chat Interface │          │  Chat Interface  │   │  Terminal   │
     │    (Mobile)     │          │     (Web)        │   │   (SSH)     │
     │                 │          │                  │   │             │
     │  • Simple UX    │          │  • Full features │   │ • Power user│
     │  • Touch-first  │          │  • Model switch  │   │ • Raw access│
     │  • Voice input  │          │  • Cost tracking │   │ • Debugging │
     └─────────────────┘          └──────────────────┘   └─────────────┘
```

### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| State storage | SQLite | Portable, auditable, SQL queryable |
| Session persistence | JSONL | Append-only, easy inspection |
| Memory search | FTS5 + Vector | Full-text for exact, semantic for concept |
| Process model | Per-session subprocess | Isolation, clean restarts |
| Communication | WebSocket + RPC | Real-time events, structured commands |
| Auth storage | Encrypted JSON file | Simple, no external dependencies |

### Data Flow Example

```
User types "Fix the auth bug" on iPhone
                    │
                    ▼
┌─────────────────────────────────────────┐
│  WebSocket → Session Manager            │
│  Route to session by ID                 │
└─────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────┐
│  SessionStart Hook                      │
│  • Load ledger                          │
│  • Load recent handoff                  │
│  • Search episodic memory for "auth"    │
│  • Inject relevant context              │
└─────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────┐
│  Agent Loop                             │
│  • Stream to Claude                     │
│  • Execute tools (read, edit, bash)     │
│  • Emit events via WebSocket            │
└─────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────┐
│  PostToolUse Hooks                      │
│  • Index modified files                 │
│  • Track patterns                       │
│  • Check context usage                  │
└─────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────┐
│  Context at 80%: PreCompact Hook        │
│  • Auto-generate handoff                │
│  • Save to SQLite with FTS5             │
│  • Warn user via WebSocket              │
└─────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────┐
│  User says "done for today"             │
│  SessionEnd Hook                        │
│  • Extract learnings                    │
│  • Update global memory                 │
│  • Clean up temp files                  │
└─────────────────────────────────────────┘
```

---

## Conclusions

### Key Takeaways

1. **"Clear, don't compact"** is the fundamental insight—controlled clearing with lossless persistence beats lossy compression

2. **Four-level memory hierarchy** (immediate → session → project → global) provides the right granularity for different information types

3. **Hooks are essential** for automating memory operations without manual intervention

4. **SQLite is the right choice** for agent state—portable, queryable, snapshotable

5. **Dual-interface works** when the core exposes events via RPC/WebSocket—both terminal and chat consume the same state

6. **Multi-model testing** is straightforward with a provider abstraction layer and standardized evaluation framework

### Recommended Implementation Order

1. **Week 1**: Core agent loop with Claude-only provider
2. **Week 2**: Ledger + handoff system with SQLite persistence
3. **Week 3**: Hook system with SessionStart/PreCompact/SessionEnd
4. **Week 4**: Always-on server with WebSocket bridge
5. **Week 5**: Chat interface (start simple, iterate)
6. **Week 6**: Multi-model support (add providers incrementally)
7. **Ongoing**: Episodic memory, learnings extraction, evaluation framework

### Success Metrics

- Sessions can run 100+ exchanges without degradation
- Context clears are seamless (< 2s reload time)
- Model switching preserves conversation continuity
- Chat interface usable by non-technical users
- New models testable within hours of release

---

## References

### Primary Sources

- [Continuous-Claude-v2](https://github.com/parcadei/Continuous-Claude-v2) - Ledger/handoff architecture
- [Letta Documentation](https://docs.letta.com/) - Memory blocks pattern
- [AgentFS](https://github.com/tursodatabase/agentfs) - SQLite as agent runtime
- [Episodic Memory Plugin](https://blog.fsck.com/2025/10/23/episodic-memory/) - Vector search over sessions
- [How I Use Every Claude Code Feature](https://blog.sshh.io/p/how-i-use-every-claude-code-feature) - Best practices

### Related Research

- [Manage Claude's Memory](https://code.claude.com/docs/en/memory) - Official documentation
- [Context Management in Claude Code](https://angelo-lima.fr/en/claude-code-context-memory-management/)
- [Claude Code Best Practices: Memory Management](https://cuong.io/blog/2025/06/15-claude-code-best-practices-memory-management)
- [Letta Code Blog](https://www.letta.com/blog/letta-code) - Memory-first coding agents

### Previous Research

- [Dual-Interface Coding Agent Architecture](./2025-12-31_dual-interface-coding-agent-architecture.md) - pi-mono analysis
