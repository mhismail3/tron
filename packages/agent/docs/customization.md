# Customization

## Settings

**Location:** `~/.tron/settings.json`

Only specify overrides. Unspecified values use defaults.

```json
{
  "models": {
    "default": "claude-sonnet-4-20250514",
    "defaultMaxTokens": 4096
  },
  "tools": {
    "bash": { "defaultTimeoutMs": 300000 }
  }
}
```

### Available Settings

| Section | Key | Default | Description |
|---------|-----|---------|-------------|
| `models` | `default` | `claude-opus-4-5-20251101` | Default model |
| `models` | `defaultMaxTokens` | `4096` | Max output tokens |
| `tools.bash` | `defaultTimeoutMs` | `120000` | Command timeout |
| `tools.bash` | `maxOutputLength` | `30000` | Output truncation |
| `tools.read` | `defaultLimitLines` | `2000` | Lines per read |
| `tools.grep` | `skipDirectories` | `["node_modules", ".git"]` | Excluded dirs |
| `server` | `wsPort` | `8080` | WebSocket port |
| `server` | `healthPort` | `8081` | Health endpoint port |

### Environment Overrides

Environment variables override settings.json:

| Variable | Overrides |
|----------|-----------|
| `TRON_WS_PORT` | `server.wsPort` |
| `TRON_HEALTH_PORT` | `server.healthPort` |
| `TRON_DEFAULT_MODEL` | `models.default` |
| `TRON_LOG_LEVEL` | Logging verbosity |

## Skills

Skills are reusable context packages. Each is a folder with a `SKILL.md` file.

### Locations

| Location | Scope |
|----------|-------|
| `~/.tron/skills/` | Global (all projects) |
| `.claude/skills/` or `.tron/skills/` | Project (higher precedence) |

### Usage

Reference with `@skill-name` in prompts:

```
@api-design Create a new endpoint for users
```

Multiple skills: `@typescript-rules @testing Help me write tests`

### Creating a Skill

```bash
mkdir -p ~/.tron/skills/my-rules
cat > ~/.tron/skills/my-rules/SKILL.md << 'EOF'
---
autoInject: true
tags: [rules]
---
Project coding standards.

- Use strict TypeScript
- No `any` types
- Write tests for new code
EOF
```

### Frontmatter

```yaml
---
autoInject: false    # true = included in every prompt
version: "1.0.0"     # For tracking changes
tools: [Read, Edit]  # Informational
tags: [typescript]   # For filtering
---
```

**`autoInject: true`** includes the skill automatically without `@reference`. Use sparingly—consumes tokens on every request.

### How It Works

The prompt `@api-design Create endpoint` becomes:

```xml
<skills>
<skill name="api-design">
[SKILL.md content]
</skill>
</skills>

Create endpoint
```

## System Prompt

The system prompt defines the agent's core identity. Custom prompts override the built-in default.

### Locations (Priority Order)

1. **Programmatic** - `systemPrompt` parameter in code
2. **Project** - `.claude/SYSTEM.md` or `.tron/SYSTEM.md`
3. **Global** - `~/.tron/SYSTEM.md`
4. **Built-in** - Default `TRON_CORE_PROMPT`

Project prompts **replace** global prompts entirely (no merging).

### Example

```bash
cat > .claude/SYSTEM.md << 'EOF'
You are Tron, a TypeScript assistant for this project.

Tools: read, write, edit, bash, grep, find, ls

Rules:
- Use strict mode
- No `any` types
- Write tests for new code
EOF
```

### Guidelines

- Keep under 1000 tokens (~4KB)
- Don't repeat tool descriptions (agent knows them)
- Put domain knowledge in Skills instead
- System prompt = identity, Skills = capabilities

## Context Rules

Context rules (AGENTS.md/CLAUDE.md) provide project-specific instructions loaded into every prompt.

### Locations

| Location | Scope |
|----------|-------|
| `.claude/AGENTS.md` or `.tron/AGENTS.md` | Project |
| `subdir/AGENTS.md` | Subdirectory (path-scoped) |

### Path-Scoped Rules

Rules in subdirectories only load when working with files in that path:

```
project/
├── .claude/AGENTS.md          # Always loaded
├── src/
│   └── AGENTS.md              # Loaded for src/ files
└── tests/
    └── AGENTS.md              # Loaded for tests/ files
```

## File Locations Summary

```
~/.tron/
├── settings.json       # Global settings
├── auth.json           # API keys and OAuth tokens
├── SYSTEM.md           # Global system prompt
├── skills/             # Global skills
│   └── my-skill/
│       └── SKILL.md
└── rules/
    └── AGENTS.md       # Global context rules

.claude/                # Project config (or .tron/)
├── SYSTEM.md           # Project system prompt
├── AGENTS.md           # Project context rules
└── skills/             # Project skills
```

## Hooks

Hooks allow custom logic at key points in agent execution. The hook system consists of three components:

- **HookEngine** - Orchestrates hook execution
- **HookRegistry** - Manages registration and priority sorting
- **BackgroundTracker** - Tracks async background hook execution

### Hook Types

| Type | Mode | Description |
|------|------|-------------|
| `PreToolUse` | Blocking | Before tool execution. Can block or modify. |
| `PostToolUse` | Background | After tool completion. For logging/observation. |
| `UserPromptSubmit` | Blocking | Before processing user input. Can validate/transform. |
| `PreCompact` | Blocking | Before context compaction. |
| `SessionStart` | Background | On session creation. |
| `SessionEnd` | Background | On session termination. |
| `Stop` | Background | On agent turn completion. |
| `SubagentStop` | Background | On subagent completion. |

**Blocking hooks** must complete before the operation continues. They can return control signals.

**Background hooks** run asynchronously and don't block the main flow. Errors are logged but don't fail the operation (fail-open design).

### Hook Priority

Hooks execute in priority order (highest first). Default priority is 0.

```typescript
// High priority hook runs first
hookEngine.register({
  name: 'security-check',
  type: 'PreToolUse',
  priority: 100,
  handler: async (context) => {
    // Runs before default priority hooks
  },
});
```

### PreToolUse

Runs before a tool executes. Can block or modify the call.

```typescript
// In .claude/hooks/pre-tool-use.ts
export default async function(context) {
  const { toolName, toolInput, sessionId } = context;

  if (toolName === 'bash' && toolInput.command.includes('rm -rf')) {
    return { blocked: true, reason: 'Dangerous command blocked' };
  }

  // Modify input
  if (toolName === 'bash') {
    return {
      proceed: true,
      modifiedInput: { ...toolInput, timeout: 30000 }
    };
  }

  return { proceed: true };
}
```

### PostToolUse

Runs after a tool completes. For logging or observation.

```typescript
// In .claude/hooks/post-tool-use.ts
export default async function(context) {
  const { toolName, toolResult, duration, sessionId } = context;

  // Log to external service
  await analytics.track('tool_execution', {
    tool: toolName,
    duration,
    success: !toolResult.isError,
    sessionId,
  });
}
```

### UserPromptSubmit

Runs before processing user input. Can validate or transform.

```typescript
// In .claude/hooks/user-prompt-submit.ts
export default async function(context) {
  const { content, sessionId } = context;

  // Block certain inputs
  if (content.includes('SECRET_TOKEN')) {
    return { blocked: true, reason: 'Sensitive content detected' };
  }

  return { proceed: true };
}
```

### Hook Context

Each hook type receives a typed context with relevant data:

```typescript
// PreToolUse context
interface PreToolHookContext {
  hookType: 'PreToolUse';
  sessionId: string;
  timestamp: string;
  toolName: string;
  toolInput: Record<string, unknown>;
  data: Record<string, unknown>;
}

// PostToolUse context
interface PostToolHookContext {
  hookType: 'PostToolUse';
  sessionId: string;
  timestamp: string;
  toolName: string;
  toolResult: ToolResult;
  duration: number;
  data: Record<string, unknown>;
}
```

### Error Handling

Hooks use fail-open error handling. If a hook throws:
- Error is logged with session context
- Operation continues (for background hooks)
- Blocking hooks may block if they throw

This ensures extension failures don't crash the agent.

### Waiting for Background Hooks

Before shutdown, drain pending background hooks:

```typescript
// Wait up to 5 seconds for background hooks to complete
await hookEngine.waitForBackgroundHooks(5000);
```
