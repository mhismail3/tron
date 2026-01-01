# Tron Agent - Quick Reference

## CLI

```bash
tron                          # Start new session
tron -c                       # Continue last session
tron -r <id>                  # Resume specific session
tron --model gpt-4o           # Use specific model
tron login                    # OAuth login
tron logout                   # Clear credentials
```

## Slash Commands

```
/help                  Show help
/model <name>          Switch model
/models                List models
/clear                 Clear context
/fork                  Fork session
/rewind <n>            Rewind to message n
/export [format]       Export transcript
/ledger                Show ledger
/handoff               Create handoff
/search <query>        Search handoffs
/skills                List skills
/context               Show context usage
```

## Session Operations

| Operation | CLI | Slash Command | RPC |
|-----------|-----|---------------|-----|
| New session | `tron` | - | `session.create` |
| Continue | `tron -c` | - | `session.get` |
| Fork | - | `/fork` | `session.fork` |
| Rewind | - | `/rewind 5` | `session.rewind` |
| List | - | - | `session.list` |

## Memory Hierarchy

```
Level 1: Immediate   →  In-context messages
Level 2: Session     →  Ledger (goal/now/next)
Level 3: Project     →  Handoffs (searchable)
Level 4: Global      →  Learnings (patterns)
```

## Tools

```
read   path [offset] [limit]     Read file
write  path content              Write file
edit   path oldText newText      Edit file
bash   command [timeout]         Run shell command
```

## Hooks

```
session_start    →  Load context
session_end      →  Save learnings
pre_tool_use     →  Validate/block
post_tool_use    →  Index changes
pre_compact      →  Auto-handoff
```

## Models

```
anthropic:  claude-opus-4-20250514, claude-sonnet-4-20250514
openai:     gpt-4o, gpt-4-turbo
google:     gemini-pro, gemini-1.5-pro
```

## Files

```
~/.tron/
├── AGENTS.md        Global context
├── auth.json        Credentials
├── settings.json    Preferences
└── skills/          User skills

.tron/
├── sessions/        Session files
├── memory/          Databases
└── AGENTS.md        Project context
```

## Keyboard (TUI)

```
Enter    Send message
Ctrl+C   Abort/Exit
Ctrl+L   Clear screen
Up/Down  History
Tab      Autocomplete
Esc      Cancel
```
