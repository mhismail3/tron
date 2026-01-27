# Agent API

## WebSocket Protocol

Connect to the agent server via WebSocket for bidirectional communication.

### Connection

```
ws://localhost:8080  (production)
ws://localhost:8082  (development)
```

### Message Format

All messages use JSON-RPC 2.0:

```typescript
// Request
{
  jsonrpc: "2.0",
  id: string,
  method: string,
  params: Record<string, unknown>
}

// Response
{
  jsonrpc: "2.0",
  id: string,
  result?: unknown,
  error?: { code: number, message: string }
}

// Notification (server → client)
{
  jsonrpc: "2.0",
  method: string,
  params: Record<string, unknown>
}
```

## RPC Methods

### Session Management

| Method | Params | Returns |
|--------|--------|---------|
| `session.create` | `{ workingDirectory, model }` | `{ sessionId }` |
| `session.list` | `{ workspaceId?, limit? }` | `{ sessions: Session[] }` |
| `session.get` | `{ sessionId }` | `{ session: Session }` |
| `session.fork` | `{ sessionId, eventId? }` | `{ newSessionId }` |
| `session.delete` | `{ sessionId }` | `{ success: boolean }` |

### Agent Control

| Method | Params | Returns |
|--------|--------|---------|
| `agent.message` | `{ sessionId, content, attachments? }` | Stream of events |
| `agent.abort` | `{ sessionId }` | `{ aborted: boolean }` |
| `agent.respond` | `{ sessionId, response }` | Stream of events |

### Model

| Method | Params | Returns |
|--------|--------|---------|
| `model.list` | `{}` | `{ models: ModelInfo[] }` |
| `model.switch` | `{ sessionId, model }` | `{ success: boolean }` |

### Context

| Method | Params | Returns |
|--------|--------|---------|
| `context.get` | `{ sessionId }` | `{ context: ContextSnapshot }` |
| `context.compact` | `{ sessionId }` | `{ compacted: boolean }` |

### Events

| Method | Params | Returns |
|--------|--------|---------|
| `events.list` | `{ sessionId, limit?, after? }` | `{ events: Event[] }` |
| `events.sync` | `{ sessionId, lastSequence }` | `{ events: Event[] }` |

## Event Notifications

Server sends notifications for real-time updates:

### Streaming Events

```typescript
// Text streaming
{ method: "agent.text_delta", params: { sessionId, delta: string } }

// Tool start
{ method: "agent.tool_start", params: { sessionId, toolName, toolId } }

// Tool end
{ method: "agent.tool_end", params: { sessionId, toolId, result } }

// Turn complete
{ method: "agent.turn_complete", params: { sessionId, tokenUsage } }
```

### Session Events

```typescript
// Session status change
{ method: "session.status", params: { sessionId, status } }

// Sub-agent spawned
{ method: "subagent.spawn", params: { parentSessionId, subagentSessionId, task } }

// Sub-agent completed
{ method: "subagent.complete", params: { subagentSessionId, result } }
```

## Event Types Reference

### Core Events

| Type | Description | Key Payload Fields |
|------|-------------|-------------------|
| `session.start` | Session created | workingDirectory, model, provider |
| `session.end` | Session ended | reason, summary |
| `session.fork` | Session forked | sourceSessionId, sourceEventId |

### Message Events

| Type | Description | Key Payload Fields |
|------|-------------|-------------------|
| `message.user` | User message | content, turn |
| `message.assistant` | Assistant message | content, tokenUsage |

### Tool Events

| Type | Description | Key Payload Fields |
|------|-------------|-------------------|
| `tool.call` | Tool invoked | name, arguments, toolId |
| `tool.result` | Tool completed | content, isError, duration |

### Sub-agent Events

| Type | Description | Key Payload Fields |
|------|-------------|-------------------|
| `subagent.spawn` | Sub-agent created | sessionId, task, model |
| `subagent.progress` | Sub-agent update | sessionId, turn, status |
| `subagent.complete` | Sub-agent finished | sessionId, result, tokenUsage |

### Context Events

| Type | Description | Key Payload Fields |
|------|-------------|-------------------|
| `context.compaction` | Context compacted | turnsBefore, turnsAfter, tokensSaved |

## Health Endpoint

```
GET http://localhost:8081/health  (production)
GET http://localhost:8083/health  (development)

Response: { status: "ok", version: "1.0.0" }
```

## Authentication

Currently uses local-only connections. Future versions will support API keys.

## Error Codes

| Code | Meaning |
|------|---------|
| -32700 | Parse error |
| -32600 | Invalid request |
| -32601 | Method not found |
| -32602 | Invalid params |
| -32603 | Internal error |
| -32000 | Session not found |
| -32001 | Agent busy |
| -32002 | Context overflow |
