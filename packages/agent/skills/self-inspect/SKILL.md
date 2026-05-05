---
name: "Self Inspect"
description: "Inspect Tron database, settings, auth, skills, runtime locks, health, and all ~/.tron/ state via direct sqlite3 queries and file reads. Trigger on 'debug this session', 'what went wrong', 'why did that fail', 'inspect my last turns', 'what just happened', 'debug this chat' — diagnose the current live session's errors, failed tools, and anomalies, then write a diagnostic report to ~/.tron/workspace/reports/"
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
| Settings | `sed -n '/^\[settings\]/,$p' ~/.tron/profiles/user/profile.toml` |
| Auth providers | `cat ~/.tron/profiles/auth.json \| jq 'del(.. \| .accessToken?, .refreshToken?, .apiKey?, .clientSecret?)'` |

## ~/.tron/ Directory Layout

```
~/.tron/
├── internal/                      # Runtime state, DB, locks, journals
│   ├── database/log.db            # Main SQLite database
│   ├── run/                       # .onboarded, updater-state.json, locks
│   └── transcription/             # Speech-to-text sidecar
├── profiles/                      # Agent execution specs and built-in auth
│   ├── active.toml
│   ├── auth.toml
│   ├── auth.json                  # OAuth tokens, API keys, bearerToken
│   ├── default/
│   └── user/
├── skills/                        # Installed skills (SKILL.md per skill)
├── memory/                        # Durable user/world/environment continuity
└── workspace/                     # Active work, artifacts, experiments
    ├── automations/
    ├── knowledge/
    └── vault/
```

## Quick Access

```bash
DB="$HOME/.tron/internal/database/log.db"

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
