# User Guide

<!--
PURPOSE: Complete user documentation for Tron features and workflows.
AUDIENCE: End users of Tron (TUI, Web, iOS).

AGENT MAINTENANCE:
- Update when new features are added
- Update CLI options when they change
- Keep slash commands current
- Last verified: 2026-01-20
-->

## Quick Start

```bash
# First-time setup
./scripts/tron setup

# Start development server
tron dev

# In another terminal, start TUI
bun run dev:tui
```

## CLI Options

```bash
tron                    # Start new session
tron -c                 # Continue last session
tron -r <id>            # Resume specific session
tron --model <name>     # Use specific model
tron --verbose          # Verbose output
```

## Slash Commands

### Session

| Command | Description |
|---------|-------------|
| `/clear` | Clear conversation context |
| `/fork` | Fork current session |
| `/rewind <n>` | Rewind to message n |
| `/export` | Export transcript |

### Model

| Command | Description |
|---------|-------------|
| `/model` | Show current model |
| `/model <name>` | Switch to model |
| `/models` | List available models |

### Context

| Command | Description |
|---------|-------------|
| `/context` | Show context usage |
| `/skills` | List available skills |

### Help

| Command | Description |
|---------|-------------|
| `/help` | Show help |
| `/version` | Show version |

## Tools

The agent has access to these tools:

| Tool | Description |
|------|-------------|
| `read` | Read file contents |
| `write` | Create/overwrite files |
| `edit` | Make targeted edits |
| `bash` | Execute shell commands |
| `grep` | Search file contents |
| `find` | Find files by pattern |

## Skills

Skills are reusable context packages. Reference with `@skill-name`:

```
@api-design Create a new endpoint for users
```

**Locations:**
- Global: `~/.tron/skills/`
- Project: `.claude/skills/` or `.tron/skills/`

See [skills.md](./skills.md) for details.

## Context Files

Context files provide project-specific instructions:

- Global: `~/.tron/rules/AGENTS.md`
- Project: `.claude/AGENTS.md` or `AGENTS.md`

## Configuration

Settings file: `~/.tron/settings.json`

```json
{
  "models": {
    "default": "claude-sonnet-4-20250514"
  }
}
```

See [settings.md](./settings.md) for all options.

## Keyboard Shortcuts (TUI)

| Shortcut | Action |
|----------|--------|
| `Enter` | Send message |
| `Ctrl+C` | Abort / Exit |
| `Ctrl+L` | Clear screen |
| `Up/Down` | Navigate history |
| `Tab` | Autocomplete |
| `Esc` | Cancel input |

## Session Management

Sessions are automatically persisted. To resume:

```bash
# Continue last session
tron -c

# Resume specific session
tron -r sess_abc123
```

## File Locations

```
~/.tron/
├── settings.json       # User configuration
├── db/                 # SQLite databases
├── skills/             # User skills
└── rules/              # Global context files

.claude/                # Project config (preferred)
├── AGENTS.md           # Project context
└── skills/             # Project skills
```

## Troubleshooting

### Authentication

```bash
# Check auth status
tron auth

# Re-authenticate
tron login
```

### Debug Logging

```bash
TRON_LOG_LEVEL=debug tron dev
```

### Session Recovery

```bash
# List sessions
ls ~/.tron/db/

# Check database
sqlite3 ~/.tron/db/prod.db ".tables"
```
