---
name: "Self Inspect"
description: "Inspect Tron database, settings, auth, skills, deployment, health, and all ~/.tron/ state via direct sqlite3 queries and file reads. Trigger on 'debug this session', 'what went wrong', 'why did that fail', 'inspect my last turns', 'what just happened', 'debug this chat' — diagnose the current live session's errors, failed tools, and anomalies, then write a diagnostic report to ~/.tron/workspace/reports/"
version: "3.2.0"
allowedTools:
  - Bash
tags:
  - introspection
  - tron
  - debugging
---

Comprehensive self-introspection for the Tron installation. Use this skill to investigate sessions, analyze token usage, debug cron jobs, check server health, inspect settings/auth/skills, or understand any aspect of `~/.tron/` state.

All inspection is done via direct `sqlite3` queries and file reads — no wrapper scripts needed.

## MANDATORY: Session Debug Always Produces a Report File

Whenever you debug or investigate a session — for ANY reason — you MUST write a structured report to `~/.tron/workspace/reports/`. This is not optional. Posting findings only in chat is not sufficient. The file must be written BEFORE you give the verbal summary. See `reference/session-debug.md` Step 8 for the exact path format and template.

## Routing Table

| Intent | Action |
|--------|--------|
| Database schema, tables, columns | Read `reference/schema.md` |
| SQL queries for investigation | Read `reference/queries.md` |
| Debug this session / what went wrong / why did that fail | Read `reference/session-debug.md` → **write report to `~/.tron/workspace/reports/` (mandatory)** |
| Investigation workflows | Read `reference/workflows.md` |
| Server health | `curl -s http://localhost:9847/health \| jq .` |
| Deep health check | `curl -s http://localhost:9847/health/deep \| jq .` |
| Settings | `cat ~/.tron/system/settings.json \| jq .` |
| Auth providers | `cat ~/.tron/system/auth.json \| jq 'del(.. \| .accessToken?, .refreshToken?, .apiKey?, .clientSecret?)'` |
| Deploy status | `curl -s http://localhost:9847/deploy/status \| jq .` |

## ~/.tron/ Directory Layout

```
~/.tron/
├── system/                        # Operational state
│   ├── Tron.app/                  # App bundle (macOS TCC identity)
│   │   └── Contents/MacOS/tron    # Server binary (Rust, launchd-managed)
│   ├── auth.json                  # OAuth tokens and API keys
│   ├── settings.json              # All configuration
│   ├── database/
│   │   └── log.db                 # Main SQLite database
│   ├── deployment/                # Deploy scripts and state
│   │   ├── tron-cli               # CLI wrapper
│   │   ├── tron-lib.sh            # Shared deployment library
│   │   ├── tron-agent.entitlements # Hardened runtime entitlements
│   │   ├── deployed-commit        # Current git commit hash
│   │   ├── last-deployment.json   # Last deploy metadata
│   │   ├── restart-sentinel.json  # Restart state tracking
│   │   ├── workspace-path         # Path to tron workspace
│   │   └── auth.lock              # Auth serialization lock
│   └── transcription/             # Speech-to-text sidecar (worker.py, venv/, models/hf/)
├── skills/                        # Installed skills (SKILL.md per skill)
├── memory/                        # Agent memory and working state
│   ├── rules/SYSTEM.md            # System identity and operational rules
│   ├── knowledge/                 # Long-term knowledge base
│   ├── sessions/log.md            # Session completion notes
│   ├── cron/                      # Cron job working files
│   └── scratch/                   # Temporary files and experiments
└── user/
    └── voice/                     # Voice I/O files
```

## Quick Access

```bash
DB="$HOME/.tron/system/database/log.db"

# Recent sessions
sqlite3 "$DB" "SELECT id, title, origin, datetime(last_activity_at) as last_active, event_count, printf('\$%.4f', total_cost) as cost FROM sessions ORDER BY last_activity_at DESC LIMIT 10;"

# Errors in a session
sqlite3 "$DB" "SELECT sequence, type, datetime(timestamp), json_extract(payload, '\$.error.message') FROM events WHERE session_id = 'SESSION_ID' AND type LIKE 'error.%' ORDER BY sequence;"

# Token costs by session
sqlite3 "$DB" "SELECT id, title, total_input_tokens + total_output_tokens as tokens, printf('\$%.4f', total_cost) as cost FROM sessions WHERE total_cost > 0 ORDER BY total_cost DESC LIMIT 10;"

# Cron job status
sqlite3 "$DB" "SELECT name, enabled, datetime(next_run_at) as next, datetime(last_run_at) as last, consecutive_failures as fails FROM cron_jobs ORDER BY enabled DESC, name;"

# Database stats
sqlite3 "$DB" "SELECT (SELECT COUNT(*) FROM sessions) as sessions, (SELECT COUNT(*) FROM events) as events, (SELECT COUNT(*) FROM logs) as logs, (SELECT printf('\$%.2f', COALESCE(SUM(total_cost),0)) FROM sessions) as total_cost;"
```

## When to Use What

| Skill | Use For |
|-------|---------|
| **self-inspect** | Everything about the Tron installation state |
| **self-deploy** | Deploying, restarting, rolling back the server |
| **manage-automations** | Creating/editing cron jobs |

## Gotchas
