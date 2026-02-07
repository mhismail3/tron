# Agent Architecture

## Overview

The agent package (`@tron/agent`) is the core backend for Tron. It handles:
- LLM communication via providers (Anthropic, OpenAI, Google)
- Tool execution (read, write, edit, bash, grep, etc.)
- Event-sourced session persistence
- Context management and compaction
- Sub-agent spawning and coordination
- WebSocket server for clients

## System Architecture

### High-Level Overview

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                      CLIENTS                                             │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐    │
│  │    iOS App      │  │    TUI CLI      │  │    Web Chat     │  │   External API  │    │
│  │  (SwiftUI)      │  │  (Ink/React)    │  │    (React)      │  │    Consumers    │    │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘    │
└───────────┼─────────────────────┼─────────────────────┼─────────────────────┼───────────┘
            │                     │                     │                     │
            └──────────────────────┬──────────────────────┬────────────────────┘
                                   │ WebSocket / HTTP     │
                                   ▼                      ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              INTERFACE LAYER                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│  │                           TronServer (server.ts)                                 │   │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────────────┐  │   │
│  │  │  HTTP Server    │  │ WebSocket       │  │      RPC Handler                │  │   │
│  │  │  (Hono)         │  │ Gateway         │  │  ┌─────────────────────────┐    │  │   │
│  │  │  - /health      │  │ - Connection    │  │  │    MethodRegistry       │    │  │   │
│  │  │  - /api/*       │  │   management    │  │  │  - Validation           │    │  │   │
│  │  │                 │  │ - Event         │  │  │  - Middleware chain     │    │  │   │
│  │  │                 │  │   broadcasting  │  │  │  - Namespace routing    │    │  │   │
│  │  └─────────────────┘  └─────────────────┘  │  └─────────────────────────┘    │  │   │
│  │                                            │  ┌─────────────────────────┐    │  │   │
│  │                                            │  │   Domain Handlers       │    │  │   │
│  │                                            │  │  - session.*            │    │  │   │
│  │                                            │  │  - agent.*              │    │  │   │
│  │                                            │  │  - model.*              │    │  │   │
│  │                                            │  │  - context.*            │    │  │   │
│  │                                            │  │  - events.*             │    │  │   │
│  │                                            │  └─────────────────────────┘    │  │   │
│  │                                            └─────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────┬─────────────────────────────────────────┘
                                                │
                                                ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              RUNTIME LAYER                                               │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│  │                      Event Store Orchestrator                                    │   │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────────────┐  │   │
│  │  │ Session Manager │  │  Agent Manager  │  │      Controllers                │  │   │
│  │  │ - create/fork   │  │ - spawn agents  │  │  - BrowserController            │  │   │
│  │  │ - resume/delete │  │ - abort/status  │  │  - NotificationController       │  │   │
│  │  │ - list/get      │  │ - message queue │  │  - WorktreeController           │  │   │
│  │  └─────────────────┘  └─────────────────┘  └─────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                │                                        │
│                                                ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│  │                           TronAgent (Agent Runner)                               │   │
│  │  ┌───────────────────────────────────────────────────────────────────────────┐  │   │
│  │  │                          Turn Execution Loop                               │  │   │
│  │  │                                                                            │  │   │
│  │  │   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐           │  │   │
│  │  │   │ Context  │───▶│ LLM Call │───▶│ Response │───▶│  Tool    │──┐        │  │   │
│  │  │   │ Assembly │    │          │    │ Parse    │    │ Executor │  │        │  │   │
│  │  │   └──────────┘    └──────────┘    └──────────┘    └──────────┘  │        │  │   │
│  │  │        ▲                                               │         │        │  │   │
│  │  │        └───────────────────────────────────────────────┘         │        │  │   │
│  │  │                         (loop until done)                        │        │  │   │
│  │  │                                                                  ▼        │  │   │
│  │  │                                                          ┌──────────┐    │  │   │
│  │  │                                                          │  Event   │    │  │   │
│  │  │                                                          │ Recording│    │  │   │
│  │  │                                                          └──────────┘    │  │   │
│  │  └───────────────────────────────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────┬─────────────────────────────────────────┘
                                                │
            ┌───────────────────────────────────┼───────────────────────────────────┐
            │                                   │                                   │
            ▼                                   ▼                                   ▼
┌───────────────────────┐       ┌───────────────────────┐       ┌───────────────────────┐
│   CAPABILITIES        │       │      LLM LAYER        │       │   CONTEXT LAYER       │
│  ┌─────────────────┐  │       │  ┌─────────────────┐  │       │  ┌─────────────────┐  │
│  │     Tools       │  │       │  │    Providers    │  │       │  │  System Prompt  │  │
│  │  ┌───────────┐  │  │       │  │  ┌───────────┐  │  │       │  │  Templates      │  │
│  │  │ fs/       │  │  │       │  │  │ Anthropic │  │  │       │  └─────────────────┘  │
│  │  │ browser/  │  │  │       │  │  │ Google    │  │  │       │  ┌─────────────────┐  │
│  │  │ subagent/ │  │  │       │  │  │ OpenAI    │  │  │       │  │  Rules Tracker  │  │
│  │  │ ui/       │  │  │       │  │  └───────────┘  │  │       │  │  (AGENTS.md)    │  │
│  │  │ system/   │  │  │       │  │  ┌───────────┐  │  │       │  └─────────────────┘  │
│  │  │ search/   │  │  │       │  │  │ Token     │  │  │       │  ┌─────────────────┐  │
│  │  └───────────┘  │  │       │  │  │ Normalizer│  │  │       │  │  Compaction     │  │
│  └─────────────────┘  │       │  │  └───────────┘  │  │       │  │  Engine         │  │
│  ┌─────────────────┐  │       │  └─────────────────┘  │       │  └─────────────────┘  │
│  │   Extensions    │  │       └───────────────────────┘       └───────────────────────┘
│  │  ┌───────────┐  │  │
│  │  │ Hooks     │  │  │
│  │  │ Skills    │  │  │
│  │  │ Commands  │  │  │
│  │  └───────────┘  │  │
│  └─────────────────┘  │
│  ┌─────────────────┐  │
│  │   Guardrails    │  │
│  └─────────────────┘  │
└───────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                            INFRASTRUCTURE LAYER                                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │
│  │   Logging   │  │  Settings   │  │    Auth     │  │   Events    │  │    Usage    │   │
│  │   (Pino +   │  │  Provider   │  │  (Unified   │  │   Factory   │  │  Tracking   │   │
│  │   SQLite)   │  │             │  │  sync/async)│  │             │  │             │   │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘   │
└───────────────────────────────────────────────────────────────────────────────────────────┘
                                                │
                                                ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              PERSISTENCE LAYER                                           │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│  │                         Event Store (SQLite)                                     │   │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────────────┐  │   │
│  │  │    events       │  │    sessions     │  │         workspaces              │  │   │
│  │  │  - id           │  │  - id           │  │  - id                           │  │   │
│  │  │  - parent_id    │  │  - head_event_id│  │  - path                         │  │   │
│  │  │  - session_id   │  │  - root_event_id│  │  - name                         │  │   │
│  │  │  - sequence     │  │  - status       │  │                                 │  │   │
│  │  │  - type         │  │  - model        │  │                                 │  │   │
│  │  │  - payload      │  │  - provider     │  │                                 │  │   │
│  │  └─────────────────┘  └─────────────────┘  └─────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                         │
│  Location: ~/.tron/database/{prod,dev,test}.db                                               │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

### Request Flow (Turn Execution)

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              COMPLETE REQUEST FLOW                                       │
└─────────────────────────────────────────────────────────────────────────────────────────┘

  Client                    Server                     Agent                    LLM
    │                         │                         │                        │
    │  1. agent.message       │                         │                        │
    │  {sessionId, content}   │                         │                        │
    │ ───────────────────────▶│                         │                        │
    │                         │                         │                        │
    │                         │  2. Validate request    │                        │
    │                         │     (MethodRegistry)    │                        │
    │                         │                         │                        │
    │                         │  3. UserPromptSubmit    │                        │
    │                         │     hook (blocking)     │                        │
    │                         │                         │                        │
    │                         │  4. Queue message       │                        │
    │                         │ ───────────────────────▶│                        │
    │                         │                         │                        │
    │                         │                         │  5. Record             │
    │                         │                         │     message.user       │
    │                         │                         │     event              │
    │                         │                         │                        │
    │                         │                         │  6. Build context      │
    │                         │                         │     - System prompt    │
    │                         │                         │     - AGENTS.md rules  │
    │                         │                         │     - Skills           │
    │                         │                         │     - History          │
    │                         │                         │                        │
    │                         │                         │  7. Call LLM           │
    │                         │                         │ ──────────────────────▶│
    │                         │                         │                        │
    │                         │                         │  8. Stream response    │
    │  9. text_delta events   │                         │◀──────────────────────│
    │◀─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│◀─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│                        │
    │                         │                         │                        │
    │                         │                         │  10. Parse tool calls  │
    │                         │                         │      (if any)          │
    │                         │                         │                        │
    │                         │                         │  ┌──────────────────┐  │
    │                         │                         │  │ FOR EACH TOOL:   │  │
    │                         │                         │  │                  │  │
    │  11. tool_start event   │                         │  │ a. PreToolUse    │  │
    │◀─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│◀─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│  │    hook          │  │
    │                         │                         │  │    (blocking)    │  │
    │                         │                         │  │                  │  │
    │                         │                         │  │ b. Execute tool  │  │
    │                         │                         │  │                  │  │
    │                         │                         │  │ c. Record        │  │
    │                         │                         │  │    tool.call +   │  │
    │                         │                         │  │    tool.result   │  │
    │                         │                         │  │                  │  │
    │  12. tool_end event     │                         │  │ d. PostToolUse   │  │
    │◀─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│◀─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│  │    hook (bg)     │  │
    │                         │                         │  └──────────────────┘  │
    │                         │                         │                        │
    │                         │                         │  13. Loop to step 7    │
    │                         │                         │      if more tools     │
    │                         │                         │                        │
    │                         │                         │  14. Record            │
    │                         │                         │      message.assistant │
    │                         │                         │                        │
    │                         │                         │  15. Stop hook (bg)    │
    │                         │                         │                        │
    │  16. turn_complete      │                         │                        │
    │◀─────────────────────────────────────────────────│                        │
    │                         │                         │                        │
```

### Hook System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              HOOK SYSTEM ARCHITECTURE                                    │
└─────────────────────────────────────────────────────────────────────────────────────────┘

                              ┌─────────────────────────────────────┐
                              │           HookEngine                │
                              │         (Orchestrator)              │
                              │                                     │
                              │  • execute(type, context)           │
                              │  • executeWithEvents(...)           │
                              │  • waitForBackgroundHooks()         │
                              └───────────────┬─────────────────────┘
                                              │
                        ┌─────────────────────┴─────────────────────┐
                        │                                           │
                        ▼                                           ▼
          ┌─────────────────────────────┐           ┌─────────────────────────────┐
          │       HookRegistry          │           │     BackgroundTracker       │
          │                             │           │                             │
          │  • register(definition)     │           │  • track(id, promise)       │
          │  • unregister(name)         │           │  • getPendingCount()        │
          │  • getByType(type)          │           │  • waitForAll(timeout)      │
          │    → sorted by priority     │           │                             │
          └─────────────────────────────┘           └─────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                HOOK EXECUTION FLOW                                       │
└─────────────────────────────────────────────────────────────────────────────────────────┘

  BLOCKING HOOKS                                    BACKGROUND HOOKS
  (must complete before continuing)                 (fire-and-forget, fail-open)

  ┌─────────────────────────────────┐              ┌─────────────────────────────────┐
  │ PreToolUse                      │              │ PostToolUse                     │
  │ UserPromptSubmit                │              │ SessionStart                    │
  │ PreCompact                      │              │ SessionEnd                      │
  │                                 │              │ Stop                            │
  │ Returns:                        │              │ SubagentStop                    │
  │ • { proceed: true }             │              │                                 │
  │ • { blocked: true, reason }     │              │ Errors: logged but don't fail   │
  │ • { proceed: true, modified }   │              │ the operation                   │
  └─────────────────────────────────┘              └─────────────────────────────────┘

  Priority Ordering (highest first):

  ┌──────────────────────────────────────────────────────────────────────────────────────┐
  │  priority: 100  │  security-check     │  ──▶  Runs first                             │
  │  priority: 50   │  audit-logger       │  ──▶  Runs second                            │
  │  priority: 0    │  default-handler    │  ──▶  Runs third (default)                   │
  │  priority: -10  │  cleanup-hook       │  ──▶  Runs last                              │
  └──────────────────────────────────────────────────────────────────────────────────────┘
```

### Event Sourcing Model

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              EVENT SOURCING MODEL                                        │
└─────────────────────────────────────────────────────────────────────────────────────────┘

  SESSION STATE = f(events from root to head)

  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │                                EVENT TREE                                            │
  │                                                                                      │
  │                     [session.start]  ◀─── rootEventId (Session A)                   │
  │                           │                                                          │
  │                           │ parentId                                                 │
  │                           ▼                                                          │
  │                     [message.user]                                                   │
  │                     "Hello, help me"                                                 │
  │                           │                                                          │
  │                           │ parentId                                                 │
  │                           ▼                                                          │
  │                   [message.assistant]                                                │
  │                   "I'll help you..."                                                 │
  │                           │                                                          │
  │                           │ parentId                                                 │
  │                           ▼                                                          │
  │                     [message.user]  ◀─── FORK POINT                                 │
  │                     "Read file.ts"                                                   │
  │                           │                                                          │
  │           ┌───────────────┴───────────────┐                                         │
  │           │ parentId                      │ parentId                                │
  │           ▼                               ▼                                          │
  │   [message.assistant]              [session.fork]  ◀─── rootEventId (Session B)     │
  │   "Let me read that"               sourceEventId ──────▶                            │
  │           │                               │                                          │
  │           │ parentId                      │ parentId                                │
  │           ▼                               ▼                                          │
  │      [tool.call]                   [message.user]                                   │
  │      name: "Read"                  "Actually, read other.ts"                        │
  │           │                               │                                          │
  │           │ parentId                      │ parentId                                │
  │           ▼                               ▼                                          │
  │     [tool.result]                 [message.assistant]                               │
  │     content: "..."                "Reading other.ts..."                             │
  │           │                               │                                          │
  │           ▼                               ▼                                          │
  │   [message.assistant]  ◀─── headEventId (A)                                         │
  │   "Here's the file..."            [tool.call]  ◀─── headEventId (B)                │
  │                                                                                      │
  └─────────────────────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │                           SESSION POINTERS                                           │
  │                                                                                      │
  │   Session A:                           Session B:                                    │
  │   ┌────────────────────────┐           ┌────────────────────────┐                   │
  │   │ id: sess_abc123        │           │ id: sess_def456        │                   │
  │   │ rootEventId: evt_001   │           │ rootEventId: evt_fork  │                   │
  │   │ headEventId: evt_007   │           │ headEventId: evt_010   │                   │
  │   │ status: active         │           │ status: active         │                   │
  │   └────────────────────────┘           └────────────────────────┘                   │
  │                                                                                      │
  │   State Reconstruction:                                                              │
  │   1. Start at headEventId                                                            │
  │   2. Walk parentId chain to root                                                     │
  │   3. Reverse to get chronological order                                              │
  │   4. Apply events to build message history                                           │
  │                                                                                      │
  └─────────────────────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │                           OPERATIONS                                                 │
  │                                                                                      │
  │   FORK:                                  REWIND:                                     │
  │   ┌─────────────────────────────┐       ┌─────────────────────────────┐             │
  │   │ 1. Create session.fork event│       │ 1. Move headEventId back    │             │
  │   │    with parentId pointing   │       │ 2. Events after head become │             │
  │   │    to branch point          │       │    orphaned (still in DB)   │             │
  │   │ 2. New session root = fork  │       │ 3. Can fork from new head   │             │
  │   │ 3. Original unchanged       │       │    to explore alternatives  │             │
  │   └─────────────────────────────┘       └─────────────────────────────┘             │
  │                                                                                      │
  └─────────────────────────────────────────────────────────────────────────────────────┘
```

### RPC Handler Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              RPC HANDLER ARCHITECTURE                                    │
└─────────────────────────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │                              METHOD REGISTRY                                         │
  │                                                                                      │
  │   ┌─────────────────────────────────────────────────────────────────────────────┐   │
  │   │                         Registration                                         │   │
  │   │                                                                              │   │
  │   │   registry.register('session.create', handler, {                            │   │
  │   │     requiredParams: ['workingDirectory'],        ◀── Validated before call  │   │
  │   │     requiredManagers: ['sessionManager'],        ◀── Checked for existence  │   │
  │   │     description: 'Create a new session',                                     │   │
  │   │   });                                                                        │   │
  │   │                                                                              │   │
  │   └─────────────────────────────────────────────────────────────────────────────┘   │
  │                                                                                      │
  │   ┌─────────────────────────────────────────────────────────────────────────────┐   │
  │   │                         Dispatch Flow                                        │   │
  │   │                                                                              │   │
  │   │   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐             │   │
  │   │   │  Find    │───▶│ Validate │───▶│Middleware│───▶│ Execute  │             │   │
  │   │   │ Handler  │    │  Params  │    │  Chain   │    │ Handler  │             │   │
  │   │   └──────────┘    └──────────┘    └──────────┘    └──────────┘             │   │
  │   │        │               │               │               │                    │   │
  │   │        ▼               ▼               ▼               ▼                    │   │
  │   │   -32601 if      -32602 if       Cross-cutting    Returns result           │   │
  │   │   not found      missing         concerns          directly                 │   │
  │   │                                  (logging,etc)                              │   │
  │   └─────────────────────────────────────────────────────────────────────────────┘   │
  │                                                                                      │
  │   ┌─────────────────────────────────────────────────────────────────────────────┐   │
  │   │                         Namespace Organization                               │   │
  │   │                                                                              │   │
  │   │   session.*                          agent.*                                 │   │
  │   │   ├── session.create                 ├── agent.message                       │   │
  │   │   ├── session.get                    ├── agent.abort                         │   │
  │   │   ├── session.list                   └── agent.respond                       │   │
  │   │   ├── session.fork                                                           │   │
  │   │   └── session.delete                 model.*                                 │   │
  │   │                                      ├── model.list                          │   │
  │   │   context.*                          └── model.switch                        │   │
  │   │   ├── context.get                                                            │   │
  │   │   └── context.compact                events.*                                │   │
  │   │                                      ├── events.list                         │   │
  │   │                                      └── events.sync                         │   │
  │   └─────────────────────────────────────────────────────────────────────────────┘   │
  │                                                                                      │
  └─────────────────────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │                              ERROR HIERARCHY                                         │
  │                                                                                      │
  │                                   RpcError                                           │
  │                                      │                                               │
  │            ┌─────────────┬───────────┼───────────┬─────────────┐                    │
  │            │             │           │           │             │                    │
  │            ▼             ▼           ▼           ▼             ▼                    │
  │   ┌─────────────┐ ┌───────────┐ ┌─────────┐ ┌─────────┐ ┌───────────┐              │
  │   │SessionNot   │ │SessionNot │ │Manager  │ │AgentBusy│ │Validation │              │
  │   │FoundError   │ │ActiveError│ │NotAvail │ │Error    │ │Error      │              │
  │   │  -32000     │ │  -32001   │ │ -32002  │ │ -32003  │ │ -32602    │              │
  │   └─────────────┘ └───────────┘ └─────────┘ └─────────┘ └───────────┘              │
  │                                                                                      │
  │   Error Response:                                                                    │
  │   {                                                                                  │
  │     error: {                                                                         │
  │       code: -32000,                                                                  │
  │       message: "Session not found: sess_abc",                                        │
  │       data: { category: "client_error", retryable: false }                          │
  │     }                                                                                │
  │   }                                                                                  │
  │                                                                                      │
  └─────────────────────────────────────────────────────────────────────────────────────┘
```

### Tool Execution Detail

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              TOOL EXECUTION FLOW                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘

  LLM Response with tool_use block:
  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │  {                                                                                   │
  │    "type": "tool_use",                                                               │
  │    "id": "toolu_abc123",                                                             │
  │    "name": "Read",                                                                   │
  │    "input": { "file_path": "/path/to/file.ts" }                                     │
  │  }                                                                                   │
  └─────────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │  1. PRE-TOOL-USE HOOK (Blocking)                                                     │
  │                                                                                      │
  │  Context created via HookContextFactory:                                             │
  │  ┌───────────────────────────────────────┐                                          │
  │  │ {                                     │                                          │
  │  │   hookType: 'PreToolUse',             │                                          │
  │  │   sessionId: 'sess_abc',              │                                          │
  │  │   timestamp: '2026-02-01T...',        │  ◀── Auto-generated                      │
  │  │   toolName: 'Read',                   │                                          │
  │  │   toolInput: { file_path: '...' },    │                                          │
  │  │   toolId: 'toolu_abc123'              │                                          │
  │  │ }                                     │                                          │
  │  └───────────────────────────────────────┘                                          │
  │                                                                                      │
  │  Possible returns:                                                                   │
  │  • { proceed: true }                       → Continue to execution                   │
  │  • { blocked: true, reason: '...' }        → Skip tool, return block message         │
  │  • { proceed: true, modifiedInput: {...} } → Execute with modified args              │
  └─────────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │  2. TOOL EXECUTION                                                                   │
  │                                                                                      │
  │  Tool Lookup:                                                                        │
  │  ┌────────────────────────────────────────────────────────────────────────────────┐ │
  │  │ tools/                                                                          │ │
  │  │ ├── fs/         → Read, Write, Edit, Glob, Grep                                │ │
  │  │ ├── browser/    → Browser automation tools                                      │ │
  │  │ ├── subagent/   → Task (spawn subagent)                                        │ │
  │  │ ├── ui/         → AskUser, Notify, TodoWrite                                   │ │
  │  │ ├── system/     → Bash, Thinking                                               │ │
  │  │ └── search/     → Code search tools                                            │ │
  │  └────────────────────────────────────────────────────────────────────────────────┘ │
  │                                                                                      │
  │  Execute with context:                                                               │
  │  • AbortSignal for cancellation                                                      │
  │  • Session context (working directory, etc.)                                         │
  │  • Tool-specific options from settings                                               │
  └─────────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │  3. EVENT RECORDING                                                                  │
  │                                                                                      │
  │  Events created via EventFactory:                                                    │
  │                                                                                      │
  │  tool.call event:                        tool.result event:                          │
  │  ┌──────────────────────────┐           ┌──────────────────────────┐                │
  │  │ id: evt_xxx (generated)  │           │ id: evt_yyy (generated)  │                │
  │  │ parentId: evt_prev       │           │ parentId: evt_xxx        │                │
  │  │ type: 'tool.call'        │           │ type: 'tool.result'      │                │
  │  │ timestamp: (generated)   │           │ timestamp: (generated)   │                │
  │  │ payload: {               │           │ payload: {               │                │
  │  │   name: 'Read',          │           │   toolId: 'toolu_abc',   │                │
  │  │   arguments: {...},      │           │   content: '...',        │                │
  │  │   toolId: 'toolu_abc'    │           │   isError: false,        │                │
  │  │ }                        │           │   duration: 45           │                │
  │  └──────────────────────────┘           └──────────────────────────┘                │
  │                                                                                      │
  │  NOTE: tool.result recorded BEFORE message.assistant                                 │
  │        (required for proper message reconstruction)                                  │
  └─────────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │  4. POST-TOOL-USE HOOK (Background)                                                  │
  │                                                                                      │
  │  Context:                                                                            │
  │  ┌───────────────────────────────────────┐                                          │
  │  │ {                                     │                                          │
  │  │   hookType: 'PostToolUse',            │                                          │
  │  │   sessionId: 'sess_abc',              │                                          │
  │  │   timestamp: '...',                   │                                          │
  │  │   toolName: 'Read',                   │                                          │
  │  │   toolResult: { content, isError },   │                                          │
  │  │   duration: 45                        │                                          │
  │  │ }                                     │                                          │
  │  └───────────────────────────────────────┘                                          │
  │                                                                                      │
  │  Execution: Async, fire-and-forget, errors logged but don't fail                    │
  │  Use cases: Logging, metrics, external integrations                                  │
  └─────────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
                              Return to LLM with tool_result
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
│   ├── auth/                # API key management (unified sync/async)
│   ├── communication/       # Inter-agent messaging bus
│   ├── usage/               # Token/cost tracking
│   └── events/              # Event store, SQLite backend, EventFactory
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
│   │   ├── hooks/           # HookEngine, HookRegistry, BackgroundTracker
│   │   ├── skills/          # Skill loader, registry
│   │   └── commands/        # Custom commands
│   ├── guardrails/          # Safety guardrails
│   └── todos/               # Task management
│
├── interface/               # External Interfaces
│   ├── server.ts            # TronServer entry point
│   ├── http/                # HTTP server (Hono)
│   ├── gateway/             # WebSocket gateway
│   ├── rpc/                 # RPC protocol, handlers, MethodRegistry
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

## Key Architectural Patterns

### Registry Pattern

The RPC system uses a registry pattern for method dispatch with automatic validation:

```typescript
// Handler registration with validation rules
registry.register('session.create', handler, {
  requiredParams: ['workingDirectory'],
  requiredManagers: ['sessionManager'],
});

// Dispatch handles validation automatically
const response = await registry.dispatch(request, context);
```

**Benefits:**
- Eliminates repeated validation boilerplate across handlers
- Centralized error handling with typed RPC errors
- Middleware support for cross-cutting concerns
- Namespace-based method organization

**Key files:** `interface/rpc/registry.ts`, `interface/rpc/handlers/`

### Factory Pattern

Factories ensure consistent object construction with automatic field generation:

**EventFactory** (`infrastructure/events/event-factory.ts`):
```typescript
const factory = createEventFactory({ sessionId, workspaceId });
const event = factory.createSessionStart({
  parentId,
  sequence,
  payload: { workingDirectory, model, provider },
});
// Auto-generates: id (evt_xxx), timestamp (ISO 8601)
```

**HookContextFactory** (`capabilities/extensions/hooks/context-factory.ts`):
```typescript
const factory = createHookContextFactory({ sessionId });
const context = factory.createPreToolContext({
  toolName: 'bash',
  toolInput: { command: 'ls' },
});
// Auto-generates: timestamp, hookType, sessionId
```

### Component Extraction

Large classes are decomposed into focused components:

**HookEngine decomposition:**
```
HookEngine (orchestration)
    ├── HookRegistry (registration, lookup, priority sorting)
    └── BackgroundTracker (pending background hook tracking)
```

**Key principle:** Each component has a single responsibility. The parent class delegates to components rather than containing all logic.

### Type-Safe Event Broadcasting

Event broadcasting uses typed enums to prevent string typos:

```typescript
import { BroadcastEventType } from './event-envelope.js';

// Type-safe event creation
const envelope = createEventEnvelope(
  BroadcastEventType.SESSION_CREATED,
  { sessionId, workingDirectory },
);
```

**Available types:** `SESSION_CREATED`, `SESSION_ENDED`, `AGENT_TURN`, `TOOL_START`, `TOOL_END`, etc.

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
| Registry pattern | Eliminate handler boilerplate, centralize validation |
| Factory pattern | Consistent object construction, reduce duplication |
| Component extraction | Single responsibility, testable units |
| Type-safe enums | Compile-time validation, prevent string typos |
