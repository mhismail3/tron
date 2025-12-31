# Complete Implementation Plan: Persistent Dual-Interface Coding Agent

## Executive Summary

This document provides a **complete, test-driven implementation plan** for building a persistent, dual-interface coding agent that combines the best of pi-mono's architecture with advanced memory management and productivity features.

**Decision: Hybrid Approach** - Build fresh architecture while selectively reusing battle-tested components from pi as npm dependencies. This gives us full control over the memory system and dual-interface design while leveraging proven code for LLM abstraction and UI components.

**Timeline Estimate**: 12-16 weeks to MVP (minimum viable product), 20-24 weeks to feature-complete.

**Methodology**: Strict test-driven development (TDD) - every feature starts with a failing test.

---

## Table of Contents

1. [Architecture Decision: Fork vs. Build](#1-architecture-decision-fork-vs-build)
2. [Complete Feature Inventory](#2-complete-feature-inventory)
3. [Project Structure](#3-project-structure)
4. [Testing Strategy](#4-testing-strategy)
5. [Phase 1: Foundation (Weeks 1-3)](#phase-1-foundation-weeks-1-3)
6. [Phase 2: Memory Layer (Weeks 4-5)](#phase-2-memory-layer-weeks-4-5)
7. [Phase 3: Hook System (Week 6)](#phase-3-hook-system-week-6)
8. [Phase 4: Agent Loop (Weeks 7-8)](#phase-4-agent-loop-weeks-7-8)
9. [Phase 5: Dual Interface (Weeks 9-11)](#phase-5-dual-interface-weeks-9-11)
10. [Phase 6: Productivity Features (Weeks 12-14)](#phase-6-productivity-features-weeks-12-14)
11. [Phase 7: Advanced Features (Weeks 15-16)](#phase-7-advanced-features-weeks-15-16)
12. [Phase 8: Multi-Model Support (Weeks 17-18)](#phase-8-multi-model-support-weeks-17-18)
13. [Phase 9: Polish & Production (Weeks 19-20)](#phase-9-polish--production-weeks-19-20)
14. [Deployment Architecture](#deployment-architecture)
15. [Code Samples: Critical Paths](#code-samples-critical-paths)
16. [Migration from Existing Systems](#migration-from-existing-systems)

---

## 1. Architecture Decision: Fork vs. Build

### The Question

Should we:
1. **Fork pi-mono**, strip it down, and add our features on top?
2. **Build from scratch**, selectively reusing pi components?

### Analysis

| Aspect | Fork pi-mono | Build Fresh + Selective Reuse |
|--------|--------------|-------------------------------|
| **Time to first working version** | Faster (1-2 weeks) | Slower (3-4 weeks) |
| **Control over architecture** | Limited | Complete |
| **Memory integration** | Retrofit (harder) | Native (easier) |
| **Dual-interface support** | Bolt-on | First-class |
| **Custom features** | Fight existing design | Natural fit |
| **Code understanding** | Must learn pi internals | Know everything we write |
| **Maintenance burden** | Merge upstream changes | Only what we build |
| **Customization** | Constrained by pi patterns | Unlimited |

### Decision: **Hybrid Approach**

**Build new architecture, reuse specific packages:**

```
Our Project
├── Core (build fresh)
│   ├── Agent loop with memory integration
│   ├── Session manager
│   ├── Hook system (comprehensive)
│   ├── Memory layer (4-level hierarchy)
│   └── Always-on server
├── Reuse as npm dependencies
│   ├── @mariozechner/pi-ai (LLM abstraction - it's perfect)
│   └── @mariozechner/pi-tui components (terminal rendering)
└── Reference implementations (study & copy patterns)
    ├── Tools (read/write/edit/bash)
    ├── Skills system
    └── Context file loading
```

### Rationale

1. **pi-ai is battle-tested** for multi-provider LLM handling - no need to reinvent
2. **Memory architecture is fundamentally different** from pi's compaction approach - easier to build right from start
3. **Dual-interface is core requirement** - needs to be designed in, not retrofitted
4. **User wants features pi explicitly avoids** (inbox monitoring, notes integration) - cleaner with fresh architecture
5. **Full control over customization** while still leveraging proven code where it makes sense

---

## 2. Complete Feature Inventory

### 2.1 Core Agent Features

#### LLM & Model Management
- [ ] Multi-provider support (Claude first, expand to OpenAI/Google/Mistral)
- [ ] Claude Max OAuth authentication with PKCE
- [ ] API key authentication fallback
- [ ] Token refresh automation
- [ ] Mid-session model switching with context preservation
- [ ] Model evaluation framework
- [ ] Cost & token tracking per message
- [ ] Rate limit handling

#### Tools (4 Core + 3 Optional)
- [ ] **read**: Text files + images with offset/limit support
- [ ] **write**: Create/overwrite with automatic parent directory creation
- [ ] **edit**: Exact text matching with unified diff output
- [ ] **bash**: Shell execution with timeout, abort, large output handling
- [ ] **grep**: Pattern search (optional, read-only)
- [ ] **find**: File search (optional, read-only)
- [ ] **ls**: Directory listing (optional, read-only)

#### Agent Loop
- [ ] Event-driven streaming architecture
- [ ] Tool execution with validation
- [ ] Error handling and retry logic
- [ ] Abort signal support
- [ ] Tool call batching
- [ ] User interruption handling (queue message)

### 2.2 Memory & Context Management

#### Four-Level Memory Hierarchy
- [ ] **Level 1: Immediate** (in-context) - current task, recent messages
- [ ] **Level 2: Session** (ledger) - goal, focus, decisions, working files
- [ ] **Level 3: Project** (handoffs) - past sessions with FTS5 search
- [ ] **Level 4: Global** (learnings) - cross-project patterns

#### Ledger System
- [ ] Markdown-based session state
- [ ] Goal tracking
- [ ] Current focus (drives status line)
- [ ] Next steps list
- [ ] Key decisions log
- [ ] Working files tracking
- [ ] Auto-load on SessionStart
- [ ] Auto-save on updates

#### Handoff Documents
- [ ] Session summary generation
- [ ] Code changes tracking with file:line references
- [ ] Current state capture
- [ ] Blockers identification
- [ ] Next steps enumeration
- [ ] Patterns discovered
- [ ] FTS5 indexing for search
- [ ] Auto-generation on PreCompact

#### Episodic Memory
- [ ] Session log archival
- [ ] Vector embeddings for semantic search
- [ ] Full-text search (FTS5)
- [ ] Configurable retention period
- [ ] MCP tool integration for agent access

#### Learnings Extraction
- [ ] Session outcome tracking
- [ ] Pattern identification
- [ ] "What worked" / "What failed" extraction
- [ ] Cross-session aggregation
- [ ] Global rules generation

### 2.3 Hook System

#### Standard Lifecycle Hooks
- [ ] **SessionStart** - Load ledger, handoffs, inject context
- [ ] **SessionEnd** - Extract learnings, cleanup, outcome logging
- [ ] **PreToolUse** - Validation, type-checking, permission checks
- [ ] **PostToolUse** - Index changes, track patterns, update state
- [ ] **PreCompact** - Auto-handoff generation, block manual compact
- [ ] **UserPromptSubmit** - Skill suggestions, context warnings
- [ ] **Stop** - Agent completion finalization
- [ ] **SubagentStop** - Capture sub-agent reports
- [ ] **Notification** - External event triggers

#### Comprehensive Placeholder Hooks
- [ ] **PreRead** - Before file read operations
- [ ] **PostRead** - After file read completion
- [ ] **PreWrite** - Before file write operations
- [ ] **PostWrite** - After file write completion
- [ ] **PreEdit** - Before file edit operations
- [ ] **PostEdit** - After file edit completion
- [ ] **PreBash** - Before bash execution
- [ ] **PostBash** - After bash completion
- [ ] **MessageReceived** - On any message from user
- [ ] **MessageSent** - On any message from agent
- [ ] **ToolStart** - On any tool invocation start
- [ ] **ToolEnd** - On any tool invocation end
- [ ] **ThinkingStart** - When extended thinking begins
- [ ] **ThinkingEnd** - When extended thinking completes
- [ ] **ErrorOccurred** - On any error
- [ ] **ModelSwitched** - On model change
- [ ] **SessionSaved** - On session persistence
- [ ] **SessionLoaded** - On session restoration

#### Hook Implementation
- [ ] TypeScript/JavaScript handlers
- [ ] Pre-bundled with zero runtime dependencies
- [ ] Shell script wrappers
- [ ] JSON input/output protocol
- [ ] Action control (continue/block/modify)
- [ ] Configurable timeouts
- [ ] Matcher patterns for selective execution
- [ ] Hot reload support

### 2.4 Session Management

#### Core Session Operations
- [ ] JSONL persistence (append-only)
- [ ] Session creation with unique IDs
- [ ] Session listing and selection
- [ ] Continue most recent session
- [ ] Resume specific session by ID or path
- [ ] **NEW**: Rewind to earlier message
- [ ] **NEW**: Fork session (create branch)
- [ ] Session deletion with confirmation
- [ ] Ephemeral sessions (--no-session mode)

#### Cross-Device Sync
- [ ] **NEW**: Session state synchronization
- [ ] **NEW**: Conflict resolution strategies
- [ ] **NEW**: Last-write-wins or merge
- [ ] **NEW**: Device-specific session metadata

#### Git Worktree Integration
- [ ] **NEW**: Auto-create worktree for new session in same project
- [ ] **NEW**: Worktree cleanup on session end
- [ ] **NEW**: Branch naming conventions (session/<id>)
- [ ] **NEW**: Automatic commit on session fork

#### Multi-Session Support
- [ ] Concurrent session handling
- [ ] Session isolation (separate state)
- [ ] Session switching without restart
- [ ] Resource limits per session

### 2.5 Dual Interface

#### Terminal UI
- [ ] Differential rendering (pi-tui pattern)
- [ ] Synchronized output (CSI 2026)
- [ ] Components: Text, Editor, Markdown, Loader, Image
- [ ] Keyboard shortcuts
- [ ] Context percentage indicator
- [ ] Status line with ledger integration
- [ ] Inline images (Kitty/iTerm2)
- [ ] Bracketed paste mode

#### Chat Interface (Web)
- [ ] WebSocket connection to server
- [ ] Real-time event streaming
- [ ] Message rendering (markdown + code highlighting)
- [ ] Tool execution visualization
- [ ] File diff display (collapsible)
- [ ] Model switcher UI
- [ ] Cost/token display (optional)
- [ ] **NEW**: Voice input support
- [ ] **NEW**: Mobile-optimized layout

#### Chat Interface (Mobile PWA)
- [ ] iOS/Android installable
- [ ] Touch-optimized controls
- [ ] Swipe gestures (branch, delete message)
- [ ] Simplified UX for non-technical users
- [ ] Progressive disclosure (basic → advanced)
- [ ] Offline message queueing

#### RPC Protocol
- [ ] JSON commands over stdin/stdout (terminal mode)
- [ ] JSON messages over WebSocket (chat mode)
- [ ] Command correlation IDs
- [ ] Event streaming
- [ ] State query commands
- [ ] Operation commands (prompt, abort, switch model, etc.)

### 2.6 Always-On Service

#### Process Management
- [ ] launchd configuration (macOS)
- [ ] systemd configuration (Linux)
- [ ] Auto-restart on crash
- [ ] Graceful shutdown handling
- [ ] Log rotation

#### Session Orchestration
- [ ] Spawn isolated agent processes
- [ ] Route WebSocket connections to sessions
- [ ] Health checks
- [ ] Resource monitoring
- [ ] Session cleanup (idle timeout)

#### Monitoring
- [ ] Health endpoint (HTTP)
- [ ] Metrics collection (optional)
- [ ] Error logging
- [ ] Performance tracking

### 2.7 NEW: Productivity Features

#### Transcript Export
- [ ] **Copy to clipboard** (all interfaces)
- [ ] **Export as Markdown** with syntax highlighting
- [ ] **Export as HTML** with embedded styles
- [ ] **Export to browser** (live preview)
- [ ] Include/exclude tool calls (configurable)
- [ ] Include/exclude thinking (configurable)
- [ ] Session metadata in export (cost, tokens, duration)

#### Task Tracking
- [ ] **Persistent markdown to-do lists**
- [ ] Auto-create from user requests
- [ ] Tag support (#project, #bug, #feature)
- [ ] Category support (work, personal, learning)
- [ ] Cross-session task continuity
- [ ] Task completion tracking
- [ ] Due date support (optional)
- [ ] Integration with ledger "Next" section

#### Inbox Monitoring (PersonalOS-style)
- [ ] **Gmail inbox connector** (OAuth + IMAP)
- [ ] **Folder watcher** (local filesystem)
- [ ] **Notion page connector** (Notion API)
- [ ] **Obsidian inbox** (markdown files in designated folder)
- [ ] Configurable polling intervals
- [ ] "Stuff to process" aggregation
- [ ] Mark as processed/archive workflow
- [ ] Custom inbox types (plugin system)

#### Notes Integration
- [ ] **Designated notes folder**
- [ ] Obsidian-compatible markdown
- [ ] PDF support (text extraction)
- [ ] Image support
- [ ] Full-text search across notes
- [ ] Link to notes from agent conversations
- [ ] Auto-tag notes referenced in sessions

#### Skills System
- [ ] **Primary invocation method** for agents/tools/prompts
- [ ] SKILL.md format (YAML frontmatter + markdown)
- [ ] Skill discovery from .agent/skills/
- [ ] Slash command mapping (/skill-name)
- [ ] Argument support in skill definitions
- [ ] Skill chaining (composite skills)
- [ ] Built-in skills (commit, handoff, ledger, etc.)
- [ ] Custom user skills

#### Hierarchical Context Files
- [ ] **Global context**: ~/.agent/AGENTS.md
- [ ] **Project context**: ./AGENTS.md or ./CLAUDE.md
- [ ] **Load order**: global → parent dirs → project
- [ ] **Merge strategy**: append or override sections
- [ ] **Token budget allocation**

#### Slash Commands
- [ ] **Built-in commands**:
  - /clear - Clear context, preserve ledger
  - /compact - Auto-handoff + compact (discouraged)
  - /context - Show token usage breakdown
  - /model - Switch model
  - /export - Export transcript
  - /handoff - Create handoff
  - /ledger - Update ledger
  - /resume - Resume from handoff
  - /fork - Fork current session
  - /rewind - Rewind to earlier state
- [ ] **Custom commands** as markdown templates
- [ ] Argument support with placeholders
- [ ] Auto-complete in editor

#### tmux Support
- [ ] **Spawn self-agents** in tmux sessions
- [ ] Session naming (agent-<skill>-<id>)
- [ ] Window/pane management
- [ ] Attach/detach workflow
- [ ] Session persistence across reconnects

### 2.8 Multi-Model Testing

#### Model Registry
- [ ] Model configuration (context, cost, capabilities)
- [ ] Provider endpoints
- [ ] Auth requirements per provider
- [ ] Custom model definitions

#### Evaluation Framework
- [ ] Standard task suite
- [ ] Metrics collection (latency, tokens, cost, quality)
- [ ] Comparison reports
- [ ] Historical tracking

---

## 3. Project Structure

```
agent/
├── packages/
│   ├── core/
│   │   ├── src/
│   │   │   ├── agent/
│   │   │   │   ├── loop.ts              # Agent execution loop
│   │   │   │   ├── state.ts             # Agent state management
│   │   │   │   └── events.ts            # Event emitter
│   │   │   ├── memory/
│   │   │   │   ├── ledger.ts            # Session ledger management
│   │   │   │   ├── handoff.ts           # Handoff generation/loading
│   │   │   │   ├── episodic.ts          # Episodic memory with vector search
│   │   │   │   ├── learnings.ts         # Learning extraction
│   │   │   │   └── fts.ts               # FTS5 search utilities
│   │   │   ├── hooks/
│   │   │   │   ├── manager.ts           # Hook registration/execution
│   │   │   │   ├── types.ts             # Hook interfaces
│   │   │   │   └── builtin/             # Built-in hooks
│   │   │   │       ├── session-start.ts
│   │   │   │       ├── session-end.ts
│   │   │   │       ├── pre-compact.ts
│   │   │   │       └── ...
│   │   │   ├── tools/
│   │   │   │   ├── read.ts              # File read tool
│   │   │   │   ├── write.ts             # File write tool
│   │   │   │   ├── edit.ts              # File edit tool
│   │   │   │   ├── bash.ts              # Bash execution tool
│   │   │   │   └── types.ts             # Tool interfaces
│   │   │   ├── providers/
│   │   │   │   ├── anthropic.ts         # Anthropic provider
│   │   │   │   ├── openai.ts            # OpenAI provider
│   │   │   │   ├── factory.ts           # Provider factory
│   │   │   │   └── types.ts             # Provider interfaces
│   │   │   ├── auth/
│   │   │   │   ├── oauth.ts             # OAuth flows (PKCE)
│   │   │   │   ├── storage.ts           # Encrypted credential storage
│   │   │   │   └── refresh.ts           # Token refresh
│   │   │   ├── session/
│   │   │   │   ├── manager.ts           # Session lifecycle
│   │   │   │   ├── persistence.ts       # JSONL read/write
│   │   │   │   ├── sync.ts              # Cross-device sync
│   │   │   │   └── worktree.ts          # Git worktree integration
│   │   │   ├── productivity/
│   │   │   │   ├── tasks.ts             # Task tracking
│   │   │   │   ├── inbox.ts             # Inbox monitoring
│   │   │   │   ├── notes.ts             # Notes integration
│   │   │   │   └── export.ts            # Transcript export
│   │   │   ├── skills/
│   │   │   │   ├── loader.ts            # Skill discovery
│   │   │   │   ├── executor.ts          # Skill execution
│   │   │   │   └── types.ts             # Skill interfaces
│   │   │   ├── context/
│   │   │   │   ├── loader.ts            # AGENTS.md loading
│   │   │   │   └── hierarchy.ts         # Hierarchical merging
│   │   │   ├── rpc/
│   │   │   │   ├── protocol.ts          # RPC message types
│   │   │   │   ├── handler.ts           # Command handling
│   │   │   │   └── client.ts            # Client implementation
│   │   │   ├── types.ts                 # Shared types
│   │   │   └── index.ts                 # Public API
│   │   ├── test/
│   │   │   ├── agent/
│   │   │   ├── memory/
│   │   │   ├── hooks/
│   │   │   ├── tools/
│   │   │   └── ...
│   │   ├── package.json
│   │   └── tsconfig.json
│   ├── server/
│   │   ├── src/
│   │   │   ├── index.ts                 # Server entry point
│   │   │   ├── websocket.ts             # WebSocket handler
│   │   │   ├── session-manager.ts       # Multi-session orchestration
│   │   │   ├── health.ts                # Health checks
│   │   │   └── supervisor.ts            # Process supervision
│   │   ├── test/
│   │   ├── package.json
│   │   └── tsconfig.json
│   ├── tui/
│   │   ├── src/
│   │   │   ├── index.ts                 # TUI entry point
│   │   │   ├── components/              # Reuse pi-tui or build custom
│   │   │   ├── renderer.ts              # Differential rendering
│   │   │   ├── input.ts                 # Keyboard handling
│   │   │   └── status.ts                # Status line
│   │   ├── test/
│   │   ├── package.json
│   │   └── tsconfig.json
│   ├── chat-web/
│   │   ├── src/
│   │   │   ├── components/
│   │   │   │   ├── MessageList.tsx
│   │   │   │   ├── PromptInput.tsx
│   │   │   │   ├── ToolExecution.tsx
│   │   │   │   ├── ModelSwitcher.tsx
│   │   │   │   └── ...
│   │   │   ├── hooks/
│   │   │   │   ├── useWebSocket.ts
│   │   │   │   ├── useSession.ts
│   │   │   │   └── useAgent.ts
│   │   │   ├── App.tsx
│   │   │   └── index.tsx
│   │   ├── public/
│   │   ├── package.json
│   │   └── vite.config.ts
│   └── chat-mobile/
│       ├── src/                          # React Native or PWA build
│       ├── package.json
│       └── ...
├── .agent/
│   ├── AGENTS.md                         # Global context
│   ├── settings.json                     # User preferences
│   ├── auth.json                         # Encrypted credentials
│   ├── models.json                       # Model registry
│   ├── skills/                           # Built-in + custom skills
│   │   ├── commit/
│   │   │   └── SKILL.md
│   │   ├── handoff/
│   │   │   └── SKILL.md
│   │   ├── ledger/
│   │   │   └── SKILL.md
│   │   └── ...
│   ├── hooks/                            # User hooks
│   │   ├── pre-tool-use.sh
│   │   ├── post-tool-use.sh
│   │   └── ...
│   ├── sessions/
│   │   ├── session-abc123.jsonl
│   │   ├── session-def456.jsonl
│   │   └── ...
│   ├── memory/
│   │   ├── episodic.db                   # Vector search
│   │   ├── handoffs.db                   # FTS5 index
│   │   └── learnings/
│   │       └── 2025-12-31_session-abc.md
│   ├── tasks/
│   │   ├── work.md
│   │   ├── personal.md
│   │   └── learning.md
│   ├── inbox/
│   │   ├── connectors.json               # Inbox configurations
│   │   └── processed/
│   └── notes/                            # Obsidian-compatible
│       ├── daily/
│       ├── projects/
│       └── reference/
├── thoughts/                              # Session-scoped (gitignored)
│   ├── ledgers/
│   │   └── CONTINUITY_*.md
│   └── shared/
│       ├── handoffs/
│       └── plans/
├── scripts/
│   ├── setup.sh                          # Initial setup
│   ├── install-service.sh                # launchd/systemd install
│   └── migrate-from-pi.sh                # Migration helper
├── package.json                           # Workspace root
├── tsconfig.json                          # Shared TS config
└── README.md
```

---

## 4. Testing Strategy

### 4.1 Test-Driven Development Workflow

**Every feature follows this pattern:**

```
1. Write failing test(s)
2. Run test suite (verify failure)
3. Write minimal code to pass
4. Run test suite (verify pass)
5. Refactor if needed
6. Run test suite (verify still passing)
7. Commit
```

### 4.2 Test Levels

#### Unit Tests
- Individual functions and classes
- Mock external dependencies
- Fast execution (< 1ms per test)
- Coverage target: >80%

#### Integration Tests
- Multiple components working together
- Real dependencies where practical
- Database, filesystem, network mocked where slow
- Coverage target: >60%

#### End-to-End Tests
- Full user workflows
- Real agent loop with mocked LLM
- Session persistence, tool execution, memory operations
- Coverage target: Critical paths

#### Contract Tests
- RPC protocol compliance
- WebSocket message formats
- Hook input/output schemas
- Provider API contracts

### 4.3 Test Infrastructure

```typescript
// packages/core/test/setup.ts
import { jest } from '@jest/globals';

// Mock filesystem
export const mockFs = {
  readFile: jest.fn(),
  writeFile: jest.fn(),
  mkdir: jest.fn(),
  // ...
};

// Mock LLM provider
export class MockProvider {
  async *stream(context: Context): AsyncGenerator<StreamEvent> {
    yield { type: 'start' };
    yield { type: 'text_delta', delta: 'Hello' };
    yield { type: 'done', message: { role: 'assistant', content: [...] } };
  }
}

// Test database
export function createTestDb(): Database {
  return new Database(':memory:');  // SQLite in-memory
}

// Test session
export function createTestSession(overrides?: Partial<SessionOptions>): Session {
  return new Session({
    id: 'test-session',
    model: mockModel,
    tools: [readTool, writeTool],
    ...overrides
  });
}
```

### 4.4 Testing Tools

- **Test Runner**: Vitest (fast, TypeScript-native)
- **Mocking**: Built-in Vitest mocks
- **Assertions**: Expect API (Vitest)
- **Coverage**: c8
- **E2E**: Playwright (for web interface)
- **Database**: SQLite :memory: mode

---

## Phase 1: Foundation (Weeks 1-3)

### Goals
- Project setup
- Dependency integration
- Core types and interfaces
- Basic test infrastructure

### Week 1: Project Scaffolding

#### Day 1: Repository Setup

**Test**: Repository structure exists
```typescript
// packages/core/test/setup.test.ts
describe('Project structure', () => {
  it('should have core package', () => {
    expect(fs.existsSync('packages/core')).toBe(true);
  });

  it('should have valid package.json', () => {
    const pkg = JSON.parse(fs.readFileSync('packages/core/package.json', 'utf-8'));
    expect(pkg.name).toBe('@agent/core');
  });
});
```

**Implementation**:
```bash
# Create monorepo
mkdir agent && cd agent
npm init -y
npm install -D typescript vitest @vitest/coverage-c8

# Create packages
mkdir -p packages/{core,server,tui,chat-web}

# Initialize each package
for pkg in packages/*; do
  cd $pkg
  npm init -y
  cd ../..
done

# Setup workspaces
# Edit root package.json to add workspaces
```

#### Day 2-3: Type System & Interfaces

**Test**: Core types are well-defined
```typescript
// packages/core/test/types.test.ts
import { Message, Context, Tool, StreamEvent } from '../src/types';

describe('Core types', () => {
  it('should define Message type correctly', () => {
    const userMsg: Message = {
      role: 'user',
      content: 'Hello',
      timestamp: Date.now()
    };
    expect(userMsg.role).toBe('user');
  });

  it('should define Tool interface', () => {
    const tool: Tool = {
      name: 'test',
      description: 'Test tool',
      parameters: {}
    };
    expect(tool.name).toBe('test');
  });
});
```

**Implementation**:
```typescript
// packages/core/src/types.ts

// Messages
export type MessageRole = 'user' | 'assistant' | 'toolResult';

export interface UserMessage {
  role: 'user';
  content: string | Content[];
  timestamp?: number;
}

export interface AssistantMessage {
  role: 'assistant';
  content: AssistantContent[];
  usage?: TokenUsage;
  cost?: Cost;
  stopReason?: StopReason;
  thinking?: string;
}

export interface ToolResultMessage {
  role: 'toolResult';
  toolCallId: string;
  content: string | Content[];
  isError?: boolean;
}

export type Message = UserMessage | AssistantMessage | ToolResultMessage;

// Content types
export interface TextContent {
  type: 'text';
  text: string;
}

export interface ImageContent {
  type: 'image';
  data: string;  // base64
  mimeType: string;
}

export interface ThinkingContent {
  type: 'thinking';
  thinking: string;
}

export interface ToolCall {
  type: 'tool_use';
  id: string;
  name: string;
  arguments: Record<string, unknown>;
}

export type Content = TextContent | ImageContent;
export type AssistantContent = TextContent | ThinkingContent | ToolCall;

// Context
export interface Context {
  systemPrompt?: string;
  messages: Message[];
  tools?: Tool[];
}

// Tools
export interface Tool<TParams = unknown> {
  name: string;
  description: string;
  parameters: TSchema;  // TypeBox schema
}

export interface AgentTool<TParams = unknown, TDetails = unknown> extends Tool<TParams> {
  label: string;
  execute: (
    toolCallId: string,
    params: TParams,
    signal: AbortSignal,
    onUpdate?: (update: string) => void
  ) => Promise<AgentToolResult<TDetails>>;
}

export interface AgentToolResult<TDetails = unknown> {
  content: Content[];
  details?: TDetails;
  isError?: boolean;
}

// Streaming
export type StreamEvent =
  | { type: 'start' }
  | { type: 'text_start' }
  | { type: 'text_delta'; delta: string }
  | { type: 'text_end'; text: string }
  | { type: 'thinking_start' }
  | { type: 'thinking_delta'; delta: string }
  | { type: 'thinking_end'; thinking: string }
  | { type: 'toolcall_start'; toolCallId: string; name: string }
  | { type: 'toolcall_delta'; toolCallId: string; argumentsDelta: string }
  | { type: 'toolcall_end'; toolCall: ToolCall }
  | { type: 'done'; message: AssistantMessage; stopReason: string }
  | { type: 'error'; error: Error };

// Provider
export interface LLMProvider {
  id: string;
  stream(context: Context, options?: StreamOptions): AsyncIterable<StreamEvent>;
  complete(context: Context, options?: StreamOptions): Promise<AssistantMessage>;
}

// More types...
```

#### Day 4-5: Install Dependencies

**Test**: Dependencies are installed
```typescript
// packages/core/test/dependencies.test.ts
describe('Dependencies', () => {
  it('should have @mariozechner/pi-ai installed', async () => {
    const { getModel } = await import('@mariozechner/pi-ai');
    expect(getModel).toBeDefined();
  });

  it('should have TypeBox installed', async () => {
    const { Type } = await import('@sinclair/typebox');
    expect(Type).toBeDefined();
  });
});
```

**Implementation**:
```bash
cd packages/core

# Install pi-ai for LLM abstraction
npm install @mariozechner/pi-ai

# Install utilities
npm install @sinclair/typebox ajv
npm install better-sqlite3
npm install ws

# Install dev dependencies
npm install -D @types/node @types/better-sqlite3 @types/ws
npm install -D vitest @vitest/coverage-c8
```

### Week 2: Provider Layer

#### Day 1-2: Anthropic Provider with OAuth

**Test**: OAuth flow works
```typescript
// packages/core/test/auth/oauth.test.ts
import { loginAnthropic, refreshToken } from '../../src/auth/oauth';

describe('Anthropic OAuth', () => {
  it('should generate PKCE challenge', () => {
    const { verifier, challenge } = generatePKCE();
    expect(verifier).toHaveLength(64);
    expect(challenge).toBeTruthy();
  });

  it('should construct authorization URL', () => {
    const url = getAuthorizationUrl();
    expect(url).toContain('claude.ai/oauth/authorize');
    expect(url).toContain('code_challenge=');
  });

  it('should exchange code for tokens', async () => {
    // Mock fetch
    global.fetch = vi.fn().mockResolvedValue({
      json: () => Promise.resolve({
        access_token: 'sk-ant-oat-test',
        refresh_token: 'refresh-test',
        expires_in: 3600
      })
    });

    const tokens = await exchangeCodeForTokens('auth-code', 'verifier');
    expect(tokens.accessToken).toContain('sk-ant-oat');
  });
});
```

**Implementation**:
```typescript
// packages/core/src/auth/oauth.ts
import crypto from 'crypto';

export interface OAuthTokens {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
}

export function generatePKCE(): { verifier: string; challenge: string } {
  const verifier = crypto.randomBytes(32).toString('base64url');
  const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
  return { verifier, challenge };
}

export function getAuthorizationUrl(challenge: string): string {
  const params = new URLSearchParams({
    client_id: process.env.ANTHROPIC_CLIENT_ID!,
    redirect_uri: 'urn:ietf:wg:oauth:2.0:oob',
    response_type: 'code',
    scope: 'user:inference user:profile',
    code_challenge: challenge,
    code_challenge_method: 'S256',
  });
  return `https://claude.ai/oauth/authorize?${params}`;
}

export async function exchangeCodeForTokens(
  code: string,
  verifier: string
): Promise<OAuthTokens> {
  const response = await fetch('https://console.anthropic.com/v1/oauth/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      code_verifier: verifier,
      client_id: process.env.ANTHROPIC_CLIENT_ID!,
    }),
  });

  const { access_token, refresh_token, expires_in } = await response.json();
  return {
    accessToken: access_token,
    refreshToken: refresh_token,
    expiresAt: Date.now() + (expires_in - 300) * 1000,  // 5-min buffer
  };
}

export async function refreshOAuthToken(refreshToken: string): Promise<OAuthTokens> {
  const response = await fetch('https://console.anthropic.com/v1/oauth/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
      client_id: process.env.ANTHROPIC_CLIENT_ID!,
    }),
  });

  const { access_token, refresh_token, expires_in } = await response.json();
  return {
    accessToken: access_token,
    refreshToken: refresh_token,
    expiresAt: Date.now() + (expires_in - 300) * 1000,
  };
}

// Interactive login flow
export async function loginAnthropic(): Promise<OAuthTokens> {
  const { verifier, challenge } = generatePKCE();
  const authUrl = getAuthorizationUrl(challenge);

  console.log(`Open this URL in your browser:\n${authUrl}\n`);
  const code = await promptForCode();

  return exchangeCodeForTokens(code, verifier);
}
```

#### Day 3-4: Streaming with pi-ai

**Test**: Streaming works with Anthropic
```typescript
// packages/core/test/providers/anthropic.test.ts
import { stream } from '@mariozechner/pi-ai';
import { getModel } from '@mariozechner/pi-ai';

describe('Anthropic streaming', () => {
  it('should stream text deltas', async () => {
    const model = getModel('anthropic', 'claude-sonnet-4-20250514');
    const context = {
      messages: [{ role: 'user', content: 'Say hello' }]
    };

    const events = [];
    for await (const event of stream(model, context)) {
      events.push(event);
    }

    expect(events.some(e => e.type === 'text_delta')).toBe(true);
    expect(events.some(e => e.type === 'done')).toBe(true);
  });
});
```

**Implementation**: Use pi-ai directly (already implemented)

#### Day 5: Provider Factory

**Test**: Factory creates correct provider
```typescript
// packages/core/test/providers/factory.test.ts
import { ProviderFactory } from '../../src/providers/factory';

describe('ProviderFactory', () => {
  it('should create Anthropic provider with OAuth', () => {
    const provider = ProviderFactory.create({
      id: 'anthropic',
      auth: { type: 'oauth', accessToken: 'sk-ant-oat-test' }
    });
    expect(provider.id).toBe('anthropic');
  });
});
```

**Implementation**:
```typescript
// packages/core/src/providers/factory.ts
import { getModel } from '@mariozechner/pi-ai';

export interface ProviderConfig {
  id: string;
  modelId: string;
  auth: AuthCredentials;
}

export class ProviderFactory {
  static create(config: ProviderConfig): LLMProvider {
    // Wrap pi-ai's getModel with our interface
    const model = getModel(config.id, config.modelId);

    return {
      id: config.id,
      stream: (context, options) => stream(model, context, options),
      complete: (context, options) => complete(model, context, options)
    };
  }
}
```

### Week 3: Basic Tools

#### Day 1-2: Read Tool

**Test**: Read tool works
```typescript
// packages/core/test/tools/read.test.ts
import { createReadTool } from '../../src/tools/read';
import fs from 'fs/promises';

describe('Read tool', () => {
  const cwd = '/test/dir';
  const tool = createReadTool(cwd);

  beforeEach(() => {
    vi.spyOn(fs, 'readFile').mockResolvedValue('file content');
  });

  it('should read file content', async () => {
    const result = await tool.execute('call-1', { path: 'test.txt' }, new AbortSignal());

    expect(result.content).toEqual([{ type: 'text', text: 'file content' }]);
  });

  it('should handle offset and limit', async () => {
    vi.spyOn(fs, 'readFile').mockResolvedValue('line1\nline2\nline3\nline4\nline5');

    const result = await tool.execute('call-1', { path: 'test.txt', offset: 2, limit: 2 }, new AbortSignal());

    expect(result.content[0].text).toBe('line2\nline3');
  });

  it('should read images as base64', async () => {
    vi.spyOn(fs, 'readFile').mockResolvedValue(Buffer.from('fake-image-data'));

    const result = await tool.execute('call-1', { path: 'test.png' }, new AbortSignal());

    expect(result.content).toEqual([{
      type: 'image',
      data: Buffer.from('fake-image-data').toString('base64'),
      mimeType: 'image/png'
    }]);
  });
});
```

**Implementation**: (See Code Samples section below)

#### Day 3: Write Tool

**Test**: Write tool creates files
```typescript
// packages/core/test/tools/write.test.ts
import { createWriteTool } from '../../src/tools/write';

describe('Write tool', () => {
  it('should write file content', async () => {
    const spy = vi.spyOn(fs, 'writeFile').mockResolvedValue();
    const mkdirSpy = vi.spyOn(fs, 'mkdir').mockResolvedValue(undefined);

    const tool = createWriteTool('/test/dir');
    await tool.execute('call-1', { path: 'new/file.txt', content: 'hello' }, new AbortSignal());

    expect(mkdirSpy).toHaveBeenCalledWith(expect.stringContaining('new'), { recursive: true });
    expect(spy).toHaveBeenCalledWith(expect.any(String), 'hello');
  });
});
```

**Implementation**: Similar to read (see Code Samples)

#### Day 4: Edit Tool

**Test**: Edit tool replaces text exactly
```typescript
// packages/core/test/tools/edit.test.ts
import { createEditTool } from '../../src/tools/edit';

describe('Edit tool', () => {
  it('should replace exact text match', async () => {
    vi.spyOn(fs, 'readFile').mockResolvedValue('Hello world\nGoodbye world');
    const writeSpy = vi.spyOn(fs, 'writeFile').mockResolvedValue();

    const tool = createEditTool('/test/dir');
    await tool.execute('call-1', {
      path: 'test.txt',
      oldText: 'Goodbye world',
      newText: 'Hello again'
    }, new AbortSignal());

    expect(writeSpy).toHaveBeenCalledWith(expect.any(String), 'Hello world\nHello again');
  });

  it('should error if text appears multiple times', async () => {
    vi.spyOn(fs, 'readFile').mockResolvedValue('hello\nhello\nhello');

    const tool = createEditTool('/test/dir');
    const result = await tool.execute('call-1', {
      path: 'test.txt',
      oldText: 'hello',
      newText: 'hi'
    }, new AbortSignal());

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain('multiple matches');
  });
});
```

**Implementation**: (See Code Samples)

#### Day 5: Bash Tool

**Test**: Bash executes commands
```typescript
// packages/core/test/tools/bash.test.ts
import { createBashTool } from '../../src/tools/bash';
import { spawn } from 'child_process';

describe('Bash tool', () => {
  it('should execute command and capture output', async () => {
    // Mock spawn
    const mockProcess = {
      stdout: new EventEmitter(),
      stderr: new EventEmitter(),
      on: vi.fn((event, cb) => {
        if (event === 'close') setTimeout(() => cb(0), 10);
      })
    };
    vi.spyOn(require('child_process'), 'spawn').mockReturnValue(mockProcess);

    const tool = createBashTool('/test/dir');
    const promise = tool.execute('call-1', { command: 'echo hello' }, new AbortSignal());

    mockProcess.stdout.emit('data', Buffer.from('hello\n'));

    const result = await promise;
    expect(result.content[0].text).toContain('hello');
  });

  it('should handle timeout', async () => {
    // Test timeout logic
  });
});
```

**Implementation**: (See Code Samples)

---

## Phase 2: Memory Layer (Weeks 4-5)

### Week 4: Ledger & Handoffs

#### Day 1-2: Ledger Manager

**Test**: Ledger persists state
```typescript
// packages/core/test/memory/ledger.test.ts
import { LedgerManager } from '../../src/memory/ledger';

describe('LedgerManager', () => {
  const ledgerPath = '/tmp/test-ledger.md';
  const manager = new LedgerManager(ledgerPath);

  it('should create empty ledger', async () => {
    const ledger = await manager.load();
    expect(ledger.goal).toBe('');
    expect(ledger.done).toEqual([]);
  });

  it('should save and load ledger', async () => {
    await manager.save({
      goal: 'Build agent',
      constraints: ['Use Claude Max'],
      done: ['Setup project'],
      now: 'Implement memory',
      next: ['Build hooks'],
      decisions: [{ choice: 'SQLite for storage', reason: 'Portable' }],
      workingFiles: ['src/memory/ledger.ts']
    });

    const loaded = await manager.load();
    expect(loaded.goal).toBe('Build agent');
    expect(loaded.done).toContain('Setup project');
  });

  it('should update partial ledger', async () => {
    await manager.update({ now: 'Testing ledger' });

    const loaded = await manager.load();
    expect(loaded.now).toBe('Testing ledger');
    expect(loaded.goal).toBe('Build agent');  // Unchanged
  });
});
```

**Implementation**:
```typescript
// packages/core/src/memory/ledger.ts
import fs from 'fs/promises';

export interface Ledger {
  goal: string;
  constraints: string[];
  done: string[];
  now: string;
  next: string[];
  decisions: Array<{ choice: string; reason: string }>;
  workingFiles: string[];
  lastUpdated?: Date;
}

export class LedgerManager {
  constructor(private ledgerPath: string) {}

  async load(): Promise<Ledger> {
    try {
      const content = await fs.readFile(this.ledgerPath, 'utf-8');
      return this.parse(content);
    } catch (err) {
      // File doesn't exist, return empty
      return {
        goal: '',
        constraints: [],
        done: [],
        now: '',
        next: [],
        decisions: [],
        workingFiles: []
      };
    }
  }

  async save(ledger: Ledger): Promise<void> {
    const content = this.serialize(ledger);
    await fs.writeFile(this.ledgerPath, content, 'utf-8');
  }

  async update(partial: Partial<Ledger>): Promise<void> {
    const current = await this.load();
    await this.save({ ...current, ...partial, lastUpdated: new Date() });
  }

  private parse(content: string): Ledger {
    const ledger: Ledger = {
      goal: '',
      constraints: [],
      done: [],
      now: '',
      next: [],
      decisions: [],
      workingFiles: []
    };

    const sections = content.split('\n## ');
    for (const section of sections) {
      if (section.startsWith('Goal')) {
        ledger.goal = section.split('\n')[1]?.trim() || '';
      } else if (section.startsWith('Constraints')) {
        ledger.constraints = this.parseList(section);
      } else if (section.startsWith('Done')) {
        ledger.done = this.parseList(section);
      } else if (section.startsWith('Now')) {
        ledger.now = section.split('\n')[1]?.trim() || '';
      } else if (section.startsWith('Next')) {
        ledger.next = this.parseList(section);
      }
      // ... parse other sections
    }

    return ledger;
  }

  private parseList(section: string): string[] {
    return section
      .split('\n')
      .slice(1)
      .filter(line => line.trim().startsWith('-'))
      .map(line => line.replace(/^-\s*\[.\]\s*/, '').trim());
  }

  private serialize(ledger: Ledger): string {
    return `# Continuity Ledger

## Goal
${ledger.goal}

## Constraints
${ledger.constraints.map(c => `- ${c}`).join('\n')}

## Done
${ledger.done.map(d => `- [x] ${d}`).join('\n')}

## Now
${ledger.now}

## Next
${ledger.next.map(n => `- [ ] ${n}`).join('\n')}

## Key Decisions
${ledger.decisions.map(d => `- **${d.choice}**: ${d.reason}`).join('\n')}

## Working Files
${ledger.workingFiles.map(f => `- ${f}`).join('\n')}

*Last updated: ${ledger.lastUpdated?.toISOString() || 'never'}*
`;
  }
}
```

#### Day 3-4: Handoff Manager with FTS5

**Test**: Handoffs are searchable
```typescript
// packages/core/test/memory/handoff.test.ts
import { HandoffManager } from '../../src/memory/handoff';

describe('HandoffManager', () => {
  const dbPath = ':memory:';
  const manager = new HandoffManager(dbPath);

  beforeEach(async () => {
    await manager.initialize();
  });

  it('should create handoff', async () => {
    const id = await manager.create({
      sessionId: 'test-session',
      timestamp: new Date(),
      summary: 'Implemented OAuth flow',
      codeChanges: [
        { file: 'src/auth/oauth.ts', description: 'Added PKCE flow' }
      ],
      currentState: 'OAuth working, need to integrate with streaming',
      blockers: [],
      nextSteps: ['Wire OAuth into provider', 'Test refresh'],
      patterns: ['Use 5-minute buffer for token expiry']
    });

    expect(id).toBeTruthy();
  });

  it('should search handoffs by content', async () => {
    await manager.create({
      sessionId: 's1',
      timestamp: new Date(),
      summary: 'Fixed auth bug',
      codeChanges: [],
      currentState: 'Auth working',
      blockers: [],
      nextSteps: [],
      patterns: []
    });

    const results = await manager.search('auth', 10);
    expect(results.length).toBe(1);
    expect(results[0].summary).toContain('auth');
  });

  it('should get recent handoffs', async () => {
    await manager.create({ sessionId: 's1', /* ... */ });
    await manager.create({ sessionId: 's2', /* ... */ });

    const recent = await manager.getRecent(1);
    expect(recent.length).toBe(1);
    expect(recent[0].sessionId).toBe('s2');  // Most recent
  });
});
```

**Implementation**: (See Code Samples below)

### Week 5: Episodic Memory

#### Day 1-3: Vector Search Integration

**Test**: Episodic memory enables semantic search
```typescript
// packages/core/test/memory/episodic.test.ts
import { EpisodicMemory } from '../../src/memory/episodic';

describe('EpisodicMemory', () => {
  const memory = new EpisodicMemory(':memory:');

  beforeEach(async () => {
    await memory.initialize();
  });

  it('should archive session logs', async () => {
    const session = {
      id: 'session-1',
      messages: [
        { role: 'user', content: 'Fix auth bug' },
        { role: 'assistant', content: 'I found the issue in oauth.ts' }
      ],
      timestamp: new Date()
    };

    await memory.archive(session);

    // Verify archived
    const results = await memory.search('oauth');
    expect(results.length).toBeGreaterThan(0);
  });

  it('should perform semantic search', async () => {
    // Archive multiple sessions
    await memory.archive({ id: 's1', messages: [/* OAuth work */], timestamp: new Date() });
    await memory.archive({ id: 's2', messages: [/* UI work */], timestamp: new Date() });

    const results = await memory.search('authentication flow', { limit: 5 });

    // Should find OAuth session even though query doesn't match exactly
    expect(results.some(r => r.sessionId === 's1')).toBe(true);
  });
});
```

**Implementation**: Use sqlite-vss or alternative vector search library

#### Day 4-5: Learning Extraction

**Test**: Learnings are extracted from sessions
```typescript
// packages/core/test/memory/learnings.test.ts
import { LearningsExtractor } from '../../src/memory/learnings';

describe('LearningsExtractor', () => {
  it('should extract patterns from session', async () => {
    const session = {
      messages: [/* ... */],
      outcome: 'succeeded',
      duration: 3600
    };

    const learnings = await extractor.extract(session);

    expect(learnings.whatWorked).toBeDefined();
    expect(learnings.whatFailed).toBeDefined();
    expect(learnings.patterns).toBeDefined();
  });

  it('should save learnings to file', async () => {
    const learnings = {
      whatWorked: ['OAuth with PKCE'],
      whatFailed: ['Initial token expiry logic'],
      patterns: ['Add 5-minute buffer to token expiry']
    };

    await extractor.save('session-1', learnings);

    // Verify file exists
    expect(fs.existsSync('.agent/memory/learnings/session-1.md')).toBe(true);
  });
});
```

---

## Phase 3: Hook System (Week 6)

### Day 1-2: Hook Manager

**Test**: Hooks register and execute
```typescript
// packages/core/test/hooks/manager.test.ts
import { HookManager } from '../../src/hooks/manager';

describe('HookManager', () => {
  const manager = new HookManager();

  it('should register hook', () => {
    manager.register({
      event: 'session_start',
      handler: async (input) => ({ action: 'continue' })
    });

    expect(manager.getHooks('session_start').length).toBe(1);
  });

  it('should trigger hook and get result', async () => {
    manager.register({
      event: 'pre_tool_use',
      handler: async (input) => {
        if (input.context.toolName === 'dangerous') {
          return { action: 'block', message: 'Blocked dangerous tool' };
        }
        return { action: 'continue' };
      }
    });

    const results = await manager.trigger('pre_tool_use', {
      toolName: 'dangerous'
    });

    expect(results[0].action).toBe('block');
  });

  it('should handle hook timeout', async () => {
    manager.register({
      event: 'post_tool_use',
      timeout: 100,
      handler: async () => {
        await new Promise(resolve => setTimeout(resolve, 200));
        return { action: 'continue' };
      }
    });

    const results = await manager.trigger('post_tool_use', {});

    // Should timeout and return default
    expect(results[0].action).toBe('continue');
  });
});
```

**Implementation**: (See Code Samples)

### Day 3-4: Built-in Hooks

**Test**: SessionStart hook loads ledger
```typescript
// packages/core/test/hooks/builtin/session-start.test.ts
import { sessionStartHook } from '../../../src/hooks/builtin/session-start';

describe('SessionStart hook', () => {
  it('should load ledger and inject into context', async () => {
    // Mock ledger manager
    const mockLedger = {
      goal: 'Test goal',
      now: 'Testing',
      next: ['Write tests']
    };

    const result = await sessionStartHook({
      event: 'session_start',
      sessionId: 'test',
      context: {}
    });

    expect(result.message).toContain('Test goal');
    expect(result.message).toContain('Testing');
  });
});
```

**Implementation**: Create hooks for SessionStart, SessionEnd, PreCompact, etc.

### Day 5: Hook Discovery & Loading

**Test**: User hooks are discovered
```typescript
// packages/core/test/hooks/discovery.test.ts
import { discoverHooks } from '../../src/hooks/discovery';

describe('Hook discovery', () => {
  it('should find hooks in .agent/hooks/', async () => {
    // Create test hook files
    await fs.writeFile('.agent/hooks/custom-hook.sh', '#!/bin/bash\necho "test"');

    const hooks = await discoverHooks();

    expect(hooks.length).toBeGreaterThan(0);
    expect(hooks.some(h => h.name === 'custom-hook')).toBe(true);
  });
});
```

---

## Phase 4: Agent Loop (Weeks 7-8)

### Week 7: Core Loop

#### Day 1-3: Event Streaming Loop

**Test**: Agent loop executes and emits events
```typescript
// packages/core/test/agent/loop.test.ts
import { agentLoop } from '../../src/agent/loop';

describe('Agent loop', () => {
  it('should emit agent_start and agent_end', async () => {
    const events = [];

    for await (const event of agentLoop(config, [{ role: 'user', content: 'Hello' }])) {
      events.push(event);
    }

    expect(events[0].type).toBe('agent_start');
    expect(events[events.length - 1].type).toBe('agent_end');
  });

  it('should execute tools when called', async () => {
    const mockTool = {
      name: 'test_tool',
      execute: vi.fn().mockResolvedValue({ content: [{ type: 'text', text: 'result' }] })
    };

    const events = [];
    for await (const event of agentLoop({
      model: mockModel,
      tools: [mockTool],
      convertToLlm: (msgs) => msgs
    }, [{ role: 'user', content: 'Use test_tool' }])) {
      events.push(event);
    }

    expect(mockTool.execute).toHaveBeenCalled();
    expect(events.some(e => e.type === 'tool_execution_start')).toBe(true);
  });
});
```

**Implementation**: (See Code Samples)

### Week 8: Session Manager

#### Day 1-3: Session Lifecycle

**Test**: Sessions persist and restore
```typescript
// packages/core/test/session/manager.test.ts
import { SessionManager } from '../../src/session/manager';

describe('SessionManager', () => {
  it('should create session with unique ID', async () => {
    const session = await manager.createSession({
      model: 'claude-sonnet-4-20250514',
      cwd: '/test/dir'
    });

    expect(session.id).toBeTruthy();
    expect(session.messages).toEqual([]);
  });

  it('should persist messages to JSONL', async () => {
    const session = await manager.createSession({ /* ... */ });
    session.messages.push({ role: 'user', content: 'Hello' });

    await manager.saveSession(session);

    // Read JSONL
    const content = await fs.readFile(session.filePath, 'utf-8');
    const lines = content.trim().split('\n');
    expect(lines.length).toBe(1);

    const msg = JSON.parse(lines[0]);
    expect(msg.role).toBe('user');
  });

  it('should resume session from file', async () => {
    const original = await manager.createSession({ /* ... */ });
    original.messages.push({ role: 'user', content: 'Test' });
    await manager.saveSession(original);

    const resumed = await manager.resumeSession(original.id);
    expect(resumed.messages.length).toBe(1);
    expect(resumed.messages[0].content).toBe('Test');
  });
});
```

**Implementation**: JSONL append-only persistence

#### Day 4-5: Fork & Rewind

**Test**: Sessions can fork and rewind
```typescript
// packages/core/test/session/fork.test.ts
describe('Session forking', () => {
  it('should fork session at current state', async () => {
    const original = await manager.createSession({ /* ... */ });
    original.messages.push({ role: 'user', content: 'Message 1' });
    original.messages.push({ role: 'assistant', content: 'Response 1' });

    const forked = await manager.forkSession(original.id);

    expect(forked.id).not.toBe(original.id);
    expect(forked.messages).toEqual(original.messages);
  });

  it('should rewind session to earlier message', async () => {
    const session = await manager.createSession({ /* ... */ });
    session.messages.push({ role: 'user', content: 'M1' });
    session.messages.push({ role: 'assistant', content: 'R1' });
    session.messages.push({ role: 'user', content: 'M2' });

    await manager.rewindSession(session.id, 1);  // Rewind to after M1

    const reloaded = await manager.resumeSession(session.id);
    expect(reloaded.messages.length).toBe(2);  // M1 + R1
  });
});
```

---

## Phase 5: Dual Interface (Weeks 9-11)

### Week 9: RPC Protocol

#### Day 1-3: RPC Commands

**Test**: RPC commands execute correctly
```typescript
// packages/core/test/rpc/handler.test.ts
import { RpcHandler } from '../../src/rpc/handler';

describe('RPC Handler', () => {
  it('should handle prompt command', async () => {
    const response = await handler.handle(session, {
      type: 'prompt',
      text: 'Hello agent'
    });

    expect(response.success).toBe(true);
  });

  it('should handle get_state command', async () => {
    const response = await handler.handle(session, {
      type: 'get_state'
    });

    expect(response.success).toBe(true);
    expect(response.data.model).toBeDefined();
    expect(response.data.isStreaming).toBeDefined();
  });

  it('should handle switch_model command', async () => {
    const response = await handler.handle(session, {
      type: 'switch_model',
      modelId: 'gpt-4o'
    });

    expect(response.success).toBe(true);
    expect(session.model.id).toBe('gpt-4o');
  });
});
```

### Week 10: Terminal UI

**Test**: TUI renders correctly
```typescript
// packages/tui/test/renderer.test.ts
import { Renderer } from '../src/renderer';

describe('Terminal renderer', () => {
  it('should render text component', () => {
    const component = new Text('Hello world');
    const lines = component.render(80);

    expect(lines).toEqual(['Hello world']);
  });

  it('should perform differential rendering', () => {
    const renderer = new Renderer();
    renderer.render([new Text('Line 1'), new Text('Line 2')]);

    // Change only second line
    const output = renderer.render([new Text('Line 1'), new Text('Modified')]);

    // Should only re-render from line 2 onwards
    expect(output).toContain('Modified');
    expect(output).not.toContain('\x1b[2J');  // No full clear
  });
});
```

### Week 11: Web Interface

#### Day 1-3: WebSocket Server

**Test**: WebSocket broadcasts events
```typescript
// packages/server/test/websocket.test.ts
import { WebSocketServer } from '../src/websocket';
import WebSocket from 'ws';

describe('WebSocket server', () => {
  it('should accept connections', async () => {
    const server = new WebSocketServer(3000);
    await server.start();

    const client = new WebSocket('ws://localhost:3000');
    await new Promise(resolve => client.on('open', resolve));

    expect(client.readyState).toBe(WebSocket.OPEN);
  });

  it('should stream events to client', async () => {
    const client = new WebSocket('ws://localhost:3000');
    await new Promise(resolve => client.on('open', resolve));

    const events = [];
    client.on('message', (data) => events.push(JSON.parse(data)));

    // Trigger agent event
    session.emit('message_update', { type: 'text_delta', delta: 'Hello' });

    await new Promise(resolve => setTimeout(resolve, 100));
    expect(events.some(e => e.type === 'text_delta')).toBe(true);
  });
});
```

#### Day 4-5: React Components

**Test**: Message list renders correctly
```typescript
// packages/chat-web/test/components/MessageList.test.tsx
import { render } from '@testing-library/react';
import { MessageList } from '../src/components/MessageList';

describe('MessageList', () => {
  it('should render user and assistant messages', () => {
    const messages = [
      { role: 'user', content: 'Hello' },
      { role: 'assistant', content: [{ type: 'text', text: 'Hi there' }] }
    ];

    const { getByText } = render(<MessageList messages={messages} />);

    expect(getByText('Hello')).toBeInTheDocument();
    expect(getByText('Hi there')).toBeInTheDocument();
  });
});
```

---

## Phase 6: Productivity Features (Weeks 12-14)

### Week 12: Transcript Export & Tasks

#### Day 1-2: Export Functionality

**Test**: Transcripts export correctly
```typescript
// packages/core/test/productivity/export.test.ts
import { TranscriptExporter } from '../../src/productivity/export';

describe('Transcript export', () => {
  it('should export as markdown', async () => {
    const messages = [
      { role: 'user', content: 'Test message' },
      { role: 'assistant', content: [{ type: 'text', text: 'Response' }] }
    ];

    const md = await exporter.toMarkdown(messages);

    expect(md).toContain('# Conversation');
    expect(md).toContain('**User**: Test message');
    expect(md).toContain('**Assistant**: Response');
  });

  it('should export as HTML', async () => {
    const html = await exporter.toHTML(messages);

    expect(html).toContain('<html>');
    expect(html).toContain('<div class="message user">');
  });
});
```

#### Day 3-5: Task Tracking

**Test**: Tasks persist across sessions
```typescript
// packages/core/test/productivity/tasks.test.ts
import { TaskManager } from '../../src/productivity/tasks';

describe('Task manager', () => {
  it('should create task with tags', async () => {
    const task = await manager.create({
      description: 'Implement OAuth',
      tags: ['#auth', '#security'],
      category: 'work'
    });

    expect(task.id).toBeTruthy();
    expect(task.tags).toContain('#auth');
  });

  it('should persist to markdown file', async () => {
    await manager.create({ description: 'Test task', tags: [], category: 'work' });

    const content = await fs.readFile('.agent/tasks/work.md', 'utf-8');
    expect(content).toContain('- [ ] Test task');
  });

  it('should mark task complete', async () => {
    const task = await manager.create({ description: 'Task', tags: [], category: 'work' });
    await manager.complete(task.id);

    const content = await fs.readFile('.agent/tasks/work.md', 'utf-8');
    expect(content).toContain('- [x] Task');
  });
});
```

### Week 13: Inbox Monitoring

#### Day 1-3: Inbox Connectors

**Test**: Gmail inbox connector works
```typescript
// packages/core/test/productivity/inbox/gmail.test.ts
import { GmailInboxConnector } from '../../../src/productivity/inbox/gmail';

describe('Gmail connector', () => {
  it('should fetch unread messages', async () => {
    const connector = new GmailInboxConnector({
      credentials: mockOAuthCreds
    });

    const items = await connector.fetch();

    expect(items.length).toBeGreaterThan(0);
    expect(items[0].source).toBe('gmail');
  });

  it('should mark as processed', async () => {
    const items = await connector.fetch();
    await connector.markProcessed(items[0].id);

    // Should no longer appear in fetch
    const newItems = await connector.fetch();
    expect(newItems.some(i => i.id === items[0].id)).toBe(false);
  });
});
```

#### Day 4-5: Aggregation

**Test**: Multiple inboxes aggregate
```typescript
// packages/core/test/productivity/inbox/aggregator.test.ts
import { InboxAggregator } from '../../../src/productivity/inbox/aggregator';

describe('Inbox aggregator', () => {
  it('should aggregate from multiple sources', async () => {
    const aggregator = new InboxAggregator([
      gmailConnector,
      folderConnector,
      notionConnector
    ]);

    const items = await aggregator.fetchAll();

    expect(items.some(i => i.source === 'gmail')).toBe(true);
    expect(items.some(i => i.source === 'folder')).toBe(true);
    expect(items.some(i => i.source === 'notion')).toBe(true);
  });
});
```

### Week 14: Notes & Skills

#### Day 1-2: Notes Integration

**Test**: Notes are searchable
```typescript
// packages/core/test/productivity/notes.test.ts
import { NotesManager } from '../../src/productivity/notes';

describe('Notes manager', () => {
  it('should search notes by content', async () => {
    const results = await manager.search('OAuth implementation');

    expect(results.length).toBeGreaterThan(0);
    expect(results[0].path).toContain('.md');
  });

  it('should support PDF extraction', async () => {
    const content = await manager.readNote('reference/paper.pdf');

    expect(content).toBeTruthy();
    expect(content).not.toContain('PDF');  // Extracted text, not binary
  });
});
```

#### Day 3-5: Skills System

**Test**: Skills are discovered and executed
```typescript
// packages/core/test/skills/loader.test.ts
import { SkillLoader } from '../../src/skills/loader';

describe('Skill loader', () => {
  it('should discover skills from .agent/skills/', async () => {
    const skills = await loader.discover();

    expect(skills.length).toBeGreaterThan(0);
    expect(skills.some(s => s.name === 'commit')).toBe(true);
  });

  it('should parse SKILL.md with frontmatter', async () => {
    const skill = await loader.load('commit');

    expect(skill.name).toBe('commit');
    expect(skill.description).toBeTruthy();
    expect(skill.instructions).toBeTruthy();
  });

  it('should execute skill', async () => {
    const skill = await loader.load('commit');
    const result = await executor.execute(skill, { message: 'Test commit' });

    expect(result.success).toBe(true);
  });
});
```

---

## Phase 7: Advanced Features (Weeks 15-16)

### Week 15: Git Worktrees & tmux

#### Day 1-3: Git Worktree Integration

**Test**: Worktrees created for sessions
```typescript
// packages/core/test/session/worktree.test.ts
import { WorktreeManager } from '../../src/session/worktree';

describe('Worktree manager', () => {
  it('should create worktree for session', async () => {
    const worktree = await manager.createForSession('session-123', '/project');

    expect(worktree.path).toContain('session-123');
    expect(fs.existsSync(worktree.path)).toBe(true);
  });

  it('should cleanup worktree on session end', async () => {
    const worktree = await manager.createForSession('session-123', '/project');
    await manager.cleanup('session-123');

    expect(fs.existsSync(worktree.path)).toBe(false);
  });
});
```

#### Day 4-5: tmux Support

**Test**: Agents spawn in tmux
```typescript
// packages/core/test/tmux/spawn.test.ts
import { TmuxManager } from '../../src/tmux/manager';

describe('tmux manager', () => {
  it('should spawn agent in tmux session', async () => {
    const sessionName = await tmux.spawn('skill-name', ['arg1', 'arg2']);

    expect(sessionName).toContain('agent-skill-name');

    // Verify session exists
    const sessions = await tmux.list();
    expect(sessions.some(s => s.name === sessionName)).toBe(true);
  });

  it('should attach to existing session', async () => {
    const sessionName = await tmux.spawn('test', []);
    await tmux.attach(sessionName);

    // Verify attached (tricky to test, may need manual verification)
  });
});
```

### Week 16: Context Files & Slash Commands

#### Day 1-2: Hierarchical Context Loading

**Test**: Context files load hierarchically
```typescript
// packages/core/test/context/loader.test.ts
import { ContextLoader } from '../../src/context/loader';

describe('Context loader', () => {
  it('should load global context', async () => {
    await fs.writeFile('~/.agent/AGENTS.md', '# Global context\nGeneric rules');

    const context = await loader.load('/project/subdir');

    expect(context).toContain('Global context');
  });

  it('should merge project and global', async () => {
    await fs.writeFile('~/.agent/AGENTS.md', '# Global\nRule 1');
    await fs.writeFile('/project/AGENTS.md', '# Project\nRule 2');

    const context = await loader.load('/project/subdir');

    expect(context).toContain('Rule 1');
    expect(context).toContain('Rule 2');
  });
});
```

#### Day 3-5: Slash Commands

**Test**: Slash commands execute
```typescript
// packages/core/test/commands/slash.test.ts
import { SlashCommandHandler } from '../../src/commands/slash';

describe('Slash commands', () => {
  it('should execute /clear command', async () => {
    const result = await handler.execute('/clear', session);

    expect(session.messages.length).toBe(0);
    expect(result.message).toContain('cleared');
  });

  it('should execute custom command with arguments', async () => {
    // Create custom command
    await fs.writeFile('.agent/commands/deploy.md', `
---
name: deploy
description: Deploy to environment
arguments:
  - env: target environment
---
Deploy to {{env}}
`);

    const result = await handler.execute('/deploy prod', session);

    expect(result.message).toContain('Deploy to prod');
  });
});
```

---

## Phase 8: Multi-Model Support (Weeks 17-18)

### Week 17: Additional Providers

#### Day 1-3: OpenAI Provider

**Test**: OpenAI provider works
```typescript
// packages/core/test/providers/openai.test.ts
import { OpenAIProvider } from '../../src/providers/openai';

describe('OpenAI provider', () => {
  it('should stream with GPT-4', async () => {
    const provider = new OpenAIProvider({
      apiKey: process.env.OPENAI_API_KEY,
      model: 'gpt-4o'
    });

    const events = [];
    for await (const event of provider.stream(context)) {
      events.push(event);
    }

    expect(events.some(e => e.type === 'text_delta')).toBe(true);
  });
});
```

#### Day 4-5: Google Provider

Similar tests for Google Gemini

### Week 18: Model Evaluation

**Test**: Evaluations compare models
```typescript
// packages/core/test/eval/framework.test.ts
import { EvaluationFramework } from '../../src/eval/framework';

describe('Evaluation framework', () => {
  it('should run standard task suite', async () => {
    const results = await framework.evaluateModel('claude-sonnet-4-20250514', {
      tasks: standardTasks
    });

    expect(results.metrics.latencyMs).toBeGreaterThan(0);
    expect(results.metrics.tokensUsed.input).toBeGreaterThan(0);
  });

  it('should compare multiple models', async () => {
    const comparison = await framework.compare([
      'claude-sonnet-4-20250514',
      'gpt-4o'
    ], standardTasks);

    expect(comparison.length).toBe(2);
    expect(comparison[0].modelId).toBeTruthy();
  });
});
```

---

## Phase 9: Polish & Production (Weeks 19-20)

### Week 19: Integration Testing & Bug Fixes

- End-to-end workflow tests
- Performance optimization
- Memory leak detection
- Error handling improvements

### Week 20: Documentation & Deployment

- API documentation
- User guides
- Deployment scripts
- Migration tools

---

## Deployment Architecture

### launchd Configuration (macOS)

```xml
<!-- ~/Library/LaunchAgents/com.user.agent-server.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.agent-server</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/node</string>
        <string>/opt/agent/packages/server/dist/index.js</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>StandardOutPath</key>
    <string>/var/log/agent/stdout.log</string>

    <key>StandardErrorPath</key>
    <string>/var/log/agent/stderr.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>NODE_ENV</key>
        <string>production</string>
        <key>HOME</key>
        <string>/Users/username</string>
    </dict>

    <key>WorkingDirectory</key>
    <string>/opt/agent</string>
</dict>
</plist>
```

Load with:
```bash
launchctl load ~/Library/LaunchAgents/com.user.agent-server.plist
```

---

## Code Samples: Critical Paths

### Read Tool Implementation

```typescript
// packages/core/src/tools/read.ts
import fs from 'fs/promises';
import path from 'path';
import { Type } from '@sinclair/typebox';
import type { AgentTool } from '../types';

const readSchema = Type.Object({
  path: Type.String({ description: 'File path to read (relative or absolute)' }),
  offset: Type.Optional(Type.Number({ description: 'Starting line (1-indexed)' })),
  limit: Type.Optional(Type.Number({ description: 'Max lines to return' })),
});

type ReadParams = { path: string; offset?: number; limit?: number };
type ReadDetails = { totalLines?: number; truncated?: boolean };

export function createReadTool(cwd: string): AgentTool<ReadParams, ReadDetails> {
  return {
    name: 'read',
    label: 'Read File',
    description: 'Read contents of text files or images',
    parameters: readSchema,

    async execute(toolCallId, params, signal) {
      const absolutePath = path.resolve(cwd, params.path);

      // Check abort
      if (signal.aborted) {
        return { content: [{ type: 'text', text: 'Aborted' }], isError: true };
      }

      // Check file exists
      try {
        await fs.access(absolutePath, fs.constants.R_OK);
      } catch (err) {
        return {
          content: [{ type: 'text', text: `File not found: ${params.path}` }],
          isError: true
        };
      }

      // Detect image
      const ext = path.extname(absolutePath).toLowerCase();
      if (['.jpg', '.jpeg', '.png', '.gif', '.webp'].includes(ext)) {
        const buffer = await fs.readFile(absolutePath);
        return {
          content: [{
            type: 'image',
            data: buffer.toString('base64'),
            mimeType: `image/${ext.slice(1)}`
          }]
        };
      }

      // Read text file
      const content = await fs.readFile(absolutePath, 'utf-8');
      const lines = content.split('\n');

      // Apply offset and limit
      const offset = (params.offset || 1) - 1;  // Convert to 0-indexed
      const limit = params.limit;

      if (offset >= lines.length) {
        return {
          content: [{ type: 'text', text: `Offset ${params.offset} exceeds file length (${lines.length} lines)` }],
          isError: true
        };
      }

      const slice = limit ? lines.slice(offset, offset + limit) : lines.slice(offset);
      const truncated = limit && (offset + limit) < lines.length;

      let text = slice.join('\n');
      if (truncated) {
        text += `\n\n... (showing lines ${offset + 1}-${offset + slice.length} of ${lines.length})`;
      }

      return {
        content: [{ type: 'text', text }],
        details: { totalLines: lines.length, truncated }
      };
    }
  };
}
```

### Handoff Manager with FTS5

```typescript
// packages/core/src/memory/handoff.ts
import Database from 'better-sqlite3';

export interface Handoff {
  id?: string;
  sessionId: string;
  timestamp: Date;
  summary: string;
  codeChanges: Array<{ file: string; description: string }>;
  currentState: string;
  blockers: string[];
  nextSteps: string[];
  patterns: string[];
}

export class HandoffManager {
  private db: Database.Database;

  constructor(dbPath: string) {
    this.db = new Database(dbPath);
  }

  async initialize(): Promise<void> {
    // Create tables
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS handoffs (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        summary TEXT NOT NULL,
        code_changes TEXT,
        current_state TEXT,
        blockers TEXT,
        next_steps TEXT,
        patterns TEXT
      );

      CREATE VIRTUAL TABLE IF NOT EXISTS handoffs_fts USING fts5(
        session_id,
        summary,
        code_changes,
        current_state,
        patterns,
        content='handoffs',
        content_rowid='rowid'
      );

      CREATE TRIGGER IF NOT EXISTS handoffs_ai AFTER INSERT ON handoffs BEGIN
        INSERT INTO handoffs_fts(rowid, session_id, summary, code_changes, current_state, patterns)
        VALUES (new.rowid, new.session_id, new.summary, new.code_changes, new.current_state, new.patterns);
      END;
    `);
  }

  async create(handoff: Handoff): Promise<string> {
    const id = crypto.randomUUID();
    const stmt = this.db.prepare(`
      INSERT INTO handoffs (id, session_id, timestamp, summary, code_changes, current_state, blockers, next_steps, patterns)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);

    stmt.run(
      id,
      handoff.sessionId,
      handoff.timestamp.getTime(),
      handoff.summary,
      JSON.stringify(handoff.codeChanges),
      handoff.currentState,
      JSON.stringify(handoff.blockers),
      JSON.stringify(handoff.nextSteps),
      JSON.stringify(handoff.patterns)
    );

    return id;
  }

  async search(query: string, limit = 10): Promise<Handoff[]> {
    const stmt = this.db.prepare(`
      SELECT h.* FROM handoffs h
      INNER JOIN handoffs_fts fts ON h.rowid = fts.rowid
      WHERE handoffs_fts MATCH ?
      ORDER BY rank
      LIMIT ?
    `);

    const rows = stmt.all(query, limit);
    return rows.map(this.deserialize);
  }

  async getRecent(n = 5): Promise<Handoff[]> {
    const stmt = this.db.prepare(`
      SELECT * FROM handoffs
      ORDER BY timestamp DESC
      LIMIT ?
    `);

    const rows = stmt.all(n);
    return rows.map(this.deserialize);
  }

  private deserialize(row: any): Handoff {
    return {
      id: row.id,
      sessionId: row.session_id,
      timestamp: new Date(row.timestamp),
      summary: row.summary,
      codeChanges: JSON.parse(row.code_changes || '[]'),
      currentState: row.current_state,
      blockers: JSON.parse(row.blockers || '[]'),
      nextSteps: JSON.parse(row.next_steps || '[]'),
      patterns: JSON.parse(row.patterns || '[]')
    };
  }
}
```

### Hook Manager

```typescript
// packages/core/src/hooks/manager.ts
export type HookEvent =
  | 'session_start'
  | 'session_end'
  | 'pre_tool_use'
  | 'post_tool_use'
  | 'pre_compact'
  | 'user_prompt'
  | 'stop'
  | 'subagent_stop';

export interface HookInput {
  event: HookEvent;
  sessionId: string;
  context: Record<string, unknown>;
}

export interface HookOutput {
  action: 'continue' | 'block' | 'modify';
  message?: string;
  modifiedArgs?: Record<string, unknown>;
}

export interface HookHandler {
  event: HookEvent;
  matcher?: string;  // Regex pattern
  timeout?: number;   // Milliseconds
  handler: (input: HookInput) => Promise<HookOutput>;
}

export class HookManager {
  private hooks = new Map<HookEvent, HookHandler[]>();

  register(hook: HookHandler): void {
    const handlers = this.hooks.get(hook.event) || [];
    handlers.push(hook);
    this.hooks.set(hook.event, handlers);
  }

  async trigger(event: HookEvent, context: Record<string, unknown>): Promise<HookOutput[]> {
    const handlers = this.hooks.get(event) || [];
    const results: HookOutput[] = [];

    for (const hook of handlers) {
      // Check matcher if present
      if (hook.matcher && context.toolName) {
        const regex = new RegExp(hook.matcher);
        if (!regex.test(context.toolName as string)) {
          continue;
        }
      }

      // Execute with timeout
      const timeout = hook.timeout || 30000;
      try {
        const result = await Promise.race([
          hook.handler({ event, sessionId: context.sessionId as string, context }),
          new Promise<HookOutput>((_, reject) =>
            setTimeout(() => reject(new Error('Hook timeout')), timeout)
          )
        ]);
        results.push(result);
      } catch (err) {
        console.error(`Hook error for ${event}:`, err);
        results.push({ action: 'continue' });
      }
    }

    return results;
  }

  getHooks(event: HookEvent): HookHandler[] {
    return this.hooks.get(event) || [];
  }
}
```

### Agent Loop

```typescript
// packages/core/src/agent/loop.ts
export interface AgentLoopConfig {
  model: LLMProvider;
  tools: AgentTool[];
  convertToLlm: (messages: AgentMessage[]) => Message[];
  transformContext?: (messages: AgentMessage[]) => Promise<AgentMessage[]>;
  getQueuedMessages?: () => AgentMessage[];
  hookManager?: HookManager;
}

export async function* agentLoop(
  config: AgentLoopConfig,
  initialMessages: AgentMessage[]
): AsyncGenerator<AgentEvent> {
  yield { type: 'agent_start' };

  let messages = [...initialMessages];

  while (true) {
    // Transform context if needed
    if (config.transformContext) {
      messages = await config.transformContext(messages);
    }

    // Convert to LLM-compatible messages
    const llmMessages = config.convertToLlm(messages);

    // Stream response
    yield { type: 'turn_start' };

    let response: AssistantMessage | null = null;
    for await (const event of config.model.stream({ messages: llmMessages, tools: config.tools })) {
      yield { type: 'message_update', event };

      if (event.type === 'done') {
        response = event.message;
      }
    }

    yield { type: 'turn_end' };

    if (!response) {
      yield { type: 'agent_end' };
      break;
    }

    messages.push(response);

    // Extract tool calls
    const toolCalls = response.content.filter(c => c.type === 'tool_use') as ToolCall[];

    if (toolCalls.length === 0) {
      // No tools to execute, conversation complete
      yield { type: 'agent_end' };
      break;
    }

    // Execute tools
    for (const call of toolCalls) {
      yield { type: 'tool_execution_start', toolCallId: call.id, name: call.name, arguments: call.arguments };

      const tool = config.tools.find(t => t.name === call.name);
      if (!tool) {
        yield {
          type: 'tool_execution_end',
          toolCallId: call.id,
          result: { content: [{ type: 'text', text: `Unknown tool: ${call.name}` }], isError: true }
        };
        continue;
      }

      // Trigger pre-tool hook
      if (config.hookManager) {
        const hookResults = await config.hookManager.trigger('pre_tool_use', {
          toolName: call.name,
          arguments: call.arguments
        });

        const blocked = hookResults.find(r => r.action === 'block');
        if (blocked) {
          yield {
            type: 'tool_execution_end',
            toolCallId: call.id,
            result: { content: [{ type: 'text', text: blocked.message || 'Blocked by hook' }], isError: true }
          };
          continue;
        }
      }

      // Execute tool
      const abortController = new AbortController();
      try {
        const result = await tool.execute(
          call.id,
          call.arguments,
          abortController.signal,
          (update) => {
            yield { type: 'tool_execution_update', toolCallId: call.id, update };
          }
        );

        yield { type: 'tool_execution_end', toolCallId: call.id, result };

        messages.push({
          role: 'toolResult',
          toolCallId: call.id,
          content: result.content,
          isError: result.isError
        });

        // Trigger post-tool hook
        if (config.hookManager) {
          await config.hookManager.trigger('post_tool_use', {
            toolName: call.name,
            result
          });
        }
      } catch (err) {
        yield {
          type: 'tool_execution_end',
          toolCallId: call.id,
          result: {
            content: [{ type: 'text', text: `Tool error: ${err.message}` }],
            isError: true
          }
        };
      }
    }

    // Check for queued messages
    if (config.getQueuedMessages) {
      const queued = config.getQueuedMessages();
      if (queued.length > 0) {
        messages.push(...queued);
      }
    }
  }

  yield { type: 'agent_end' };
}
``

## Conclusion

This implementation plan provides a **complete roadmap** for building a sophisticated, dual-interface coding agent with:

- **Memory-first architecture** (4-level hierarchy, episodic search)
- **Dual interfaces** (terminal + chat) as first-class citizens
- **Always-on service** for instant access
- **Multi-model support** with evaluation framework
- **Productivity features** (tasks, inbox, notes, export)
- **Comprehensive hooks** for customization
- **Strict TDD methodology** ensuring quality

**Total timeline: 20 weeks** from zero to production-ready system.

**Key decisions:**
- Hybrid approach: Build fresh, reuse pi-ai
- SQLite for state persistence
- WebSocket for dual-interface
- JSONL for session logs
- Hook system for extensibility

**Next steps:**
1. Review this plan
2. Set up repository structure
3. Begin Phase 1 (Foundation)
4. Follow TDD workflow religiously

Every feature has tests written first. Every component is documented. The result will be a robust, maintainable, extensible coding agent tailored to your exact needs.
