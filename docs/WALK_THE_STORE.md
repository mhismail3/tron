# TRON - Comprehensive Walk-the-Store Testing Document

## Executive Summary

Tron is a persistent, dual-interface coding agent with sophisticated memory architecture, comprehensive hook system, and multi-model support. This document provides exhaustive coverage of all testable features across all packages.

---

## 1. PACKAGE STRUCTURE & PURPOSES

### @tron/core
**Purpose**: Core agent logic, memory systems, hooks, tools, and provider integrations

**Key Modules**:
- `agent/` - TronAgent orchestration, message handling, event emission
- `providers/` - Anthropic (Claude), OpenAI (GPT), Google (Gemini) with streaming & tool calling
- `tools/` - File operations (read/write/edit), bash execution, search (grep/find/ls)
- `memory/` - Ledger (markdown-based), Handoff (SQLite+FTS5), MemoryStore
- `hooks/` - Event lifecycle system with discovery, registration, and execution
- `auth/` - OAuth PKCE flow and token management
- `context/` - Hierarchical AGENTS.md/CLAUDE.md loader with merging
- `session/` - Session persistence, fork/rewind operations
- `utils/` - Error handling, clipboard, file completion, media

### @tron/server
**Purpose**: WebSocket server for multi-session orchestration

**Key Components**:
- SessionOrchestrator: Multi-session management
- TronWebSocketServer: JSON-RPC protocol handler
- HealthServer: Liveness/readiness endpoints

### @tron/tui
**Purpose**: Terminal UI using React/Ink

**Key Components**:
- TuiSession: Unified session orchestration wrapper
- App.tsx: Main React component with state management
- SlashCommandMenu: Interactive command selector
- Components: Header, MessageList, InputArea, StatusBar, StreamingContent
- Auth: OAuth flow integration for terminal

### @tron/chat-web
**Purpose**: Web-based chat interface (React SPA)

---

## 2. TUI FEATURES & TESTING

### 2.1 Slash Commands

| Command | Shortcut | Function | How to Test |
|---------|----------|----------|-------------|
| `/help` | `h` | Show available commands | Type `/help` → verify list appears |
| `/model` | `m` | Show/switch model | Type `/model` → see current model |
| `/clear` | `c` | Clear message history | Type `/clear` → messages wiped |
| `/context` | - | View loaded context files | Type `/context` → see AGENTS.md hierarchy |
| `/session` | - | Show session info | Type `/session` → view ID, tokens |
| `/history` | - | View conversation history | Type `/history` → see message count |
| `/exit` | `q` | Exit the application | Type `/exit` → graceful shutdown |

**Test Scenarios**:
```bash
# Start TUI
npm run dev -w @tron/tui

# In the TUI:
/help                    # Should show command list
/session                 # Should show session ID and token counts
/model                   # Should show current model
/clear                   # Should clear messages
/context                 # Should show loaded context files
```

**Edge Cases to Test**:
- Unknown commands → should show "unknown command" error
- Partial command matching (`/mod` for `/model`)
- Empty command (just `/`)

### 2.2 SlashCommandMenu Component

**Features**:
- Real-time filtering as you type
- Arrow key navigation with scrolling
- Selected index highlighting
- Shows count of matches

**Test Steps**:
1. Type `/` to show menu
2. Type letters to filter (e.g., `/m` shows model)
3. Use ↑/↓ to navigate
4. Enter to select
5. Esc to cancel

### 2.3 Input History Navigation

**Features**:
- Up/Down arrows navigate history
- History preserved across prompts
- MAX_HISTORY = 100 entries

**Test Steps**:
1. Send first message
2. Send second message
3. Press Up arrow → should show second message
4. Press Up again → should show first message
5. Press Down → should return to second
6. Press Down again → should return to empty input

### 2.4 Streaming Content Display

**Test Steps**:
1. Send a prompt that generates long output
2. Verify text appears incrementally (streaming)
3. Verify spinner animates while thinking
4. Wait for completion → verify token count updates

### 2.5 Error Display

**Test Steps**:
1. Trigger an error (e.g., invalid command to API)
2. Verify error shows in red at bottom status bar
3. Send new prompt → error should clear

### 2.6 Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Enter | Send message |
| Ctrl+C | Abort/exit |
| Ctrl+L | Clear screen |
| Up/Down | History navigation |
| Esc | Cancel menu |

---

## 3. CLI COMMANDS

### 3.1 Authentication Commands

```bash
# OAuth login flow
npm run dev -w @tron/tui -- login

# Check auth status
npm run dev -w @tron/tui -- auth

# Logout
npm run dev -w @tron/tui -- logout
```

**Test Flow**:
1. Run `login` command
2. Copy displayed authorization URL
3. Open in browser, authorize
4. Copy code from browser
5. Paste code in CLI
6. Verify `~/.tron/auth.json` contains tokens

### 3.2 Main TUI Options

```bash
# Basic usage
npm run dev -w @tron/tui

# With options
npm run dev -w @tron/tui -- --model claude-sonnet-4-20250514
npm run dev -w @tron/tui -- --verbose
npm run dev -w @tron/tui -- --debug
npm run dev -w @tron/tui -- --ephemeral    # No persistence
npm run dev -w @tron/tui -- /path/to/project
```

---

## 4. AGENT CAPABILITIES

### 4.1 Available Tools

| Tool | Purpose | Test Command |
|------|---------|--------------|
| **Read** | Read files | "Read the file package.json" |
| **Write** | Create/overwrite files | "Create a file called test.txt with hello world" |
| **Edit** | In-place text replacement | "Change 'foo' to 'bar' in test.txt" |
| **Bash** | Execute shell commands | "Run ls -la" |
| **Grep** | Search file contents | "Search for 'TODO' in all TypeScript files" |
| **Find** | Find files by pattern | "Find all .ts files" |
| **Ls** | List directory contents | "List files in src/" |

**Test Each Tool**:
```
# In TUI, send these prompts:

"Read the README.md file"
→ Should show file contents with line numbers

"Create a file called test-output.txt containing 'Hello from Tron'"
→ Should create file

"Run the command: echo 'test'"
→ Should execute and show output

"Search for 'export' in all TypeScript files in packages/core/src"
→ Should show matching lines

"Find all test files (*.test.ts)"
→ Should list test files
```

### 4.2 Dangerous Command Blocking

The Bash tool blocks dangerous patterns:
- `rm -rf /`
- `sudo` commands
- `chmod 777 /`
- `mkfs.*`
- Fork bombs

**Test**:
```
"Run rm -rf /"
→ Should be blocked with error message
```

### 4.3 Streaming & Thinking

**Test Extended Thinking**:
1. Use a model that supports thinking (Claude Opus 4.5)
2. Send a complex reasoning prompt
3. Observe thinking block in output
4. Verify thinking tokens counted

---

## 5. AUTHENTICATION

### 5.1 OAuth Flow (Claude Max/Pro)

**Files**:
- Token storage: `~/.tron/auth.json`
- OAuth endpoints: claude.ai/oauth/authorize, console.anthropic.com/v1/oauth/token
- Scopes: `org:create_api_key user:profile user:inference`

**Complete Test**:
```bash
# 1. Start login
npm run dev -w @tron/tui -- login

# 2. Open URL in browser

# 3. Authorize and copy code

# 4. Paste code when prompted

# 5. Verify tokens saved
cat ~/.tron/auth.json
# Should show: accessToken, refreshToken, expiresAt

# 6. Test authentication works
npm run dev -w @tron/tui
# Send a message - should work without errors
```

### 5.2 API Key Authentication

```bash
# Set environment variable
export ANTHROPIC_API_KEY=sk-ant-...

# Run TUI - should use env var
npm run dev -w @tron/tui
```

### 5.3 Token Refresh

OAuth tokens auto-refresh when expired (5-minute buffer).

**Test**:
1. Manually edit `~/.tron/auth.json`
2. Set `expiresAt` to a past timestamp
3. Run TUI and send message
4. Should auto-refresh (check auth.json for new token)

---

## 6. SESSION MANAGEMENT

### 6.1 Session Lifecycle

**Files**:
- Session data: `~/.tron/sessions/<session-id>.jsonl`
- Ledger: `~/.tron/sessions/<session-id>.ledger.md`

**Test New Session**:
```bash
npm run dev -w @tron/tui
# Note the session ID shown in header
# Send a few messages
# Exit with /exit or Ctrl+C
# Check ~/.tron/sessions/ for files
```

**Test Resume Session**:
```bash
# After creating a session:
npm run dev -w @tron/tui -- --continue
# OR
npm run dev -w @tron/tui -- --resume <session-id>

# Messages should be preserved
```

### 6.2 Session State

View with `/session` command:
- Session ID
- Token usage (input/output)
- Message count

---

## 7. MEMORY SYSTEM

### 7.1 Ledger (Working Memory)

**Location**: `~/.tron/sessions/<session-id>.ledger.md`

**Format**:
```markdown
## Goal
Current objective

## Done
- Completed task 1
- Completed task 2

## Now
Current work

## Next
- Upcoming task 1
- Upcoming task 2

## Decisions
- **Choice**: Reason
```

**Test**:
1. Run session and do some work
2. Check ledger file for updates
3. Resume session - ledger should influence context

### 7.2 Handoffs (Episodic Memory)

**Location**: `~/.tron/memory/handoffs.db` (SQLite)

Handoffs are session summaries with:
- Summary text
- Code changes made
- Current state
- Next steps
- Patterns discovered

**Test**:
1. Complete meaningful work in session
2. Exit gracefully
3. Start new session
4. Agent should have context from previous session

### 7.3 Context Loading

**Hierarchy** (loaded in order, later overrides earlier):
1. `~/.tron/AGENTS.md` (global)
2. `./.tron/AGENTS.md` (project)
3. `./AGENTS.md` (project root)
4. `./CLAUDE.md` (alternative)

**Test**:
```bash
# Create global context
echo "Global instructions" > ~/.tron/AGENTS.md

# Create project context
mkdir -p .tron
echo "Project instructions" > .tron/AGENTS.md

# Run TUI
npm run dev -w @tron/tui

# Check with /context command
/context
# Should show both files loaded
```

---

## 8. CONFIGURATION

### 8.1 Settings Files

**Global**: `~/.tron/settings.json`
```json
{
  "model": "claude-opus-4-5-20251101",
  "provider": "anthropic"
}
```

**Project**: `.tron/settings.json` (overrides global)

### 8.2 Environment Variables

| Variable | Purpose |
|----------|---------|
| `ANTHROPIC_API_KEY` | API key authentication |
| `TRON_DEBUG` | Enable debug logging |
| `TRON_LOG_LEVEL` | debug/info/warn/error |

---

## 9. HOOK SYSTEM

### 9.1 Hook Types

| Hook | When | Use Case |
|------|------|----------|
| `PreToolUse` | Before tool execution | Block dangerous ops |
| `PostToolUse` | After tool completion | Log activity |
| `SessionStart` | Session begins | Load context |
| `SessionEnd` | Session closes | Save learnings |

### 9.2 Hook Locations

- Project: `.agent/hooks/*.ts`
- User: `~/.config/tron/hooks/`

### 9.3 Example Hook

Create `.agent/hooks/pre-tool-use.ts`:
```typescript
import type { HookDefinition, PreToolHookContext } from '@tron/core';

export const hook: HookDefinition = {
  name: 'log-tools',
  type: 'PreToolUse',
  handler: async (context: PreToolHookContext) => {
    console.log(`Tool: ${context.toolName}`);
    return { action: 'continue' };
  }
};
```

---

## 10. ERROR HANDLING

### 10.1 Error Categories

| Category | HTTP Code | Retryable | Suggestion |
|----------|-----------|-----------|------------|
| authentication | 401 | No | Run tron login |
| authorization | 403 | No | Check permissions |
| rate_limit | 429 | Yes | Wait and retry |
| network | - | Yes | Check internet |
| server | 500/502/503 | Yes | Try again |
| invalid_request | 400 | No | - |

### 10.2 Error Display

Errors appear in red in the status bar at bottom of TUI.

**Test Error Handling**:
```bash
# Test auth error
unset ANTHROPIC_API_KEY
rm ~/.tron/auth.json
npm run dev -w @tron/tui
# Should show auth error with suggestion

# Test with valid auth
npm run dev -w @tron/tui -- login
# Complete OAuth flow
# Should work now
```

---

## 11. COMPREHENSIVE TEST CHECKLIST

### Authentication
- [ ] OAuth login flow completes
- [ ] Tokens saved to auth.json
- [ ] Token refresh works when expired
- [ ] API key authentication works
- [ ] Auth status command works
- [ ] Logout clears tokens

### Session Management
- [ ] New session creates files
- [ ] Session ID displayed in header
- [ ] Resume latest session works
- [ ] Resume specific session works
- [ ] Session persists messages
- [ ] Graceful exit saves state

### TUI Features
- [ ] Slash command menu appears on /
- [ ] Arrow keys navigate menu
- [ ] Enter selects command
- [ ] Esc cancels menu
- [ ] /help shows commands
- [ ] /session shows info
- [ ] /clear clears messages
- [ ] /exit exits gracefully
- [ ] History navigation (up/down)
- [ ] Streaming text displays
- [ ] Token counts update

### Tools
- [ ] Read file works
- [ ] Write file creates new file
- [ ] Edit file modifies content
- [ ] Bash executes commands
- [ ] Dangerous commands blocked
- [ ] Grep finds content
- [ ] Find locates files
- [ ] Ls lists directories

### Error Handling
- [ ] Auth errors show suggestion
- [ ] Network errors retry
- [ ] Rate limits handled
- [ ] Errors display in status bar
- [ ] Errors clear on new input

### Memory
- [ ] Ledger file created
- [ ] Ledger updates during session
- [ ] Context loads from AGENTS.md
- [ ] Handoffs created on session end

---

## 12. QUICK START TEST SEQUENCE

```bash
# 1. Build
npm run build

# 2. Run tests
npm test

# 3. Start fresh
rm -rf ~/.tron

# 4. Login
npm run dev -w @tron/tui -- login
# Complete OAuth flow

# 5. Verify auth
npm run dev -w @tron/tui -- auth
# Should show authenticated

# 6. Start session
npm run dev -w @tron/tui

# 7. Test basic interaction
"Hello, can you read the README.md file?"
# Should stream response and read file

# 8. Test slash commands
/help
/session
/context

# 9. Exit
/exit

# 10. Verify persistence
ls ~/.tron/sessions/
# Should see session files

# 11. Resume
npm run dev -w @tron/tui -- --continue
# Should load previous messages
```

---

## 13. FILE LOCATIONS REFERENCE

| File | Location | Purpose |
|------|----------|---------|
| Auth tokens | `~/.tron/auth.json` | OAuth/API key storage |
| Settings | `~/.tron/settings.json` | Global config |
| Sessions | `~/.tron/sessions/*.jsonl` | Message history |
| Ledger | `~/.tron/sessions/*.ledger.md` | Working memory |
| Handoffs | `~/.tron/memory/handoffs.db` | Episodic memory |
| Global context | `~/.tron/AGENTS.md` | Global instructions |
| Project context | `.tron/AGENTS.md` | Project instructions |
| Hooks | `.agent/hooks/*.ts` | Custom hooks |

---

## 14. KNOWN ISSUES TO WATCH FOR

1. **OAuth Token Scope** - Tokens are restricted to Claude Code identity
2. **Large Context** - No automatic compaction yet
3. **Tool Timeouts** - Bash commands timeout at 600s
4. **Memory Limits** - Session files can grow large
5. **Concurrent Access** - Single session per terminal

---

*Generated for Tron v0.1.0*
