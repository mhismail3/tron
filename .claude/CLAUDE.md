# Tron Project Guidelines

**Documentation:** Each package has its own `docs/` folder:
- Agent: `packages/agent/docs/`
- iOS: `packages/ios-app/docs/`

**Path-scoped rules** load automatically when editing matching files:
- Agent: `packages/agent/.claude/rules/`
- iOS: `packages/ios-app/.claude/rules/`

## CRITICAL RULES - ALWAYS FOLLOW

### Root Cause Analysis
**NEVER apply bandaid fixes.** When you find a bug, ALWAYS:
1. Analyze the code and trace call paths to identify the TRUE root cause
2. Understand WHY the bug exists, not just WHERE it manifests
3. Fix the underlying issue robustly, even if it requires more effort

### Debugging with Database Logs
**Source of truth for all agent sessions is `$HOME/.tron/db/`**. The databases contain:
- `events` table: All session events (messages, tool calls, results)
- `logs` table: All application logs with timestamps and context

**ALWAYS use the `@tron-db` skill** (`.claude/skills/tron-db/`) when the user asks to investigate an issue. Query the database directly — do not guess.

### Build & Test Verification
**ALWAYS run before completing any task:**
```bash
bun run build && bun run test
```
Do not mark work as complete until both succeed. If tests fail, fix them.

### Test-Driven Development
**Prioritize zero regressions.** When making changes:
1. Write or update tests FIRST when adding features
2. Run existing tests BEFORE and AFTER changes
3. If refactoring, ensure test coverage exists before touching code
4. Never commit code that introduces test failures

### Documentation Self-Maintenance
**After ANY architectural change, update relevant documentation.**

Path-scoped rules load automatically when you edit matching files. When you see a rule:
1. Check if your changes affect the rule's accuracy
2. If yes, update the rule in the SAME commit as your code change
3. Run the rule's verification command to confirm accuracy

Each rule file has an "Update Triggers" section listing when to update it.
