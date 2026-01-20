# Quick Reference

<!--
PURPOSE: One-page cheat sheet for common operations.
AUDIENCE: Users who need quick command lookup.

AGENT MAINTENANCE:
- Keep this minimal and scannable
- Update commands if CLI interface changes
- Last verified: 2026-01-20
-->

## CLI

```bash
tron dev          # Build, test, start beta server
tron deploy       # Deploy to production
tron status       # Show service status
tron logs         # Query logs
```

## Slash Commands

```
/help             Show help
/model <name>     Switch model
/clear            Clear context
/fork             Fork session
/rewind <n>       Rewind to message n
/context          Show context usage
/skills           List skills
```

## Tools

```
read   path              Read file
write  path content      Write file
edit   path old new      Edit file
bash   command           Run shell
```

## Keyboard (TUI)

```
Enter     Send message
Ctrl+C    Abort/Exit
Up/Down   History
Tab       Autocomplete
Esc       Cancel
```

## Files

```
~/.tron/
├── settings.json    Config
├── db/              Databases
├── skills/          Global skills
└── rules/           Global context

.claude/             Project config (preferred)
├── AGENTS.md        Context
└── skills/          Project skills

.tron/               Project config (legacy)
├── AGENTS.md        Context
└── skills/          Project skills
```

## Ports

| Environment | WebSocket | Health |
|-------------|-----------|--------|
| Production  | 8080      | 8081   |
| Beta        | 8082      | 8083   |

## Models

```
claude-opus-4-5-20251101     # Most capable
claude-sonnet-4-20250514     # Balanced
claude-haiku-3-5-20241022    # Fast
```
