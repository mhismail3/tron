# Tron Refactoring Implementation Plan

**Date**: 2026-01-01
**Approach**: Test-Driven Development (TDD)

---

## Overview

This plan outlines a comprehensive refactoring of Tron to focus on solid foundations before innovation. The goal is to create a robust, maintainable agent harness that can be extended later.

### Principles
1. **TDD First**: Write tests before implementation
2. **Separation of Concerns**: Each module has one responsibility
3. **Debug-Friendly**: Enable breakpoints and logging throughout
4. **No Regressions**: All existing tests must pass

---

## Phase 1: REMOVE - Simplify Memory System

### Current State
- `memory/types.ts` - Complex 4-level memory hierarchy
- `memory/sqlite-store.ts` - SQLite-based persistence
- `memory/ledger-manager.ts` - Session continuity tracking
- `memory/handoff-manager.ts` - FTS5-based session handoffs

### Target State
Replace with simplified file-based system:
- **Session files**: Timestamped JSONL in `~/.tron/sessions/`
- **Plan files**: Markdown in `.tron/plans/`
- **Todo files**: Markdown in `.tron/todos/`
- **Handoffs**: Pre-compaction markdown in `.tron/handoffs/`
- **CONTINUITY.md**: Single workspace ledger

### Files to Remove
```
packages/core/src/memory/types.ts (keep simplified version)
packages/core/src/memory/sqlite-store.ts (DELETE)
packages/core/src/memory/ledger-manager.ts (SIMPLIFY to file-based)
packages/core/src/memory/handoff-manager.ts (SIMPLIFY to markdown)
packages/core/test/memory/sqlite-store.test.ts (DELETE)
packages/core/test/memory/memory-types.test.ts (UPDATE)
packages/core/test/memory/ledger-manager.test.ts (UPDATE)
packages/core/test/memory/handoff-manager.test.ts (UPDATE)
```

### Files to Update (Dependencies)
```
packages/core/src/hooks/builtin/session-start.ts
packages/core/src/hooks/builtin/session-end.ts
packages/core/src/hooks/builtin/post-tool-use.ts
packages/core/src/hooks/builtin/pre-compact.ts
packages/core/src/context/audit.ts
packages/core/test/e2e/full-workflow.test.ts
packages/core/test/hooks/builtin/*.test.ts
```

### New Simplified Types
```typescript
// memory/types.ts (simplified)
export interface ContinuityLedger {
  now: string;
  done: string[];
  next: string[];
  decisions: Array<{ choice: string; reason: string }>;
  workingFiles: string[];
  lastUpdated: string;
}

export interface SimpleHandoff {
  id: string;
  timestamp: string;
  summary: string;
  codeChanges: string[];
  nextSteps: string[];
}
```

---

## Phase 2: REMOVE - Inbox & Notes

### Files to Remove
```
packages/core/src/productivity/inbox/ (entire directory)
packages/core/src/productivity/notes.ts
packages/core/src/productivity/index.ts (update exports)
```

### Keep
```
packages/core/src/productivity/export.ts (transcript export)
packages/core/src/productivity/tasks.ts (task tracking)
```

---

## Phase 3: REMOVE - Skills System

### Files to Remove
```
packages/core/src/skills/ (entire directory)
packages/core/test/skills/ (entire directory)
packages/core/src/index.ts (remove skills export)
```

### Update Command Router
The command router imports from skills - update to remove skill integration:
```
packages/core/src/commands/router.ts
packages/core/src/commands/types.ts
packages/core/test/commands/router.test.ts
```

---

## Phase 4: REMOVE - Evaluation Framework

### Files to Remove
```
packages/core/src/eval/ (entire directory)
packages/core/test/eval/ (entire directory)
packages/core/src/index.ts (remove eval export)
```

---

## Phase 5: REMOVE - Emojis & Goal Line

### Search & Replace
- Remove all emoji characters from log output
- Remove "Goal:" line from initialization welcome message
- Update: `packages/tui/src/app.tsx` - remove goal display

### Files to Check
```
packages/core/src/logging/logger.ts
packages/tui/src/app.tsx
packages/tui/src/components/*.tsx
packages/server/src/*.ts
```

---

## Phase 6: ADD - grep/find/ls Tools

### New Files
```
packages/core/src/tools/grep.ts
packages/core/src/tools/find.ts
packages/core/src/tools/ls.ts
packages/core/test/tools/grep.test.ts
packages/core/test/tools/find.test.ts
packages/core/test/tools/ls.test.ts
packages/core/src/tools/index.ts (update)
```

### Tool Specifications

#### GrepTool
```typescript
interface GrepToolParams {
  pattern: string;       // regex pattern
  path: string;         // file or directory
  recursive?: boolean;  // -r flag, default true for dirs
  ignore_case?: boolean; // -i flag
  context_lines?: number; // -C flag
  max_results?: number;  // limit results
}
```

#### FindTool
```typescript
interface FindToolParams {
  path: string;          // starting directory
  name?: string;         // filename pattern (glob)
  type?: 'f' | 'd';      // file or directory
  max_depth?: number;    // limit depth
  exclude?: string[];    // patterns to exclude
}
```

#### LsTool
```typescript
interface LsToolParams {
  path: string;          // directory to list
  all?: boolean;         // show hidden files
  long?: boolean;        // detailed format
  recursive?: boolean;   // recurse into subdirs
}
```

---

## Phase 7: ADD - TUI Enhancements

### 7.1 Differential Rendering
Create a VirtualScreen buffer that tracks changes:
```
packages/tui/src/rendering/virtual-screen.ts
packages/tui/src/rendering/diff-renderer.ts
packages/tui/test/rendering/virtual-screen.test.ts
```

### 7.2 Full TUI Components
```
packages/tui/src/components/MarkdownRenderer.tsx
packages/tui/src/components/CodeBlock.tsx
packages/tui/src/components/DiffView.tsx
packages/tui/src/components/ProgressBar.tsx
packages/tui/src/components/ContextIndicator.tsx
packages/tui/src/components/Banner.tsx
```

### 7.3 Markdown Rendering
Use `marked` or similar to parse markdown and render with chalk colors.

### 7.4 Context Percentage Indicator
Show: `[Context: 45% | 45k/100k tokens]`

### 7.5 Bracketed Paste Mode
Handle `\e[200~` ... `\e[201~` sequences for proper paste.

---

## Phase 8: ADD - Input Improvements

### 8.1 Prompt History (Up/Down Arrows)
```typescript
// Store in packages/tui/src/state/prompt-history.ts
class PromptHistory {
  private history: string[] = [];
  private currentIndex: number = -1;

  add(prompt: string): void;
  up(): string | null;
  down(): string | null;
  save(): Promise<void>;  // persist to ~/.tron/prompt-history.json
  load(): Promise<void>;
}
```

### 8.2 Multiline Input Support
- Shift+Enter for newline
- Proper handling of pasted multiline content
- Visual indicator for multiline mode

### 8.3 Keystroke Handling
Ensure Ctrl+L doesn't leak into input:
```typescript
// Capture before input handling
if (key.ctrl && input === 'l') {
  // Clear screen, don't add to input
  return;
}
```

### 8.4 Session Banner Positioning
On new session, clear screen and position banner at top.

---

## Phase 9: ADD - Session Enhancements

### 9.1 Escape to Pause
```typescript
// On Escape during execution:
// 1. Set agent.pause() flag
// 2. Show prompt: "Paused. [c]ontinue, [a]bort, or enter message:"
// 3. Preserve full context
```

### 9.2 Interrupt Persistence
```typescript
// On SIGINT (Ctrl+C):
// 1. Catch signal
// 2. Write current messages to session file
// 3. Create handoff
// 4. Then exit
process.on('SIGINT', async () => {
  await session.emergencySave();
  await session.createHandoff('interrupted');
  process.exit(0);
});
```

### 9.3 Ephemeral Sessions
```typescript
interface SessionOptions {
  ephemeral?: boolean;  // --no-session flag
}
// If ephemeral, don't persist to disk
```

### 9.4 Git Worktree Slash Command
```
/worktree create <name>  - Create worktree and switch
/worktree list           - List worktrees
/worktree switch <name>  - Switch to worktree
```

---

## Phase 10: ADD - Compaction/Handoff

### Token-Aware Compaction
```typescript
interface CompactionConfig {
  retainTokens: 25000;      // Keep last 25k tokens
  summarizeRemainder: true;  // Summarize older messages
}

async function compact(messages: Message[]): Promise<Message[]> {
  // 1. Count tokens from end
  // 2. Find cutoff point at 25k tokens
  // 3. Summarize messages before cutoff
  // 4. Create handoff with summary
  // 5. Return [summary_message, ...recent_messages]
}
```

### Manual Compact Command
```
/compact  - Trigger manual compaction
```

---

## Phase 11: ADD - Additional Features

### 11.1 Clipboard Integration
```typescript
// packages/core/src/utils/clipboard.ts
import { exec } from 'child_process';

export async function copyToClipboard(text: string): Promise<void> {
  const cmd = process.platform === 'darwin' ? 'pbcopy' : 'xclip -selection clipboard';
  // ...
}
```

### 11.2 File Path Auto-completion
```typescript
// On "@" prefix, show file picker
// Fuzzy search with fzf-like algorithm
interface FileCompletion {
  trigger: '@';
  search(query: string): Promise<string[]>;
  complete(path: string): void;
}
```

### 11.3 Message Queuing During Streaming
```typescript
// If user types during streaming, queue message
class MessageQueue {
  private queue: string[] = [];
  add(message: string): void;
  hasMessages(): boolean;
  pop(): string | undefined;
}
```

### 11.4 Image Support
- Paste detection (iTerm2/Kitty protocols)
- Base64 encoding for API
- Drag-drop via file path

### 11.5 PDF Support
- Use `pdf-parse` library
- Extract text for context
- Show page count in tool result

### 11.6 Model Thinking Levels
```
/thinking off    - No extended thinking
/thinking low    - 1024 token budget
/thinking medium - 8192 token budget
/thinking high   - 32768 token budget
```

---

## Phase 12: Refactoring & Cleanup

### Module Organization
```
packages/core/src/
├── agent/          # Core agent loop
├── auth/           # OAuth, API keys
├── commands/       # Slash commands (simplified)
├── context/        # Context loading
├── hooks/          # Hook system
├── logging/        # Pino-based logging
├── providers/      # LLM providers
├── rpc/            # JSON-RPC protocol
├── session/        # Session management
├── storage/        # NEW: File-based storage
├── tools/          # Tool implementations
├── types/          # Shared types
└── utils/          # Utilities (clipboard, etc.)
```

### Debug Mode
```typescript
// Enable via DEBUG=tron:* environment variable
// Or --debug flag

// Ensure all critical points have debug logs:
logger.debug('agent.turn.start', { turn: this.currentTurn });
logger.debug('tool.execute', { name, args });
logger.debug('hook.run', { type, action });
```

### Source Maps
Ensure tsconfig has:
```json
{
  "compilerOptions": {
    "sourceMap": true,
    "inlineSources": true
  }
}
```

---

## Test Organization

Each phase should include:
1. **Unit tests** for new/modified code
2. **Integration tests** for module interactions
3. **E2E tests** for user workflows

### Test Commands
```bash
# Run all tests
npm test

# Run specific test file
npx vitest run packages/core/test/tools/grep.test.ts

# Run with coverage
npm run test:coverage

# Watch mode
npm run test:watch
```

---

## Implementation Order

1. **Phase 5** (Remove emojis/goal) - Quick win, no dependencies
2. **Phase 4** (Remove eval) - Self-contained removal
3. **Phase 3** (Remove skills) - Update command router
4. **Phase 2** (Remove inbox/notes) - Update productivity exports
5. **Phase 1** (Simplify memory) - Most complex, do after others
6. **Phase 6** (Add tools) - New feature, independent
7. **Phase 8** (Input improvements) - TUI enhancement
8. **Phase 9** (Session enhancements) - Session improvements
9. **Phase 10** (Compaction) - Depends on simplified memory
10. **Phase 7** (TUI enhancements) - Larger effort
11. **Phase 11** (Additional features) - Various improvements
12. **Phase 12** (Refactoring) - Final cleanup

---

## Success Criteria

- [ ] All tests pass
- [ ] No TypeScript errors
- [ ] Debug mode works with breakpoints
- [ ] Logs are clean (no emojis, no excessive output)
- [ ] Session persistence works reliably
- [ ] Handoffs created on exit/interrupt
- [ ] New tools (grep/find/ls) functional
- [ ] TUI responsive and renders markdown
- [ ] Input history works
- [ ] Multiline input works
- [ ] Compaction preserves 25k tokens

---

*This plan will be updated as implementation progresses.*
