# Customization

<!--
PURPOSE: How to configure Tron's behavior via settings, skills, and system prompts.
AUDIENCE: Users customizing Tron for their workflow.

AGENT MAINTENANCE:
- Update settings when new options added to packages/core/src/settings/
- Update skill frontmatter fields if schema changes
- Verify file locations match actual loader behavior
- Last verified: 2026-01-20
-->

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

`TRON_WS_PORT`, `TRON_HEALTH_PORT`, `TRON_DEFAULT_MODEL` override settings.json.

---

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

---

## System Prompt

The system prompt defines Tron's core identity. Custom prompts override the built-in default.

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
- Don't repeat tool descriptions (Tron knows them)
- Put domain knowledge in Skills instead
- System prompt = identity, Skills = capabilities

---

## File Locations Summary

```
~/.tron/
├── settings.json       # Global settings
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
