---
paths:
  - "**/context/**"
  - "**/compaction*"
  - "**/system-prompt*"
  - "**/token-estimator*"
---

# Context Management

Token estimation, context limits, compaction, and system prompt construction.

## Key Components

| File | Purpose |
|------|---------|
| `context-manager.ts` | Central manager, pre-turn validation |
| `compaction-engine.ts` | Compaction orchestration |
| `token-estimator.ts` | Token estimation (char/4 heuristic) |
| `system-prompts.ts` | System prompt construction |
| `loader.ts` | AGENTS.md/CLAUDE.md hierarchy loading |

## Context Loading Hierarchy

1. Global: `~/.tron/rules/AGENTS.md`
2. Project: `.claude/AGENTS.md` or `.tron/AGENTS.md`
3. Subdirectory: `subdir/AGENTS.md` files (path-scoped)

## Compaction Flow

1. Check threshold (default 70% of context limit)
2. Preserve recent turns (default 3)
3. Summarize older turns via LLM
4. Replace original messages with summary

## Rules

- Token estimation uses char/4 heuristic; API reports ground truth post-turn
- Context limit varies by model - use `getContextLimit(model)`
- Compaction is triggered before turn execution, not during
- Rules content is cached; hierarchy changes require restart

---

## Update Triggers

Update this rule when:
- Changing context loading hierarchy
- Modifying compaction thresholds or logic
- Adding new system prompt sections

Verification:
```bash
grep -l "ContextManager" packages/agent/src/context/context-manager.ts
grep -l "compaction" packages/agent/src/context/compaction-engine.ts
```
