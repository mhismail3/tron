---
paths:
  - "**/subagent/**"
  - "**/spawn*agent*"
  - "**/tmux*"
---

# Sub-Agents

Spawning and tracking child agent sessions.

## Spawn Types

| Type | File | Use Case |
|------|------|----------|
| In-process | `spawn-subagent.ts` | Quick tasks, shared memory |
| Tmux | `spawn-tmux-agent.ts` | Long-running, isolated |

## SubagentTracker

Manages sub-agent lifecycle (`subagent-tracker.ts`):
- Tracks spawning → running → completed/failed status
- Stores task, model, tokenUsage per sub-agent
- Provides waiting mechanism for parent

## Key Types

```typescript
type SubagentStatus = 'spawning' | 'running' | 'paused'
                    | 'waiting_input' | 'completed' | 'failed';

interface SubagentResult {
  sessionId, success, output, summary,
  task, totalTurns, tokenUsage, duration
}
```

## Communication Pattern

1. Parent spawns sub-agent with task
2. SubagentTracker records in parent's event log
3. Sub-agent runs independently
4. On completion, result recorded and parent notified
5. Parent can query status or wait for result

## Rules

- Sub-agent events recorded in both parent and child sessions
- Tmux spawns require terminal environment
- In-process shares event store connection
- Maximum turns configurable per spawn

---

## Update Triggers

Update this rule when:
- Adding spawn types
- Changing tracker status flow
- Modifying result injection

Verification:
```bash
grep -l "SubagentTracker" packages/agent/src/tools/subagent/subagent-tracker.ts
grep -l "spawnSubagent\|spawnTmux" packages/agent/src/tools/subagent/
```
