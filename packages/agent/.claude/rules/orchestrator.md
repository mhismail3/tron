---
paths:
  - "**/orchestrator/**"
  - "**/session-manager*"
  - "**/turn-*"
  - "**/agent-runner*"
---

# Orchestrator

Session lifecycle management, turn execution, and event persistence.

## Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| AgentRunner | `agent-runner.ts` | Turn execution loop |
| AgentFactory | `agent-factory.ts` | Agent instance creation |
| Session ops | `operations/` | CRUD operations |
| Persistence | `persistence/` | Event linearization |
| Turn handling | `turn/` | Turn state machine |

## Session Lifecycle

```
create → run → (fork | resume | end)
         ↓
      turn loop:
        1. Pre-validate context
        2. Call LLM
        3. Process response
        4. Execute tools
        5. Record events
        6. Check for completion
```

## Event Persistence

`EventPersister` linearizes tree events for efficient queries:
- Maintains sequence numbers within session
- Handles parent/child relationships
- Supports fork point detection

## Handlers

| Handler | Purpose |
|---------|---------|
| `agent-event-handler.ts` | Records events during turn |
| `ui-render-handler.ts` | Streams UI updates |

## Rules

- Sessions are immutable except for headEventId advancement
- Fork creates new session with root pointing to branch point
- Resume reconstructs state from events, continues turn loop
- Always persist events before acknowledging completion

---

## Update Triggers

Update this rule when:
- Changing session lifecycle operations
- Modifying turn execution flow
- Adding new handler types

Verification:
```bash
grep -l "AgentRunner" packages/agent/src/orchestrator/agent-runner.ts
ls packages/agent/src/orchestrator/operations/
```
