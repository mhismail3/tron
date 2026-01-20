# Settings

<!--
PURPOSE: Complete reference for ~/.tron/settings.json configuration.
AUDIENCE: Users customizing Tron behavior.

AGENT MAINTENANCE:
- Update when new settings are added to packages/core/src/settings/
- Verify default values match actual code defaults
- Last verified: 2026-01-20
-->

## Location

Settings file: `~/.tron/settings.json`

Only specify values you want to override. Unspecified values use defaults.

## Quick Example

```json
{
  "models": {
    "default": "claude-sonnet-4-20250514"
  },
  "tools": {
    "bash": {
      "defaultTimeoutMs": 300000
    }
  }
}
```

## Models

```json
{
  "models": {
    "default": "claude-opus-4-5-20251101",
    "defaultMaxTokens": 4096,
    "defaultThinkingBudget": 2048
  }
}
```

| Setting | Default | Description |
|---------|---------|-------------|
| `default` | `claude-opus-4-5-20251101` | Default model ID |
| `defaultMaxTokens` | `4096` | Max output tokens |
| `defaultThinkingBudget` | `2048` | Thinking token budget |

## Tools

### Bash

```json
{
  "tools": {
    "bash": {
      "defaultTimeoutMs": 120000,
      "maxTimeoutMs": 600000,
      "maxOutputLength": 30000
    }
  }
}
```

Dangerous patterns are blocked by default: `rm -rf /`, `sudo`, `chmod 777 /`, `mkfs.*`, fork bombs.

### Read

```json
{
  "tools": {
    "read": {
      "defaultLimitLines": 2000,
      "maxLineLength": 2000
    }
  }
}
```

### Grep

```json
{
  "tools": {
    "grep": {
      "defaultMaxResults": 100,
      "skipDirectories": ["node_modules", ".git", "dist"]
    }
  }
}
```

## Context

```json
{
  "context": {
    "compactor": {
      "maxTokens": 25000,
      "compactionThreshold": 0.85,
      "preserveRecentCount": 2
    }
  }
}
```

## Server

```json
{
  "server": {
    "wsPort": 8080,
    "healthPort": 8081,
    "maxConcurrentSessions": 10
  }
}
```

## UI

```json
{
  "ui": {
    "palette": {
      "primary": "#123524",
      "primaryVivid": "#34d399",
      "error": "#ef4444"
    },
    "thinkingAnimation": {
      "intervalMs": 120
    }
  }
}
```

## Environment Overrides

| Variable | Overrides |
|----------|-----------|
| `TRON_WS_PORT` | `server.wsPort` |
| `TRON_HEALTH_PORT` | `server.healthPort` |
| `TRON_DEFAULT_MODEL` | `server.defaultModel` |

Environment variables take precedence over settings.json.

## Troubleshooting

```bash
# Validate JSON syntax
cat ~/.tron/settings.json | jq .

# Reset to defaults
rm ~/.tron/settings.json
```
