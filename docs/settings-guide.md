# Tron Settings Configuration Guide

Tron is fully configurable through a JSON settings file. This guide covers every available setting, with examples and explanations.

## Quick Start

Create your settings file at `~/.tron/settings.json`:

```bash
mkdir -p ~/.tron
touch ~/.tron/settings.json
```

Add your customizations (you only need to specify what you want to change):

```json
{
  "models": {
    "default": "claude-sonnet-4-20250514"
  },
  "ui": {
    "palette": {
      "primary": "#1a1a2e"
    }
  }
}
```

**Key concept**: You only need to include settings you want to override. Tron deep-merges your settings with the defaults, so unspecified values use sensible defaults.

---

## Table of Contents

1. [How Settings Work](#how-settings-work)
2. [API Settings](#api-settings)
3. [Model Settings](#model-settings)
4. [Retry Settings](#retry-settings)
5. [Tool Settings](#tool-settings)
6. [Context Settings](#context-settings)
7. [Hook Settings](#hook-settings)
8. [Server Settings](#server-settings)
9. [Tmux Settings](#tmux-settings)
10. [Session Settings](#session-settings)
11. [UI Settings](#ui-settings)
12. [Complete Example](#complete-example)
13. [Environment Variable Overrides](#environment-variable-overrides)

---

## How Settings Work

### File Location

Settings are loaded from `~/.tron/settings.json` on first access.

### Deep Merging

Your settings are deep-merged with defaults. This means:

```json
// Your settings.json
{
  "tools": {
    "bash": {
      "defaultTimeoutMs": 300000
    }
  }
}
```

Results in bash having a 5-minute timeout while keeping all other bash settings (like `dangerousPatterns`) at their defaults.

### Reload Settings

Settings are cached after first load. To reload settings without restarting Tron, you can use the programmatic API:

```typescript
import { reloadSettings } from '@tron/core';
reloadSettings();
```

---

## API Settings

Configure OAuth and API endpoints for Anthropic.

```json
{
  "api": {
    "anthropic": {
      "authUrl": "https://claude.ai/oauth/authorize",
      "tokenUrl": "https://console.anthropic.com/v1/oauth/token",
      "clientId": "tron-agent",
      "scopes": ["user:inference", "user:profile"],
      "systemPromptPrefix": "You are Claude Code, Anthropic's official CLI for Claude.",
      "oauthBetaHeaders": "oauth-2025-04-20,interleaved-thinking-2025-05-14",
      "tokenExpiryBufferSeconds": 300
    }
  }
}
```

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `authUrl` | string | `https://claude.ai/oauth/authorize` | OAuth authorization URL |
| `tokenUrl` | string | `https://console.anthropic.com/v1/oauth/token` | OAuth token exchange URL |
| `clientId` | string | `tron-agent` | OAuth client identifier |
| `scopes` | string[] | `["user:inference", "user:profile"]` | OAuth scopes to request |
| `systemPromptPrefix` | string | `"You are Claude Code..."` | Required prefix for OAuth system prompts |
| `oauthBetaHeaders` | string | (see default) | Beta feature headers for OAuth requests |
| `tokenExpiryBufferSeconds` | number | `300` | Refresh tokens this many seconds before expiry |

---

## Model Settings

Configure the default model and token limits.

```json
{
  "models": {
    "default": "claude-opus-4-5-20251101",
    "defaultMaxTokens": 4096,
    "defaultThinkingBudget": 2048
  }
}
```

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `default` | string | `claude-opus-4-5-20251101` | Default model ID |
| `defaultMaxTokens` | number | `4096` | Maximum output tokens per response |
| `defaultThinkingBudget` | number | `2048` | Token budget for thinking/reasoning |

### Common Model IDs

- `claude-opus-4-5-20251101` - Most capable, best for complex tasks
- `claude-sonnet-4-20250514` - Balanced performance and speed
- `claude-haiku-3-5-20241022` - Fastest, best for simple tasks

---

## Retry Settings

Configure automatic retry behavior for API calls.

```json
{
  "retry": {
    "maxRetries": 5,
    "baseDelayMs": 1000,
    "maxDelayMs": 60000,
    "jitterFactor": 0.2
  }
}
```

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `maxRetries` | number | `5` | Maximum retry attempts |
| `baseDelayMs` | number | `1000` | Initial delay between retries (1 second) |
| `maxDelayMs` | number | `60000` | Maximum delay cap (1 minute) |
| `jitterFactor` | number | `0.2` | Random jitter factor (0-1) to prevent thundering herd |

The retry delay uses exponential backoff: `delay = min(baseDelay * 2^attempt, maxDelay) * (1 + random * jitterFactor)`

---

## Tool Settings

Configure the behavior of built-in tools.

### Bash Tool

```json
{
  "tools": {
    "bash": {
      "defaultTimeoutMs": 120000,
      "maxTimeoutMs": 600000,
      "maxOutputLength": 30000,
      "dangerousPatterns": [
        "^rm\\s+(-rf?|--force)\\s+/\\s*$",
        "^sudo\\s+",
        "^chmod\\s+777\\s+/\\s*$",
        "^mkfs\\.",
        "^dd\\s+if=.*of=/dev/"
      ]
    }
  }
}
```

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `defaultTimeoutMs` | number | `120000` | Default command timeout (2 minutes) |
| `maxTimeoutMs` | number | `600000` | Maximum allowed timeout (10 minutes) |
| `maxOutputLength` | number | `30000` | Max output characters before truncation |
| `dangerousPatterns` | string[] | (see below) | Regex patterns for blocked commands |

#### Default Dangerous Patterns

These patterns block potentially destructive commands:

```json
[
  "^rm\\s+(-rf?|--force)\\s+/\\s*$",   // rm -rf /
  "^rm\\s+-rf?\\s+/\\s*$",              // rm -rf /
  "rm\\s+-rf?\\s+/",                     // rm -rf / anywhere
  "^sudo\\s+",                           // sudo commands
  "^chmod\\s+777\\s+/\\s*$",            // chmod 777 /
  "^mkfs\\.",                            // filesystem format
  "^dd\\s+if=.*of=/dev/",               // dd to device
  ">\\s*/dev/sd[a-z]",                  // redirect to disk
  "^:\\(\\)\\s*\\{\\s*:\\|\\s*:\\s*&\\s*\\}\\s*;\\s*:"  // fork bomb
]
```

**Security note**: Customize carefully. Removing patterns may allow dangerous commands.

### Read Tool

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

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `defaultLimitLines` | number | `2000` | Default lines to read from files |
| `maxLineLength` | number | `2000` | Truncate lines longer than this |

### Find Tool

```json
{
  "tools": {
    "find": {
      "defaultMaxResults": 100,
      "defaultMaxDepth": 10
    }
  }
}
```

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `defaultMaxResults` | number | `100` | Maximum files to return |
| `defaultMaxDepth` | number | `10` | Maximum directory depth to search |

### Grep Tool

```json
{
  "tools": {
    "grep": {
      "defaultMaxResults": 100,
      "maxFileSizeBytes": 10485760,
      "binaryExtensions": [".png", ".jpg", ".pdf", ".zip"],
      "skipDirectories": ["node_modules", ".git", "dist"]
    }
  }
}
```

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `defaultMaxResults` | number | `100` | Maximum matches to return |
| `maxFileSizeBytes` | number | `10485760` | Skip files larger than 10MB |
| `binaryExtensions` | string[] | (see below) | File extensions to skip |
| `skipDirectories` | string[] | (see below) | Directories to skip |

#### Default Binary Extensions

```json
[
  ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".webp", ".svg",
  ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
  ".zip", ".tar", ".gz", ".rar", ".7z",
  ".exe", ".dll", ".so", ".dylib",
  ".woff", ".woff2", ".ttf", ".eot",
  ".mp3", ".mp4", ".avi", ".mov", ".wav",
  ".o", ".a", ".lib", ".obj",
  ".pyc", ".class", ".jar"
]
```

#### Default Skip Directories

```json
["node_modules", "__pycache__", "dist", "build", ".git", ".svn", ".hg", "vendor", "target"]
```

---

## Context Settings

Configure context window management and memory.

### Compactor Settings

The compactor automatically summarizes conversation history when it gets too long.

```json
{
  "context": {
    "compactor": {
      "maxTokens": 25000,
      "compactionThreshold": 0.85,
      "targetTokens": 10000,
      "preserveRecentCount": 2,
      "charsPerToken": 4
    }
  }
}
```

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `maxTokens` | number | `25000` | Maximum tokens before compaction triggers |
| `compactionThreshold` | number | `0.85` | Trigger when usage exceeds this ratio (85%) |
| `targetTokens` | number | `10000` | Target token count after compaction |
| `preserveRecentCount` | number | `2` | Number of recent message pairs to preserve |
| `charsPerToken` | number | `4` | Characters per token estimate |

### Memory Settings

```json
{
  "context": {
    "memory": {
      "maxEntries": 1000
    }
  }
}
```

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `maxEntries` | number | `1000` | Maximum entries in memory cache |

---

## Hook Settings

Configure the hook system for custom automation.

```json
{
  "hooks": {
    "defaultTimeoutMs": 5000,
    "discoveryTimeoutMs": 10000,
    "projectDir": ".agent/hooks",
    "userDir": ".config/tron/hooks",
    "extensions": [".ts", ".js", ".mjs", ".sh"]
  }
}
```

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `defaultTimeoutMs` | number | `5000` | Default hook execution timeout (5 seconds) |
| `discoveryTimeoutMs` | number | `10000` | Timeout for shell hook discovery |
| `projectDir` | string | `.agent/hooks` | Project-level hooks directory |
| `userDir` | string | `.config/tron/hooks` | User-level hooks directory (relative to ~) |
| `extensions` | string[] | `[".ts", ".js", ".mjs", ".sh"]` | Supported hook file extensions |

### Hook File Locations

Hooks are discovered from (in priority order):

1. **Project hooks**: `<project>/.agent/hooks/`
2. **User hooks**: `~/.config/tron/hooks/`

---

## Server Settings

Configure the Tron server (WebSocket and health endpoints).

```json
{
  "server": {
    "wsPort": 8080,
    "healthPort": 8081,
    "host": "0.0.0.0",
    "heartbeatIntervalMs": 30000,
    "sessionTimeoutMs": 1800000,
    "maxConcurrentSessions": 10,
    "sessionsDir": "sessions",
    "memoryDbPath": "memory.db",
    "defaultModel": "claude-sonnet-4-20250514",
    "defaultProvider": "anthropic"
  }
}
```

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `wsPort` | number | `8080` | WebSocket server port |
| `healthPort` | number | `8081` | Health check endpoint port |
| `host` | string | `0.0.0.0` | Server bind address |
| `heartbeatIntervalMs` | number | `30000` | WebSocket heartbeat interval (30 seconds) |
| `sessionTimeoutMs` | number | `1800000` | Session inactivity timeout (30 minutes) |
| `maxConcurrentSessions` | number | `10` | Maximum concurrent sessions |
| `sessionsDir` | string | `sessions` | Sessions directory (relative to ~/.tron) |
| `memoryDbPath` | string | `memory.db` | Memory database path (relative to ~/.tron) |
| `defaultModel` | string | `claude-sonnet-4-20250514` | Default model for server sessions |
| `defaultProvider` | string | `anthropic` | Default provider |

---

## Tmux Settings

Configure tmux integration for terminal multiplexing.

```json
{
  "tmux": {
    "commandTimeoutMs": 30000,
    "pollingIntervalMs": 500
  }
}
```

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `commandTimeoutMs` | number | `30000` | Tmux command timeout (30 seconds) |
| `pollingIntervalMs` | number | `500` | Output polling interval (500ms) |

---

## Session Settings

Configure session behavior.

```json
{
  "session": {
    "worktreeTimeoutMs": 30000
  }
}
```

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `worktreeTimeoutMs` | number | `30000` | Git worktree command timeout |

---

## UI Settings

Customize the terminal user interface appearance.

### Theme Name

```json
{
  "ui": {
    "theme": "forest_green"
  }
}
```

Currently `forest_green` is the only theme. This field is reserved for future theme presets.

### Color Palette

Customize all colors using hex color codes:

```json
{
  "ui": {
    "palette": {
      "primary": "#123524",
      "primaryLight": "#1a4a32",
      "primaryBright": "#2d7a4e",
      "primaryVivid": "#34d399",
      "emerald": "#10b981",
      "mint": "#6ee7b7",
      "sage": "#86efac",
      "dark": "#0a1f15",
      "muted": "#1f3d2c",
      "subtle": "#2d5a40",
      "textBright": "#ecfdf5",
      "textPrimary": "#d1fae5",
      "textSecondary": "#a7f3d0",
      "textMuted": "#6b8f7a",
      "textDim": "#4a6b58",
      "statusBarText": "#2eb888",
      "success": "#22c55e",
      "warning": "#f59e0b",
      "error": "#ef4444",
      "info": "#38bdf8"
    }
  }
}
```

| Color | Default | Usage |
|-------|---------|-------|
| `primary` | `#123524` | Base forest green |
| `primaryLight` | `#1a4a32` | Lighter variant |
| `primaryBright` | `#2d7a4e` | Bright emphasis |
| `primaryVivid` | `#34d399` | Vivid highlights |
| `emerald` | `#10b981` | Accent color |
| `mint` | `#6ee7b7` | Soft highlights |
| `sage` | `#86efac` | Very light accents |
| `dark` | `#0a1f15` | Dark background |
| `muted` | `#1f3d2c` | Muted elements |
| `subtle` | `#2d5a40` | Borders |
| `textBright` | `#ecfdf5` | Brightest text |
| `textPrimary` | `#d1fae5` | Main text |
| `textSecondary` | `#a7f3d0` | Secondary text |
| `textMuted` | `#6b8f7a` | Muted text |
| `textDim` | `#4a6b58` | Dim text |
| `statusBarText` | `#2eb888` | Status bar |
| `success` | `#22c55e` | Success states |
| `warning` | `#f59e0b` | Warnings |
| `error` | `#ef4444` | Errors |
| `info` | `#38bdf8` | Info states |

### Icons

Customize the Unicode characters used throughout the UI:

```json
{
  "ui": {
    "icons": {
      "prompt": "›",
      "user": "›",
      "assistant": "◆",
      "system": "◇",
      "toolRunning": "◇",
      "toolSuccess": "◆",
      "toolError": "◈",
      "ready": "◆",
      "thinking": "◇",
      "streaming": "◆",
      "bullet": "•",
      "arrow": "→",
      "check": "✓",
      "pasteOpen": "⌈",
      "pasteClose": "⌋"
    }
  }
}
```

### Thinking Animation

Customize the animated thinking indicator:

```json
{
  "ui": {
    "thinkingAnimation": {
      "chars": ["▁", "▂", "▃", "▄", "▅"],
      "width": 4,
      "intervalMs": 120
    }
  }
}
```

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `chars` | string[] | `["▁", "▂", "▃", "▄", "▅"]` | Animation frame characters |
| `width` | number | `4` | Number of bars to display |
| `intervalMs` | number | `120` | Animation speed in milliseconds |

### Input Settings

Configure input behavior:

```json
{
  "ui": {
    "input": {
      "pasteThreshold": 3,
      "maxHistory": 100,
      "defaultTerminalWidth": 80,
      "narrowThreshold": 50,
      "narrowVisibleLines": 10,
      "normalVisibleLines": 20
    }
  }
}
```

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `pasteThreshold` | number | `3` | Characters received at once to detect paste |
| `maxHistory` | number | `100` | Maximum prompt history entries |
| `defaultTerminalWidth` | number | `80` | Fallback terminal width |
| `narrowThreshold` | number | `50` | Width threshold for narrow mode |
| `narrowVisibleLines` | number | `10` | Visible lines in narrow mode |
| `normalVisibleLines` | number | `20` | Visible lines in normal mode |

### Menu Settings

Configure the slash command menu:

```json
{
  "ui": {
    "menu": {
      "maxVisibleCommands": 5
    }
  }
}
```

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `maxVisibleCommands` | number | `5` | Maximum visible commands in slash menu |

---

## Complete Example

Here's a complete settings file showcasing various customizations:

```json
{
  "version": "0.1.0",

  "models": {
    "default": "claude-sonnet-4-20250514",
    "defaultMaxTokens": 8192,
    "defaultThinkingBudget": 4096
  },

  "retry": {
    "maxRetries": 3,
    "baseDelayMs": 2000
  },

  "tools": {
    "bash": {
      "defaultTimeoutMs": 300000,
      "dangerousPatterns": [
        "^rm\\s+-rf\\s+/",
        "^sudo\\s+rm",
        "^mkfs\\."
      ]
    },
    "grep": {
      "defaultMaxResults": 200,
      "skipDirectories": [
        "node_modules",
        ".git",
        "dist",
        "coverage",
        ".next"
      ]
    }
  },

  "context": {
    "compactor": {
      "maxTokens": 50000,
      "preserveRecentCount": 4
    }
  },

  "hooks": {
    "defaultTimeoutMs": 10000,
    "projectDir": ".tron/hooks"
  },

  "server": {
    "wsPort": 9000,
    "healthPort": 9001,
    "maxConcurrentSessions": 20
  },

  "ui": {
    "palette": {
      "primary": "#1e3a5f",
      "primaryVivid": "#60a5fa",
      "emerald": "#3b82f6"
    },
    "thinkingAnimation": {
      "intervalMs": 80
    },
    "input": {
      "maxHistory": 500
    }
  }
}
```

---

## Environment Variable Overrides

Server settings can also be overridden via environment variables:

| Environment Variable | Overrides |
|---------------------|-----------|
| `TRON_WS_PORT` | `server.wsPort` |
| `TRON_HEALTH_PORT` | `server.healthPort` |
| `TRON_HOST` | `server.host` |
| `TRON_SESSIONS_DIR` | `server.sessionsDir` |
| `TRON_MEMORY_DB` | `server.memoryDbPath` |
| `TRON_DEFAULT_MODEL` | `server.defaultModel` |
| `TRON_DEFAULT_PROVIDER` | `server.defaultProvider` |
| `TRON_MAX_SESSIONS` | `server.maxConcurrentSessions` |
| `TRON_HEARTBEAT_INTERVAL` | `server.heartbeatIntervalMs` |

Environment variables take precedence over settings.json.

---

## Troubleshooting

### Settings Not Loading

1. Check JSON syntax is valid:
   ```bash
   cat ~/.tron/settings.json | jq .
   ```

2. Ensure the file is readable:
   ```bash
   ls -la ~/.tron/settings.json
   ```

### Resetting to Defaults

Delete your settings file to use all defaults:

```bash
rm ~/.tron/settings.json
```

### Validating Settings

Settings are validated at load time. Check logs for errors:

```bash
TRON_LOG_LEVEL=debug tron
```

---

## Programmatic Access

For developers, settings can be accessed programmatically:

```typescript
import { getSettings, reloadSettings, saveSettings } from '@tron/core';

// Get current settings (cached)
const settings = getSettings();
console.log(settings.models.default);

// Reload from disk
reloadSettings();

// Save modified settings
saveSettings({ models: { default: 'claude-haiku-3-5-20241022' } });
```
