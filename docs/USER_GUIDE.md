# Tron Agent - Complete User Guide

This guide covers all implemented features, commands, and workflows for the Tron persistent dual-interface coding agent.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Architecture Overview](#architecture-overview)
3. [CLI Commands](#cli-commands)
4. [Slash Commands](#slash-commands)
5. [Session Management](#session-management)
6. [Memory System](#memory-system)
7. [Model Switching](#model-switching)
8. [Tool System](#tool-system)
9. [Hook System](#hook-system)
10. [Skill System](#skill-system)
11. [Context Loading](#context-loading)
12. [RPC Protocol](#rpc-protocol)
13. [Server & WebSocket](#server--websocket)
14. [Web Interface](#web-interface)
15. [Productivity Features](#productivity-features)
16. [Configuration](#configuration)

---

## Quick Start

### Installation

```bash
# Clone and install
git clone <repo>
cd tron
npm install
npm run build

# Start the TUI
npm run tui

# Or start the server (for web interface)
npm run server
```

### First Run

```bash
# Authenticate with Claude Max OAuth
tron login

# Check authentication status
tron auth-status

# Start an interactive session
tron
```

---

## Architecture Overview

### Package Structure

```
packages/
├── core/           # Core agent logic, tools, memory, hooks, skills
├── server/         # WebSocket server, session orchestration
├── tui/            # Terminal UI (React/Ink)
└── chat-web/       # Web chat interface (React)
```

### Key Components

| Component | Description |
|-----------|-------------|
| `TronAgent` | Main agent loop with streaming, tool execution |
| `SessionManager` | Create, persist, fork, rewind sessions |
| `LedgerManager` | Working memory (goal, now, next, decisions) |
| `HandoffManager` | Episodic memory with FTS5 search |
| `HookEngine` | Lifecycle hooks with priority ordering |
| `SkillRegistry` | Skill discovery and execution |
| `CommandRouter` | Slash command routing |
| `RpcHandler` | JSON-RPC protocol handler |
| `SessionOrchestrator` | Multi-session management |

---

## CLI Commands

### Authentication

```bash
# OAuth login to Claude Max
tron login

# Logout and clear credentials
tron logout

# Check current auth status
tron auth-status
```

### Session Control

```bash
# Start new interactive session
tron

# Resume most recent session
tron --continue
tron -c

# Resume specific session
tron --resume <session-id>
tron -r <session-id>

# Run without persistence
tron --no-session

# Run in specific directory
tron --cwd /path/to/project
```

### Model Selection

```bash
# Use specific model
tron --model claude-opus-4-20250514
tron --model claude-sonnet-4-20250514
tron --model gpt-4o
tron --model gemini-pro

# Use specific provider
tron --provider anthropic
tron --provider openai
tron --provider google
```

### Output Control

```bash
# Verbose output
tron --verbose
tron -v

# Quiet mode
tron --quiet
tron -q

# JSON output
tron --json
```

---

## Slash Commands

All slash commands can be invoked during a session by typing `/command [args]`.

### Session Commands

| Command | Description | Example |
|---------|-------------|---------|
| `/clear` | Clear conversation context | `/clear` |
| `/fork` | Fork current session | `/fork` |
| `/rewind <n>` | Rewind to message n | `/rewind 5` |
| `/export` | Export transcript | `/export` |
| `/export markdown` | Export as markdown | `/export markdown` |
| `/export html` | Export as HTML | `/export html` |

### Model Commands

| Command | Description | Example |
|---------|-------------|---------|
| `/model` | Show current model | `/model` |
| `/model <name>` | Switch to model | `/model gpt-4o` |
| `/models` | List available models | `/models` |

### Memory Commands

| Command | Description | Example |
|---------|-------------|---------|
| `/ledger` | Show current ledger | `/ledger` |
| `/ledger update` | Update ledger | `/ledger update` |
| `/handoff` | Create handoff | `/handoff` |
| `/handoffs` | List recent handoffs | `/handoffs` |
| `/search <query>` | Search handoffs | `/search auth bug` |

### Context Commands

| Command | Description | Example |
|---------|-------------|---------|
| `/context` | Show context usage | `/context` |
| `/compact` | Compact context | `/compact` |

### Skill Commands

| Command | Description | Example |
|---------|-------------|---------|
| `/skills` | List available skills | `/skills` |
| `/skill <name>` | Execute skill | `/skill commit` |
| `/commit` | Git commit skill | `/commit` |

### Help Commands

| Command | Description | Example |
|---------|-------------|---------|
| `/help` | Show help | `/help` |
| `/help <command>` | Help for command | `/help model` |
| `/version` | Show version | `/version` |

---

## Session Management

### Session Lifecycle

Sessions are persisted as JSONL files in `.tron/sessions/`. Each message is appended as a JSON line.

```typescript
// Create a new session
const session = await sessionManager.createSession({
  workingDirectory: '/path/to/project',
  model: 'claude-sonnet-4-20250514',
  provider: 'anthropic',
});

// List sessions
const sessions = await sessionManager.listSessions({
  workingDirectory: '/path/to/project',
  limit: 10,
});

// Get specific session
const session = await sessionManager.getSession(sessionId);

// Add message
await sessionManager.addMessage(sessionId, {
  role: 'user',
  content: 'Hello!',
});

// End session
await sessionManager.endSession(sessionId, 'completed');
```

### Session Fork

Forking creates a new session with copied messages, enabling parallel experimentation:

```typescript
// Fork entire session
const result = await sessionManager.forkSession({
  sessionId: 'sess_abc123',
});
// result.newSessionId = 'sess_xyz789'
// result.messageCount = 10
// result.forkedFrom = 'sess_abc123'

// Fork from specific point (first 5 messages only)
const result = await sessionManager.forkSession({
  sessionId: 'sess_abc123',
  fromIndex: 5,
});
```

### Session Rewind

Rewinding truncates a session to an earlier state:

```typescript
// Rewind to message 3 (removes messages 4+)
const result = await sessionManager.rewindSession({
  sessionId: 'sess_abc123',
  toIndex: 3,
});
// result.newMessageCount = 3
// result.removedCount = 7
```

### Cross-Interface Continuity

Sessions can be started in one interface and continued in another:

1. **Terminal → Web**: Start session in TUI, note session ID, open web and connect to same session
2. **Web → Terminal**: Create session in web, use `tron -r <session-id>` in terminal
3. **Fork for experimentation**: Fork session, try different approach, compare results

---

## Memory System

### Four-Level Memory Hierarchy

| Level | Name | Scope | Storage | Purpose |
|-------|------|-------|---------|---------|
| 1 | Immediate | In-context | Messages array | Current conversation |
| 2 | Session | Ledger | Markdown file | Goal, focus, decisions |
| 3 | Project | Handoffs | SQLite + FTS5 | Past session summaries |
| 4 | Global | Learnings | Markdown files | Cross-project patterns |

### Ledger (Working Memory)

The ledger tracks session state and drives the status line:

```markdown
# Continuity Ledger

## Goal
Implement OAuth authentication for the API

## Constraints
- Must use PKCE flow
- Support refresh tokens

## Done
- [x] Set up OAuth endpoints
- [x] Implement PKCE challenge

## Now
Testing token refresh logic

## Next
- [ ] Add error handling
- [ ] Write integration tests

## Key Decisions
- **SQLite for token storage**: Portable and zero-config

## Working Files
- src/auth/oauth.ts
- src/auth/tokens.ts

*Last updated: 2025-12-31T12:00:00Z*
```

### Ledger API

```typescript
const ledger = new LedgerManager('/path/to/ledger.md');

// Load ledger
const state = await ledger.load();

// Update ledger
await ledger.update({
  now: 'Testing OAuth flow',
  done: [...state.done, 'Implemented PKCE'],
});

// Get current focus (for status line)
const focus = state.now; // "Testing OAuth flow"
```

### Handoffs (Episodic Memory)

Handoffs capture session summaries for future context retrieval:

```typescript
const handoffManager = new HandoffManager({ dbPath: '.tron/handoffs.db' });
await handoffManager.initialize();

// Create handoff
const id = await handoffManager.create({
  sessionId: 'sess_abc123',
  timestamp: new Date(),
  summary: 'Implemented OAuth with PKCE flow',
  codeChanges: [
    { file: 'src/auth/oauth.ts', description: 'Added PKCE challenge/verifier' },
    { file: 'src/auth/tokens.ts', description: 'Token storage and refresh' },
  ],
  currentState: 'OAuth working, need to add error handling',
  nextSteps: ['Add retry logic', 'Write tests'],
  blockers: [],
  patterns: ['Use 5-minute buffer for token expiry'],
});

// Search handoffs
const results = await handoffManager.search('OAuth', 10);

// Get recent handoffs
const recent = await handoffManager.getRecent(5);

// Get by session
const sessionHandoffs = await handoffManager.getBySession('sess_abc123');
```

---

## Model Switching

### Supported Providers

| Provider | Models | Auth Method |
|----------|--------|-------------|
| Anthropic | claude-opus-4-20250514, claude-sonnet-4-20250514 | OAuth (Claude Max) or API key |
| OpenAI | gpt-4o, gpt-4-turbo | API key |
| Google | gemini-pro, gemini-1.5-pro | API key |

### Runtime Model Switching

Switch models mid-session without losing context:

```bash
# In session, use slash command
/model gpt-4o

# Or via RPC
{"type": "switch_model", "modelId": "gpt-4o", "providerId": "openai"}
```

### Model Configuration

```json
// .tron/models.json
{
  "default": "claude-sonnet-4-20250514",
  "models": {
    "claude-sonnet-4-20250514": {
      "provider": "anthropic",
      "maxTokens": 8192,
      "contextWindow": 200000
    },
    "gpt-4o": {
      "provider": "openai",
      "maxTokens": 4096,
      "contextWindow": 128000
    }
  }
}
```

---

## Tool System

### Core Tools

| Tool | Description | Parameters |
|------|-------------|------------|
| `read` | Read file contents | `path`, `offset?`, `limit?` |
| `write` | Write/create file | `path`, `content` |
| `edit` | Edit file (exact match) | `path`, `oldText`, `newText` |
| `bash` | Execute shell command | `command`, `timeout?` |

### Read Tool

```typescript
// Read entire file
{ tool: 'read', path: 'src/index.ts' }

// Read lines 10-20
{ tool: 'read', path: 'src/index.ts', offset: 10, limit: 10 }

// Read image (returns base64)
{ tool: 'read', path: 'screenshot.png' }
```

### Write Tool

```typescript
// Write file (creates parent directories)
{ tool: 'write', path: 'src/new/file.ts', content: 'export const x = 1;' }
```

### Edit Tool

```typescript
// Edit file (exact text match required)
{
  tool: 'edit',
  path: 'src/index.ts',
  oldText: 'const x = 1;',
  newText: 'const x = 2;'
}
```

### Bash Tool

```typescript
// Run command
{ tool: 'bash', command: 'npm test' }

// With timeout (ms)
{ tool: 'bash', command: 'npm run build', timeout: 60000 }
```

### Tool Execution Flow

1. Agent requests tool use
2. `PreToolUse` hook runs (can block/modify)
3. Tool executes
4. `PostToolUse` hook runs (can log/index)
5. Result returned to agent

---

## Hook System

### Hook Lifecycle Events

| Event | Timing | Purpose |
|-------|--------|---------|
| `session_start` | Session begins | Load ledger, inject context |
| `session_end` | Session ends | Extract learnings, cleanup |
| `pre_tool_use` | Before tool | Validate, permission check |
| `post_tool_use` | After tool | Index changes, log |
| `pre_compact` | Before context compact | Auto-generate handoff |
| `user_prompt` | User message received | Skill suggestions |
| `stop` | Agent completes | Finalize |
| `subagent_stop` | Sub-agent completes | Capture reports |

### Hook Registration

```typescript
const hookEngine = new HookEngine();

// Register hook
hookEngine.register({
  id: 'my-hook',
  event: 'pre_tool_use',
  priority: 10, // Lower = runs first
  handler: async (context) => {
    if (context.toolName === 'bash' && context.args.command.includes('rm -rf')) {
      return { action: 'block', message: 'Dangerous command blocked' };
    }
    return { action: 'continue' };
  },
});

// Trigger hooks
const results = await hookEngine.trigger('pre_tool_use', {
  sessionId: 'sess_123',
  toolName: 'bash',
  args: { command: 'rm -rf /' },
});

// Check for blocks
const blocked = results.find(r => r.action === 'block');
if (blocked) {
  console.log('Blocked:', blocked.message);
}
```

### Hook Actions

| Action | Effect |
|--------|--------|
| `continue` | Proceed normally |
| `block` | Stop execution, return error |
| `modify` | Change arguments (for pre_tool_use) |

### Built-in Hooks

- **session-start.ts**: Loads ledger, injects into context
- **session-end.ts**: Extracts learnings, saves handoff
- **pre-tool-use.ts**: Validates tool calls
- **post-tool-use.ts**: Indexes file changes

---

## Skill System

### Skill Format

Skills are defined in SKILL.md files with YAML frontmatter:

```markdown
---
name: commit
description: Create a git commit with conventional message
trigger: /commit
arguments:
  - name: message
    description: Commit message
    required: false
---

# Commit Skill

Create a git commit following conventional commit format.

## Steps

1. Run `git status` to see changes
2. Run `git diff --staged` to review staged changes
3. Generate commit message based on changes
4. Run `git commit -m "<message>"`

## Commit Format

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

Types: feat, fix, docs, style, refactor, test, chore
```

### Skill Discovery

Skills are discovered from:
1. Built-in skills: `packages/core/src/skills/builtin/`
2. User skills: `~/.tron/skills/`
3. Project skills: `.tron/skills/`

### Skill Execution

```typescript
const registry = new SkillRegistry();
await registry.discover(); // Find all skills

// List skills
const skills = registry.list();

// Get specific skill
const commitSkill = registry.get('commit');

// Execute skill
const executor = new SkillExecutor(registry);
const result = await executor.execute('commit', {
  message: 'feat: add OAuth support',
});
```

### Built-in Skills

| Skill | Trigger | Description |
|-------|---------|-------------|
| commit | `/commit` | Git commit with message |
| handoff | `/handoff` | Create session handoff |
| ledger | `/ledger` | View/update ledger |
| explain | `/explain` | Explain code |
| refactor | `/refactor` | Refactor code |

---

## Context Loading

### Hierarchical Context Files

Context is loaded from multiple sources in order:

1. **Global**: `~/.tron/AGENTS.md`
2. **Parent directories**: Walk up from project root
3. **Project**: `./AGENTS.md` or `./CLAUDE.md`

### Context Merging

```typescript
const loader = new ContextLoader();

// Load merged context
const context = await loader.loadContextForPath('/path/to/project/src/file.ts');

// Returns combined content from all levels
```

### Context File Format

```markdown
# Project Context

## Overview
This is a TypeScript project using...

## Conventions
- Use camelCase for variables
- Use PascalCase for classes

## Important Files
- src/index.ts: Main entry point
- src/config.ts: Configuration

## Do Not Modify
- package-lock.json
- dist/
```

---

## RPC Protocol

### Message Format

```typescript
// Request
{
  type: 'prompt',
  id: 'req_123',  // Correlation ID
  text: 'Hello, agent!'
}

// Response
{
  type: 'response',
  id: 'req_123',
  success: true,
  data: { ... }
}

// Event (streaming)
{
  type: 'event',
  event: 'text_delta',
  data: { delta: 'Hello' }
}
```

### Command Types

#### Session Commands

```typescript
// Create session
{ type: 'session.create', workingDirectory: '/path' }

// List sessions
{ type: 'session.list', limit: 10 }

// Get session
{ type: 'session.get', sessionId: 'sess_123' }

// Fork session
{ type: 'session.fork', sessionId: 'sess_123', fromIndex?: 5 }

// Rewind session
{ type: 'session.rewind', sessionId: 'sess_123', toIndex: 3 }

// End session
{ type: 'session.end', sessionId: 'sess_123' }
```

#### Agent Commands

```typescript
// Send prompt
{ type: 'prompt', sessionId: 'sess_123', text: 'Hello!' }

// Abort current operation
{ type: 'abort', sessionId: 'sess_123' }

// Get state
{ type: 'get_state', sessionId: 'sess_123' }
```

#### Model Commands

```typescript
// Switch model
{ type: 'switch_model', modelId: 'gpt-4o', providerId: 'openai' }

// List models
{ type: 'list_models' }
```

#### Memory Commands

```typescript
// Get ledger
{ type: 'ledger.get', sessionId: 'sess_123' }

// Update ledger
{ type: 'ledger.update', sessionId: 'sess_123', updates: { now: 'Testing' } }

// Create handoff
{ type: 'handoff.create', sessionId: 'sess_123', summary: '...' }

// List handoffs
{ type: 'handoff.list', limit: 10 }

// Search handoffs
{ type: 'handoff.search', query: 'OAuth' }
```

---

## Server & WebSocket

### Starting the Server

```bash
# Development
npm run dev --workspace=@tron/server

# Production
npm run build --workspace=@tron/server
npm run start --workspace=@tron/server
```

### Configuration

```typescript
const server = new TronServer({
  port: 3000,
  host: 'localhost',
  sessionsDir: '.tron/sessions',
  memoryDbPath: '.tron/memory.db',
  defaultModel: 'claude-sonnet-4-20250514',
  defaultProvider: 'anthropic',
});

await server.start();
```

### Health Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Basic health check |
| `GET /ready` | Readiness probe |
| `GET /metrics` | Prometheus metrics |

### WebSocket Protocol

```typescript
// Connect
const ws = new WebSocket('ws://localhost:3000');

// Send command
ws.send(JSON.stringify({
  type: 'prompt',
  sessionId: 'sess_123',
  text: 'Hello!',
}));

// Receive events
ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  if (msg.type === 'text_delta') {
    console.log(msg.data.delta);
  }
};
```

---

## Web Interface

### Starting the Web UI

```bash
# Development
npm run dev --workspace=@tron/chat-web

# Build
npm run build --workspace=@tron/chat-web
```

### Features

- Real-time streaming responses
- Message history with markdown rendering
- Code syntax highlighting
- Tool execution visualization
- Model switcher
- Session management (create, fork, list)
- Export transcript
- Mobile-responsive layout

### Components

| Component | Description |
|-----------|-------------|
| `App` | Main application shell |
| `ChatContainer` | Chat layout wrapper |
| `MessageList` | Message history display |
| `MessageItem` | Individual message rendering |
| `PromptInput` | User input with send button |
| `ModelSelector` | Model switching dropdown |
| `SessionPanel` | Session list and controls |
| `ToolExecution` | Tool call visualization |

---

## Productivity Features

### Transcript Export

```typescript
const exporter = new TranscriptExporter();

// Export as markdown
const md = await exporter.toMarkdown(session.messages, {
  includeToolCalls: true,
  includeThinking: false,
  includeMetadata: true,
});

// Export as HTML
const html = await exporter.toHTML(session.messages);

// Copy to clipboard (in TUI)
await exporter.toClipboard(session.messages);
```

### Task Tracking

```typescript
const taskManager = new TaskManager('.tron/tasks');

// Create task
const task = await taskManager.create({
  description: 'Implement OAuth',
  tags: ['#auth', '#security'],
  category: 'work',
});

// Complete task
await taskManager.complete(task.id);

// List tasks
const tasks = await taskManager.list({ category: 'work', completed: false });
```

### Notes Integration

```typescript
const notes = new NotesManager('.tron/notes');

// Search notes
const results = await notes.search('OAuth implementation');

// Read note (supports markdown, PDF)
const content = await notes.readNote('reference/oauth-spec.md');
```

### Inbox Monitoring

```typescript
// Gmail connector
const gmail = new GmailInboxConnector({ credentials });
const emails = await gmail.fetch();

// Folder watcher
const folder = new FolderWatcher({ path: '~/Downloads/inbox' });
folder.on('file', (file) => console.log('New file:', file));

// Aggregator
const aggregator = new InboxAggregator([gmail, folder]);
const items = await aggregator.fetchAll();
```

---

## Configuration

### Global Config

```bash
~/.tron/
├── AGENTS.md           # Global context
├── settings.json       # User preferences
├── auth.json           # OAuth credentials (encrypted)
├── models.json         # Model registry
├── skills/             # User skills
│   └── my-skill/
│       └── SKILL.md
└── hooks/              # User hooks
    └── pre-tool-use.ts
```

### Project Config

```bash
.tron/
├── AGENTS.md           # Project context
├── settings.json       # Project settings
├── sessions/           # Session files
│   └── sess_abc123.jsonl
├── memory/             # Memory databases
│   ├── ledger.md
│   └── handoffs.db
└── skills/             # Project skills
```

### Settings Schema

```json
{
  "model": {
    "default": "claude-sonnet-4-20250514",
    "provider": "anthropic"
  },
  "session": {
    "autoSave": true,
    "maxHistory": 100
  },
  "ui": {
    "theme": "dark",
    "showTokens": true,
    "showCost": false
  },
  "tools": {
    "bash": {
      "timeout": 120000,
      "allowedCommands": ["*"]
    }
  }
}
```

---

## Keyboard Shortcuts (TUI)

| Shortcut | Action |
|----------|--------|
| `Enter` | Send message |
| `Ctrl+C` | Abort / Exit |
| `Ctrl+L` | Clear screen |
| `Up/Down` | Navigate history |
| `Tab` | Autocomplete |
| `Esc` | Cancel input |

---

## Troubleshooting

### Authentication Issues

```bash
# Clear and re-authenticate
tron logout
tron login

# Check stored credentials
cat ~/.tron/auth.json
```

### Session Recovery

```bash
# List all sessions
ls -la .tron/sessions/

# Inspect session file
cat .tron/sessions/sess_abc123.jsonl | jq .

# Resume specific session
tron -r sess_abc123
```

### Debug Logging

```bash
# Enable verbose logging
DEBUG=tron:* tron

# Log to file
tron 2>&1 | tee session.log
```

---

## TUI Session Lifecycle

The TUI uses `TuiSession` as a unified orchestrator that wires together all session, memory, and context subsystems.

### Session Initialization

When you start a TUI session, the following happens:

```
1. TuiSession.initialize()
   │
   ├── Create directories (~/.tron/sessions, ~/.tron/memory)
   │
   ├── Initialize managers:
   │   ├── SessionManager (JSONL persistence)
   │   ├── HandoffManager (SQLite + FTS5)
   │   ├── LedgerManager (Markdown continuity)
   │   └── ContextLoader (AGENTS.md hierarchy)
   │
   ├── Load context from AGENTS.md files
   │
   ├── Load current ledger state
   │
   ├── Load recent handoffs for context injection
   │
   ├── Create session in SessionManager
   │
   └── Build system prompt with all context sources
```

### Data Flow During Session

```
User Types Message
      │
      ▼
┌─────────────────┐
│ TuiSession.     │──▶ Persist user message to JSONL
│ addMessage()    │──▶ Update token usage counters
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ TuiSession.     │──▶ Update ledger.now with current work
│ updateLedger()  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ TronAgent.run() │──▶ Stream response, execute tools
└────────┬────────┘
         │
    For each tool execution:
         │
         ▼
┌─────────────────┐
│ TuiSession.     │──▶ Track file in working files list
│ addWorkingFile()│
└────────┬────────┘
         │
         ▼
    Persist all messages
```

### Session End

When you press Ctrl+C or the session ends:

```
TuiSession.end()
      │
      ├── Check message count ≥ minMessagesForHandoff (default: 2)
      │
      ├── If enough messages, create handoff:
      │   ├── Generate summary from ledger state
      │   ├── Include next steps from ledger.next
      │   ├── Include decisions from ledger.decisions
      │   └── Store in SQLite with FTS5 indexing
      │
      ├── Write session_end entry to SessionManager
      │
      └── Return EndResult with handoff info
```

### TuiSession API

```typescript
import { TuiSession } from '@tron/tui';

// Create session
const session = new TuiSession({
  workingDirectory: '/path/to/project',
  tronDir: '~/.tron',           // Global Tron directory
  model: 'claude-sonnet-4-20250514',
  provider: 'anthropic',
  minMessagesForHandoff: 2,     // Optional, default: 2
});

// Initialize (must call first)
const initResult = await session.initialize();
// initResult.sessionId: unique ID
// initResult.context: loaded AGENTS.md content
// initResult.ledger: current ledger state
// initResult.handoffs: recent handoffs for context
// initResult.systemPrompt: combined prompt with all context

// Add messages
await session.addMessage({ role: 'user', content: 'Hello' });
await session.addMessage({ role: 'assistant', content: '...' }, tokenUsage);

// Update ledger
await session.updateLedger({ now: 'Implementing feature X' });
await session.addWorkingFile('src/feature.ts');
await session.addDecision('Use SQLite', 'Zero-config deployment');

// Search handoffs
const results = await session.searchHandoffs('OAuth implementation');

// Get handoff by ID
const handoff = await session.getHandoff('handoff_123');

// End session (creates handoff if enough messages)
const endResult = await session.end();
// endResult.handoffCreated: boolean
// endResult.handoffId: string if created
// endResult.messageCount: total messages
// endResult.tokenUsage: total token usage
```

### Global Data Storage

All Tron data is stored in `~/.tron/`:

```
~/.tron/
├── sessions/              # Session JSONL files
│   ├── sess_abc123.jsonl
│   └── sess_def456.jsonl
├── memory/                # Continuity memory
│   └── CONTINUITY.md      # Current ledger state
├── memory-handoffs.db     # SQLite with FTS5 for handoff search
└── AGENTS.md              # Global context (optional)
```

This global storage enables:
- **Cross-project learning**: Handoffs from all projects are searchable
- **Continuity across sessions**: Ledger persists goal/now/next state
- **Context injection**: Recent handoffs inform new sessions

---

## API Reference

For detailed API documentation, see:
- [Core API](./api/core.md)
- [Server API](./api/server.md)
- [RPC Protocol](./api/rpc.md)
- [Hook API](./api/hooks.md)
- [Skill API](./api/skills.md)
