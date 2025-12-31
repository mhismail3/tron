# Dual-Interface Coding Agent Architecture: A Deep Dive into pi-mono

**Date:** 2025-12-31
**Status:** published
**Tags:** llm, agent, coding-assistant, architecture, typescript, dual-interface, claude-max, oauth

## Summary

This research report provides a comprehensive reverse-engineering analysis of Mario Zechner's **pi-mono** monorepo, which implements a production-ready coding agent with multi-provider LLM support. The goal is to understand how to build a similar system that supports **both terminal UI and chat-native interfaces** as first-class citizens—enabling sophisticated coding assistance for technical users via terminal while remaining accessible to non-technical users via chat.

The key insight from this analysis: **pi's architecture already supports dual-interface operation** through its RPC mode, JSON event streaming, and session state observability. This report documents how to leverage (or replicate) this architecture for a Claude-only implementation.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Package Deep Dive: pi-ai (Unified LLM API)](#2-package-deep-dive-pi-ai)
3. [Package Deep Dive: pi-agent (Agent Loop)](#3-package-deep-dive-pi-agent)
4. [Package Deep Dive: pi-coding-agent](#4-package-deep-dive-pi-coding-agent)
5. [Package Deep Dive: pi-tui (Terminal Framework)](#5-package-deep-dive-pi-tui)
6. [Claude Max OAuth Integration](#6-claude-max-oauth-integration)
7. [Dual-Interface Architecture Design](#7-dual-interface-architecture-design)
8. [Implementation Recommendations](#8-implementation-recommendations)
9. [Comparison with Clauset](#9-comparison-with-clauset)
10. [Appendix: Code Samples & Schemas](#appendix-code-samples--schemas)

---

## 1. Architecture Overview

### The Four-Package Architecture

Pi consists of four interconnected packages, each with a single responsibility:

```
┌─────────────────────────────────────────────────────────────────────┐
│                         pi-coding-agent                              │
│  (CLI, session management, tools, hooks, skills, context files)     │
├─────────────────────────────────────────────────────────────────────┤
│                           pi-agent                                   │
│  (Agent loop, tool execution, event streaming, state management)    │
├─────────────────────────────────────────────────────────────────────┤
│                            pi-ai                                     │
│  (Multi-provider API, streaming, tool calling, OAuth, cost tracking)│
├─────────────────────────────────────────────────────────────────────┤
│                           pi-tui                                     │
│  (Terminal rendering, components, input handling, themes)           │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Design Principles

From Mario Zechner's blog post, the philosophy is:

1. **Minimalism**: Under 1,000 tokens for system prompt + tool definitions
2. **Four core tools**: `read`, `write`, `edit`, `bash` (sufficient for 95% of tasks)
3. **Observability over automation**: No hidden sub-agents, file-based state
4. **Context engineering priority**: Explicit control over what enters the model context
5. **YOLO mode by default**: Trust the model, run in containers if paranoid

### Dual-Interface Capability

The architecture supports three operational modes:

| Mode | Interface | Use Case |
|------|-----------|----------|
| **Interactive** | Terminal TUI | Developer workflow |
| **JSON** | Stdout streaming | Programmatic integration |
| **RPC** | Stdin/stdout JSON protocol | Dual-interface applications |

The RPC mode is the key to dual-interface support—it exposes the full agent state and event stream via a machine-readable protocol.

---

## 2. Package Deep Dive: pi-ai

### Purpose

A **unified LLM API wrapper** that abstracts provider differences while maintaining full feature access. Only includes models that support tool calling (required for agentic workflows).

### Supported Providers

- Anthropic (Claude) - including **OAuth for Max/Pro subscriptions**
- OpenAI (Completions & Responses APIs)
- Google (Gemini via API and CLI OAuth)
- Mistral, Groq, Cerebras, xAI
- OpenRouter (meta-provider)
- GitHub Copilot (OAuth)
- OpenAI-compatible (Ollama, vLLM, LM Studio)

### Core Data Structures

#### Context (Serializable Conversation State)

```typescript
interface Context {
  systemPrompt?: string;
  messages: Message[];
  tools?: Tool[];
}
```

**Critical insight**: Contexts are fully serializable as JSON, enabling:
- Database persistence
- Cross-session transfer
- Cross-provider handoffs (switch from Claude to GPT mid-conversation)

#### Message Types

```typescript
type Message = UserMessage | AssistantMessage | ToolResultMessage;

interface UserMessage {
  role: "user";
  content: string | (TextContent | ImageContent)[];
  timestamp?: number;
}

interface AssistantMessage {
  role: "assistant";
  content: (TextContent | ThinkingContent | ToolCall)[];
  usage?: { inputTokens: number; outputTokens: number };
  cost?: { total: number };
  stopReason?: "end_turn" | "tool_use" | "max_tokens" | "error";
}

interface ToolResultMessage {
  role: "toolResult";
  toolCallId: string;
  content: string | (TextContent | ImageContent)[];
  isError?: boolean;
}
```

#### Tool Definition (TypeBox Schema)

```typescript
interface Tool<TParams = unknown> {
  name: string;
  description: string;
  parameters: TSchema; // TypeBox schema
}
```

Tools use **TypeBox** for type-safe parameter definitions with AJV validation at runtime.

### Streaming Architecture

#### Stream Events

```typescript
type AssistantMessageEvent =
  | { type: "start" }
  | { type: "text_start" }
  | { type: "text_delta"; delta: string }
  | { type: "text_end"; text: string; signature?: string }
  | { type: "thinking_start" }
  | { type: "thinking_delta"; delta: string }
  | { type: "thinking_end"; thinking: string; signature?: string }
  | { type: "toolcall_start"; toolCallId: string; name: string }
  | { type: "toolcall_delta"; toolCallId: string; argumentsDelta: string }
  | { type: "toolcall_end"; toolCall: ToolCall }
  | { type: "done"; message: AssistantMessage; stopReason: string }
  | { type: "error"; error: Error };
```

**Key feature**: Streaming exposes **partial tool arguments** during generation, enabling real-time UI updates before the tool call completes.

#### Usage Pattern

```typescript
import { getModel, stream, Context } from "@mariozechner/pi-ai";

const model = getModel("anthropic", "claude-sonnet-4-20250514");
const context: Context = {
  systemPrompt: "You are a helpful coding assistant.",
  messages: [{ role: "user", content: "What files are in this directory?" }],
  tools: [readTool, writeTool, editTool, bashTool],
};

for await (const event of stream(model, context)) {
  switch (event.type) {
    case "text_delta":
      process.stdout.write(event.delta);
      break;
    case "toolcall_end":
      // Execute tool, add result to context
      break;
    case "done":
      context.messages.push(event.message);
      break;
  }
}
```

### Cross-Provider Context Handoffs

Pi handles provider-specific quirks during handoffs:

- **Thinking traces**: Claude's `<thinking>` blocks convert to XML-tagged text for other providers
- **Tool call IDs**: Sanitized to match regex `^[a-zA-Z0-9_-]+$`
- **Empty messages**: Filtered before API calls
- **Image support**: Graceful degradation for text-only models

---

## 3. Package Deep Dive: pi-agent

### Purpose

The **agent loop orchestrator** that handles tool execution, message transformation, and event streaming. Separates LLM concerns from application-specific logic.

### Core Architecture

#### Two Message Domains

```
┌──────────────────────┐     convertToLlm()     ┌──────────────────────┐
│    AgentMessage[]    │ ──────────────────────▶│      Message[]       │
│  (app + LLM types)   │                        │   (LLM-only types)   │
└──────────────────────┘                        └──────────────────────┘
     ▲                                                    │
     │                                                    │
     │  Application layer                    LLM API layer
     │  (custom types, UI state)             (user, assistant, toolResult)
```

This separation enables:
- Custom message types for UI (artifacts, notifications, bash execution records)
- Clean LLM context without UI cruft
- Extensibility via TypeScript declaration merging

#### Agent State

```typescript
interface AgentState {
  systemPrompt: string;
  model: Model;
  thinkingLevel?: ThinkingLevel;
  tools: AgentTool[];
  messages: AgentMessage[];
  isStreaming: boolean;
  streamMessage?: AssistantMessage;  // Partial during streaming
  pendingToolCalls: Set<string>;
  error?: Error;
}
```

### Agent Loop Mechanics

```typescript
async function* agentLoop(config: AgentLoopConfig, messages: AgentMessage[]) {
  yield { type: "agent_start" };

  while (true) {
    // 1. Convert messages for LLM
    const llmMessages = config.convertToLlm(messages);

    // 2. Stream assistant response
    yield { type: "turn_start" };
    for await (const event of stream(config.model, { messages: llmMessages })) {
      yield { type: "message_update", event };
    }
    yield { type: "turn_end" };

    // 3. Check for tool calls
    const toolCalls = extractToolCalls(response);
    if (toolCalls.length === 0) break;  // No tools = conversation complete

    // 4. Execute tools
    for (const call of toolCalls) {
      yield { type: "tool_execution_start", call };
      const result = await executeTool(call, config.tools);
      yield { type: "tool_execution_end", call, result };
      messages.push(result);
    }

    // 5. Check for user interruption
    const queued = config.getQueuedMessages?.();
    if (queued?.length) {
      messages.push(...queued);
    }
  }

  yield { type: "agent_end" };
}
```

**Key insight**: The loop continues until the model stops calling tools—no artificial step limits.

### Tool Execution

```typescript
interface AgentTool<TParams = unknown, TDetails = unknown> extends Tool<TParams> {
  label: string;  // UI-friendly name
  execute: (
    toolCallId: string,
    params: TParams,
    signal: AbortSignal,
    onUpdate?: (update: string) => void  // Streaming progress
  ) => Promise<AgentToolResult<TDetails>>;
}

interface AgentToolResult<TDetails = unknown> {
  content: (TextContent | ImageContent)[];
  details?: TDetails;  // Structured metadata for UI
}
```

Tools can stream progress via `onUpdate()` for long-running operations.

### Event System

The agent emits granular events for UI synchronization:

```
agent_start
  └─ turn_start
       ├─ message_start
       ├─ message_update (streaming deltas)
       └─ message_end
       ├─ tool_execution_start
       ├─ tool_execution_update (progress)
       └─ tool_execution_end
  └─ turn_end
agent_end
```

---

## 4. Package Deep Dive: pi-coding-agent

### Purpose

The **production CLI** that combines all packages with session management, custom tools, hooks, skills, and context file support.

### Directory Structure

```
packages/coding-agent/src/
├── cli/           # CLI entry point, argument parsing
├── core/
│   ├── agent-session.ts    # Session lifecycle & persistence
│   ├── session-manager.ts  # Multi-session orchestration
│   ├── settings-manager.ts # User preferences
│   ├── sdk.ts              # Programmatic API
│   ├── tools/              # Built-in tools
│   │   ├── read.ts
│   │   ├── write.ts
│   │   ├── edit.ts
│   │   ├── bash.ts
│   │   ├── grep.ts
│   │   ├── find.ts
│   │   └── ls.ts
│   ├── hooks/              # Lifecycle event handlers
│   ├── custom-tools/       # User-defined tool loader
│   ├── skills.ts           # Capability bundles
│   ├── compaction/         # Context summarization
│   └── messages.ts         # Custom message types
├── modes/
│   ├── interactive/        # Terminal UI mode
│   ├── rpc/                # RPC protocol mode
│   │   ├── rpc-mode.ts
│   │   ├── rpc-types.ts
│   │   └── rpc-client.ts
│   └── print-mode.ts       # Non-interactive output
└── utils/
```

### Session Management

Sessions persist to `~/.pi/agent/sessions/` as JSONL files:

```
~/.pi/agent/sessions/
└── Users/
    └── moose/
        └── projects/
            └── my-app/
                ├── session-2025-12-31T10-30-00.jsonl
                └── session-2025-12-31T14-45-00.jsonl
```

Each line in the JSONL file is a message entry, enabling:
- Incremental persistence (append-only)
- Easy inspection/debugging
- Session branching (fork conversation history)
- Tree navigation (within same file)

### Built-in Tools

#### read

```typescript
const readSchema = Type.Object({
  path: Type.String({ description: "File path (relative or absolute)" }),
  offset: Type.Optional(Type.Number({ description: "Starting line (1-indexed)" })),
  limit: Type.Optional(Type.Number({ description: "Max lines to return" })),
});
```

Features:
- Supports text files and images (jpg, png, gif, webp)
- Truncates to 100 lines or 30KB (whichever first)
- Returns base64 for images
- Provides truncation metadata for navigation

#### write

```typescript
const writeSchema = Type.Object({
  path: Type.String({ description: "File path to write" }),
  content: Type.String({ description: "Content to write" }),
});
```

Features:
- Creates parent directories automatically
- Returns unified diff of changes

#### edit

```typescript
const editSchema = Type.Object({
  path: Type.String({ description: "File path to edit" }),
  oldText: Type.String({ description: "Exact text to replace" }),
  newText: Type.String({ description: "Replacement text" }),
});
```

Features:
- **Exact match required** (no regex)
- Fails if multiple matches found (disambiguation needed)
- Normalizes line endings for comparison
- Uses `indexOf` to avoid special character interpretation

#### bash

```typescript
const bashSchema = Type.Object({
  command: Type.String({ description: "Command to execute" }),
  timeout: Type.Optional(Type.Number({ description: "Timeout in seconds" })),
});
```

Features:
- Executes in shell context
- Streams large outputs to temp files
- Truncates displayed output (configurable limits)
- Handles abort signals and timeouts
- Kills entire process tree on cancellation

### Custom Message Types

Pi extends the base message types with application-specific variants:

```typescript
interface BashExecutionMessage {
  role: "bashExecution";
  command: string;
  output: string;
  exitCode: number;
  cancelled: boolean;
  truncated: boolean;
  fullOutputPath?: string;  // When output exceeds limits
}

interface CompactionSummaryMessage {
  role: "compactionSummary";
  summary: string;  // Wrapped in <summary> tags for LLM
}

interface BranchSummaryMessage {
  role: "branchSummary";
  summary: string;
}

interface HookMessage {
  role: "hookMessage";
  customType: string;
  content: string | Content[];
  display: boolean;  // Show in UI?
  details?: unknown;
}
```

The `convertToLlm()` function transforms these to user messages for the LLM.

### Hooks System

Hooks are TypeScript modules in `~/.pi/agent/hooks/` that intercept lifecycle events:

```typescript
// Example: block dangerous commands
export default function dangerousCommandHook(api: HookApi) {
  api.on("tool_execution_start", (event) => {
    if (event.name === "bash" && event.params.command.includes("rm -rf")) {
      throw new Error("Blocked dangerous command");
    }
  });
}
```

Hook API capabilities:
- `api.on(event, handler)` - Subscribe to events
- `api.sendMessage(message, triggerTurn)` - Inject messages
- `api.appendEntry(type, data)` - Add custom entries to session

### Context Files (AGENTS.md / CLAUDE.md)

Pi loads project context from:
1. `AGENTS.md` in project root (or any parent directory)
2. `CLAUDE.md` as fallback
3. Custom path via `--context` flag

Content is prepended to the system prompt.

### Auto-Compaction

When context approaches token limits, pi automatically:
1. Summarizes older messages using the LLM
2. Replaces them with a `<summary>` block
3. Preserves ~20,000 tokens of recent context

This enables **hundreds of exchanges** in a single session without context exhaustion.

---

## 5. Package Deep Dive: pi-tui

### Purpose

A **minimal terminal UI framework** optimized for flicker-free rendering in native terminal scrollback (not full-screen takeover).

### Rendering Architecture

#### Three-Strategy Differential Rendering

```
1. Initial render: Output all lines
2. Width change: Clear screen, full re-render
3. Normal update: Find first changed line, re-render from there
```

All updates wrapped in synchronized output (`CSI 2026h`/`CSI 2026l`) for atomic rendering.

#### Component Interface

```typescript
interface Component {
  render(width: number): string[];  // Returns array of lines
  handleInput?(data: string): void;  // Raw keyboard input
  invalidate?(): void;              // Clear cached render
}
```

**Critical constraint**: Each line must not exceed `width` or the TUI errors.

### Built-in Components

| Component | Purpose |
|-----------|---------|
| `Text` | Multi-line with word wrapping |
| `TruncatedText` | Single-line with ellipsis |
| `Input` | Single-line text field |
| `Editor` | Multi-line with autocomplete |
| `Markdown` | Syntax-highlighted rendering |
| `SelectList` | Interactive menu |
| `Loader` | Animated spinner |
| `Image` | Kitty/iTerm2 graphics protocol |
| `Box` | Container with padding/background |

### Terminal Abstraction

```typescript
interface Terminal {
  write(data: string): void;
  onInput(handler: (data: string) => void): void;
  getSize(): { columns: number; rows: number };
}

// Implementations
class ProcessTerminal implements Terminal { /* Uses process.stdin/stdout */ }
class VirtualTerminal implements Terminal { /* Uses @xterm/headless for testing */ }
```

This abstraction enables:
- Unit testing with virtual terminals
- Multiple execution environments
- Potential browser-based terminal emulation

---

## 6. Claude Max OAuth Integration

### The Key to Using Subscription Instead of API

Pi enables using your **Claude Max/Pro subscription** for API calls instead of paying per-token. This is critical for cost-effective agent usage.

### OAuth Flow

```
┌─────────────┐     1. Generate PKCE     ┌─────────────────────────────┐
│   pi CLI    │ ─────────────────────────▶│ Authorization URL           │
│             │                           │ claude.ai/oauth/authorize   │
└─────────────┘                           └─────────────────────────────┘
      │                                              │
      │  2. User opens URL, logs in                  │
      ▼                                              ▼
┌─────────────┐     3. Paste auth code    ┌─────────────────────────────┐
│   Browser   │ ◀───────────────────────── │ Anthropic consent page      │
│             │                           │ Returns authorization code  │
└─────────────┘                           └─────────────────────────────┘
      │
      │  4. Exchange code for tokens
      ▼
┌─────────────┐     5. POST to token      ┌─────────────────────────────┐
│   pi CLI    │ ─────────────────────────▶│ console.anthropic.com       │
│             │                           │ /v1/oauth/token              │
│             │ ◀───────────────────────── │ Returns access + refresh    │
└─────────────┘     6. Store tokens       └─────────────────────────────┘
```

### Implementation Details

#### PKCE (Proof Key for Code Exchange)

```typescript
// Generate cryptographic verifier
const verifier = generateRandomString(64);
const challenge = base64url(sha256(verifier));

// Authorization URL with PKCE
const authUrl = new URL("https://claude.ai/oauth/authorize");
authUrl.searchParams.set("client_id", ANTHROPIC_CLIENT_ID);
authUrl.searchParams.set("redirect_uri", "urn:ietf:wg:oauth:2.0:oob");
authUrl.searchParams.set("response_type", "code");
authUrl.searchParams.set("scope", "user:inference user:profile");
authUrl.searchParams.set("code_challenge", challenge);
authUrl.searchParams.set("code_challenge_method", "S256");
```

#### Token Storage

Tokens stored in `~/.pi/agent/auth.json`:

```json
{
  "anthropic": {
    "type": "oauth",
    "accessToken": "sk-ant-oat-...",
    "refreshToken": "...",
    "expiresAt": 1735689600000
  }
}
```

#### API Usage with OAuth

When using OAuth tokens (prefix `sk-ant-oat`), the Anthropic client requires:

```typescript
const client = new Anthropic({
  authToken: credentials.accessToken,  // NOT apiKey
  dangerouslyAllowBrowser: true,
});

// Required headers
headers["anthropic-beta"] = "oauth-2025-04-20,<other-features>";

// Required system prompt (enforced by Anthropic)
systemPrompt = "You are Claude Code, Anthropic's official CLI for Claude.";
```

#### Token Refresh

```typescript
async function refreshAnthropicToken(credentials: OAuthCredentials) {
  const response = await fetch("https://console.anthropic.com/v1/oauth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: credentials.refreshToken,
      client_id: ANTHROPIC_CLIENT_ID,
    }),
  });

  const { access_token, refresh_token, expires_in } = await response.json();
  return {
    accessToken: access_token,
    refreshToken: refresh_token,
    expiresAt: Date.now() + (expires_in - 300) * 1000,  // 5-minute buffer
  };
}
```

---

## 7. Dual-Interface Architecture Design

### The Core Insight

Pi's RPC mode already provides everything needed for dual-interface operation:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Shared Agent Core                             │
│  (Session state, tool execution, context management, persistence)   │
└─────────────────────────────────────────────────────────────────────┘
         │                                           │
         │ RPC Protocol                              │ Direct API
         │ (JSON over stdin/stdout)                  │
         ▼                                           ▼
┌─────────────────────┐                 ┌─────────────────────┐
│    Chat Interface   │                 │   Terminal UI       │
│  (Web/Mobile PWA)   │                 │   (Interactive)     │
│                     │                 │                     │
│  • Non-tech users   │                 │  • Developers       │
│  • Simplified UX    │                 │  • Full control     │
│  • Touch-friendly   │                 │  • Keyboard-driven  │
└─────────────────────┘                 └─────────────────────┘
```

### RPC Protocol Specification

#### Commands (Client → Agent)

```typescript
type RpcCommand =
  // Prompting
  | { type: "prompt"; text: string; images?: ImageData[] }
  | { type: "queue_message"; text: string }
  | { type: "abort" }
  | { type: "reset" }

  // State queries
  | { type: "get_state" }
  | { type: "get_messages" }
  | { type: "get_session_stats" }
  | { type: "get_available_models" }

  // Configuration
  | { type: "set_model"; modelId: string }
  | { type: "cycle_model" }
  | { type: "set_thinking_level"; level: ThinkingLevel }
  | { type: "cycle_thinking_level" }
  | { type: "set_queue_mode"; mode: "all" | "one-at-a-time" }
  | { type: "set_auto_compaction"; enabled: boolean }
  | { type: "set_auto_retry"; enabled: boolean }

  // Operations
  | { type: "compact" }
  | { type: "bash"; command: string }
  | { type: "abort_bash" }
  | { type: "branch"; summary?: string }
  | { type: "switch_session"; path: string }
  | { type: "export_html"; outputPath: string };
```

#### Responses (Agent → Client)

```typescript
interface RpcResponse<T = unknown> {
  id?: string;  // Correlation ID
  type: "response";
  command: string;
  success: boolean;
  data?: T;
  error?: string;
}
```

#### Events (Agent → Client, streamed)

```typescript
type RpcEvent =
  | AgentEvent  // All standard agent events
  | { type: "hook_ui_request"; method: "select" | "confirm" | "input"; ... }
  | { type: "hook_ui_response"; requestId: string; ... };
```

### State Observability

The `get_state` command returns complete agent state:

```typescript
interface RpcSessionState {
  model: string;
  thinkingLevel: ThinkingLevel;
  isStreaming: boolean;
  isCompacting: boolean;
  queueMode: "all" | "one-at-a-time";
  sessionFile: string;
  sessionId: string;
  autoCompactionEnabled: boolean;
  messageCount: number;
  tokenUsage: { input: number; output: number };
  cost: number;
}
```

### Proposed Dual-Interface Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                           Backend Server                             │
│  (Node.js/Bun - spawns agent processes, manages sessions)           │
├─────────────────────────────────────────────────────────────────────┤
│  ┌───────────────────┐  ┌───────────────────┐  ┌─────────────────┐ │
│  │  Agent Process 1  │  │  Agent Process 2  │  │  Agent Process N│ │
│  │  (RPC mode)       │  │  (RPC mode)       │  │  (RPC mode)     │ │
│  └───────────────────┘  └───────────────────┘  └─────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
         ▲                         ▲                      ▲
         │ WebSocket               │ WebSocket            │ WebSocket
         │                         │                      │
┌────────┴────────┐      ┌────────┴────────┐    ┌───────┴────────┐
│  Chat Client 1  │      │  Chat Client 2  │    │  TUI Client    │
│  (iOS PWA)      │      │  (Web app)      │    │  (Terminal)    │
└─────────────────┘      └─────────────────┘    └────────────────┘
```

### Chat Interface Design Considerations

For non-technical users, the chat interface should:

1. **Hide complexity, expose capability**
   - No model selection (use sensible defaults)
   - No thinking level controls (auto-select based on task)
   - Show file changes as diffs in collapsible panels

2. **Progressive disclosure**
   - Basic chat for simple tasks
   - "Advanced" toggle for model switching, context files
   - Developer mode for full terminal access

3. **Visual feedback**
   - Animated indicators for tool execution
   - File tree visualization for context
   - Cost/token counters (optional, for transparency)

4. **Mobile-first interactions**
   - Voice input for prompts
   - Swipe to branch conversations
   - Long-press for message actions

---

## 8. Implementation Recommendations

### Phase 1: Claude-Only Foundation

Since you want to start with Claude only, simplify the architecture:

```typescript
// Simplified provider (no multi-provider abstraction needed)
interface ClaudeProvider {
  stream(context: Context, options: StreamOptions): AsyncIterable<StreamEvent>;
  complete(context: Context, options: StreamOptions): Promise<AssistantMessage>;
}

// Auth options
type ClaudeAuth =
  | { type: "api_key"; key: string }
  | { type: "oauth"; accessToken: string; refreshToken: string; expiresAt: number };
```

### Phase 2: Core Agent Loop

Implement the minimal agent loop:

```typescript
async function* agentLoop(
  provider: ClaudeProvider,
  tools: Tool[],
  messages: Message[],
  signal: AbortSignal
): AsyncGenerator<AgentEvent> {
  yield { type: "agent_start" };

  while (!signal.aborted) {
    // Stream response
    yield { type: "turn_start" };
    let response: AssistantMessage;

    for await (const event of provider.stream({ messages, tools })) {
      yield { type: "message_update", event };
      if (event.type === "done") response = event.message;
    }
    yield { type: "turn_end" };

    // Check for tool calls
    const toolCalls = response.content.filter(c => c.type === "tool_use");
    if (toolCalls.length === 0) break;

    // Execute tools
    for (const call of toolCalls) {
      yield { type: "tool_start", call };
      const result = await executeTool(call, tools, signal);
      yield { type: "tool_end", call, result };
      messages.push({ role: "toolResult", toolCallId: call.id, content: result });
    }

    messages.push(response);
  }

  yield { type: "agent_end" };
}
```

### Phase 3: Dual-Interface Protocol

Design a WebSocket protocol that maps to RPC:

```typescript
// Client → Server
interface WsCommand {
  id: string;
  sessionId: string;
  command: RpcCommand;
}

// Server → Client
interface WsMessage {
  type: "response" | "event";
  id?: string;
  sessionId: string;
  payload: RpcResponse | AgentEvent;
}
```

### Phase 4: Chat Interface

Build on top of the WebSocket protocol:

```typescript
// React/SolidJS component example
function ChatInterface({ sessionId }: Props) {
  const [messages, setMessages] = useState<Message[]>([]);
  const [isStreaming, setIsStreaming] = useState(false);
  const ws = useWebSocket(`ws://server/sessions/${sessionId}`);

  useEffect(() => {
    ws.onMessage((msg) => {
      if (msg.type === "event") {
        switch (msg.payload.type) {
          case "message_update":
            // Update streaming message
            break;
          case "tool_start":
            // Show tool execution indicator
            break;
        }
      }
    });
  }, [ws]);

  const sendPrompt = (text: string) => {
    ws.send({ type: "prompt", text });
  };

  return (
    <div>
      <MessageList messages={messages} isStreaming={isStreaming} />
      <PromptInput onSubmit={sendPrompt} />
    </div>
  );
}
```

### Key Files to Create

```
your-agent/
├── packages/
│   ├── core/
│   │   ├── src/
│   │   │   ├── claude-provider.ts    # Anthropic API wrapper
│   │   │   ├── oauth.ts              # Claude Max auth
│   │   │   ├── agent-loop.ts         # Core loop
│   │   │   ├── tools/                # read, write, edit, bash
│   │   │   ├── types.ts              # Shared types
│   │   │   └── index.ts
│   │   └── package.json
│   ├── server/
│   │   ├── src/
│   │   │   ├── session-manager.ts    # Multi-session orchestration
│   │   │   ├── ws-handler.ts         # WebSocket protocol
│   │   │   ├── rpc-bridge.ts         # Command routing
│   │   │   └── index.ts
│   │   └── package.json
│   ├── tui/
│   │   ├── src/
│   │   │   ├── components/           # Terminal UI components
│   │   │   ├── terminal.ts           # Rendering engine
│   │   │   └── index.ts
│   │   └── package.json
│   └── chat/
│       ├── src/
│       │   ├── components/           # Chat UI components
│       │   ├── hooks/                # WebSocket hooks
│       │   └── App.tsx
│       └── package.json
└── package.json                       # Workspace root
```

---

## 9. Comparison with Clauset

### Current Clauset Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Mac Mini Server                              │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │                     Claude Code CLI                              ││
│  │  (External process - no control over internals)                 ││
│  └─────────────────────────────────────────────────────────────────┘│
│         ▲                                                           │
│         │ Terminal I/O (stdin/stdout piping)                        │
│         ▼                                                           │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │                     Rust Backend (Axum)                          ││
│  │  • portable-pty for terminal control                            ││
│  │  • SQLite for session persistence                               ││
│  │  • WebSocket for real-time updates                              ││
│  └─────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────┘
         ▲
         │ Tailscale (private network)
         │
┌────────┴────────┐
│  iPhone PWA     │
│  (SolidJS)      │
└─────────────────┘
```

### Limitations of Clauset Approach

1. **No state access**: Can't query agent state, only observe terminal output
2. **Parsing fragility**: Terminal output parsing is error-prone
3. **No event granularity**: Can't distinguish tool execution from text generation
4. **No programmatic control**: Can't abort, branch, or switch sessions cleanly

### Proposed Architecture (Your Own Implementation)

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Server (Node.js/Bun)                         │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │                     Your Agent Core                              ││
│  │  • Full state observability                                     ││
│  │  • Event streaming (JSON)                                       ││
│  │  • Tool execution hooks                                         ││
│  │  • Session branching/persistence                                ││
│  └─────────────────────────────────────────────────────────────────┘│
│         ▲                                    ▲                      │
│         │ RPC/Events                         │ Native API           │
│         ▼                                    ▼                      │
│  ┌───────────────────┐             ┌───────────────────┐           │
│  │   Chat Handler    │             │    TUI Handler    │           │
│  │   (WebSocket)     │             │    (Terminal)     │           │
│  └───────────────────┘             └───────────────────┘           │
└─────────────────────────────────────────────────────────────────────┘
         ▲                                    ▲
         │                                    │
┌────────┴────────┐             ┌────────────┴────────────┐
│  Chat Clients   │             │  Terminal Clients       │
│  (PWA/Web/iOS)  │             │  (SSH/Local)            │
└─────────────────┘             └─────────────────────────┘
```

### Key Advantages

| Aspect | Clauset | Your Implementation |
|--------|---------|---------------------|
| State access | Parse terminal output | Direct state query |
| Event granularity | None | Per-event streaming |
| Tool visibility | Guess from output | Explicit tool events |
| Session control | Limited | Full (branch, switch, abort) |
| Multi-interface | Hacky | Native support |
| Cost tracking | None | Built-in |
| Context control | None | Full (compaction, context files) |

---

## Appendix: Code Samples & Schemas

### A. Anthropic Streaming with Extended Thinking

```typescript
import Anthropic from "@anthropic-ai/sdk";

async function* streamWithThinking(
  client: Anthropic,
  messages: Anthropic.Messages.MessageParam[],
  tools: Anthropic.Messages.Tool[]
) {
  const stream = client.messages.stream({
    model: "claude-sonnet-4-20250514",
    max_tokens: 8192,
    messages,
    tools,
    thinking: {
      type: "enabled",
      budget_tokens: 4096,
    },
  });

  for await (const event of stream) {
    switch (event.type) {
      case "content_block_start":
        if (event.content_block.type === "thinking") {
          yield { type: "thinking_start" };
        } else if (event.content_block.type === "text") {
          yield { type: "text_start" };
        } else if (event.content_block.type === "tool_use") {
          yield { type: "tool_start", name: event.content_block.name };
        }
        break;
      case "content_block_delta":
        if (event.delta.type === "thinking_delta") {
          yield { type: "thinking_delta", delta: event.delta.thinking };
        } else if (event.delta.type === "text_delta") {
          yield { type: "text_delta", delta: event.delta.text };
        } else if (event.delta.type === "input_json_delta") {
          yield { type: "tool_delta", delta: event.delta.partial_json };
        }
        break;
      case "message_stop":
        yield { type: "done", message: stream.finalMessage() };
        break;
    }
  }
}
```

### B. Tool Definition with TypeBox

```typescript
import { Type, type Static } from "@sinclair/typebox";
import { Value } from "@sinclair/typebox/value";

const ReadToolSchema = Type.Object({
  path: Type.String({ description: "File path to read" }),
  offset: Type.Optional(Type.Number({ description: "Starting line (1-indexed)" })),
  limit: Type.Optional(Type.Number({ description: "Max lines to return" })),
});

type ReadToolParams = Static<typeof ReadToolSchema>;

const readTool: AgentTool<ReadToolParams> = {
  name: "read",
  description: "Read contents of a text file or image",
  parameters: ReadToolSchema,
  label: "Read File",

  async execute(toolCallId, params, signal, onUpdate) {
    // Validate params
    if (!Value.Check(ReadToolSchema, params)) {
      return { content: [{ type: "text", text: "Invalid parameters" }], isError: true };
    }

    const { path, offset = 1, limit } = params;
    const absolutePath = resolvePath(path);

    // Check abort
    if (signal.aborted) {
      return { content: [{ type: "text", text: "Aborted" }], isError: true };
    }

    // Read file
    const content = await fs.readFile(absolutePath, "utf-8");
    const lines = content.split("\n");
    const slice = lines.slice(offset - 1, limit ? offset - 1 + limit : undefined);

    return {
      content: [{ type: "text", text: slice.join("\n") }],
      details: { totalLines: lines.length, returnedLines: slice.length },
    };
  },
};
```

### C. Session Persistence (JSONL Format)

```jsonl
{"type":"user","content":"What files are in this directory?","timestamp":1735689600000}
{"type":"assistant","content":[{"type":"tool_use","id":"call_1","name":"bash","input":{"command":"ls -la"}}],"usage":{"input":150,"output":45}}
{"type":"toolResult","toolCallId":"call_1","content":"total 24\ndrwxr-xr-x  5 user  staff  160 Dec 31 10:00 .\n..."}
{"type":"assistant","content":[{"type":"text","text":"The directory contains 5 items..."}],"usage":{"input":250,"output":120}}
{"type":"bashExecution","command":"ls -la","output":"total 24\n...","exitCode":0,"cancelled":false,"truncated":false}
```

### D. RPC Command Examples

```bash
# Start agent in RPC mode
pi --mode rpc --no-session

# Send prompt
echo '{"type":"prompt","text":"List files in current directory"}' | nc localhost 3000

# Get state
echo '{"type":"get_state"}' | nc localhost 3000

# Response
{"type":"response","command":"get_state","success":true,"data":{"model":"claude-sonnet-4-20250514","isStreaming":false,"messageCount":4}}

# Switch model
echo '{"type":"set_model","modelId":"claude-opus-4-20250514"}' | nc localhost 3000

# Abort current operation
echo '{"type":"abort"}' | nc localhost 3000
```

---

## Conclusions

### Key Takeaways

1. **Pi's architecture is already dual-interface ready** through its RPC mode and event streaming
2. **Claude Max OAuth** is well-documented and straightforward to implement
3. **Minimal toolset** (read, write, edit, bash) is genuinely sufficient for coding tasks
4. **State observability** is the key to supporting multiple interfaces
5. **Session persistence as JSONL** enables easy inspection and branching

### Recommended Approach

1. **Fork pi-mono** as a starting point (Mario explicitly encourages this)
2. **Strip to Claude-only** to simplify initial implementation
3. **Implement OAuth early** to use Max subscription from the start
4. **Build dual interface from day one** rather than retrofitting
5. **Invest in state observability** - every operation should emit events

### Next Steps

1. Set up monorepo structure
2. Implement Claude provider with OAuth
3. Port minimal agent loop from pi-agent
4. Implement four core tools
5. Build RPC server
6. Build chat client
7. Build terminal client (optional, use pi's TUI as reference)

---

## References

- [pi-mono GitHub Repository](https://github.com/badlogic/pi-mono)
- [Mario Zechner's Blog Post on Building pi](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/)
- [Anthropic API Documentation](https://docs.anthropic.com/)
- [TypeBox Schema Library](https://github.com/sinclairzx81/typebox)
- [Clauset Project](https://github.com/mhismail3/clauset)
