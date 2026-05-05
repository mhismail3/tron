---
name: "Manage Automations"
description: "Create, update, and delete scheduled automations (cron jobs) via direct file editing"
version: "1.0.0"
tags: [automations, cron, scheduling, jobs]
---

# Manage Automations

Manage scheduled automations (cron jobs) stored in AUTOMATIONS. The scheduler watches this file (polling every 5 seconds via SHA256 fingerprint) and auto-reconciles on change — no restart needed.

## Paths

All paths below are derived from the Constitution path reference (AUTOMATIONS = `~/.tron/workspace/automations/`).

| Alias | Path |
|-------|------|
| AUTOMATIONS | `~/.tron/workspace/automations/` |
| AUTOMATIONS_JSON | `~/.tron/workspace/automations/automations.json` |

Use the standard **Read**, **Write**, and **Edit** tools to manage the file directly. Always use the absolute path AUTOMATIONS_JSON.

## Before Creating or Updating

Use **AskUserQuestion** to confirm anything the user hasn't specified:

- **Schedule**: What time/frequency? What timezone? (Default to user's local timezone, not UTC)
- **Payload type**: Shell command vs agent turn vs webhook?
- **Specific payload details**: What command to run? What prompt for the agent?
- **Delivery**: Should results be pushed to their phone (apns), shown silently, or sent to a webhook?
- **Failure handling**: What to do on overlap or misfire?

Only skip asking if the user has been completely explicit about all parameters.

## File Schema

```json
{
  "version": 1,
  "jobs": [
    {
      "id": "cron_<uuid_v7>",
      "name": "Job Name",
      "description": "Optional description",
      "enabled": true,
      "schedule": { },
      "payload": { },
      "delivery": [ ],
      "overlapPolicy": "skip",
      "misfirePolicy": "skip",
      "maxRetries": 0,
      "autoDisableAfter": 0,
      "stuckTimeoutSecs": 7200,
      "tags": [],
      "workspaceId": null,
      "createdAt": "2026-01-01T00:00:00Z",
      "updatedAt": "2026-01-01T00:00:00Z"
    }
  ]
}
```

### CronJob Fields

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `id` | string | yes | — | `cron_{uuid_v7}` — generate with `uuidgen` or similar |
| `name` | string | yes | — | Must be non-empty and unique across all jobs |
| `description` | string | no | null | Optional human-readable description |
| `enabled` | bool | no | true | Disabled jobs are skipped by the scheduler |
| `schedule` | object | yes | — | See Schedule Types below |
| `payload` | object | yes | — | See Payload Types below |
| `delivery` | array | no | [] | See Delivery Options below. Empty = silent |
| `overlapPolicy` | string | no | "skip" | `"skip"` or `"allow"` — what to do if previous run still in progress |
| `misfirePolicy` | string | no | "skip" | `"skip"` or `"runOnce"` — what to do on missed schedules (server was down) |
| `maxRetries` | number | no | 0 | Retry count on failure |
| `autoDisableAfter` | number | no | 0 | Disable after N consecutive failures (0 = never) |
| `stuckTimeoutSecs` | number | no | 7200 | Kill runs exceeding this duration (default 2 hours) |
| `tags` | string[] | no | [] | Arbitrary tags for filtering |
| `workspaceId` | string | no | null | Scope to a workspace |
| `createdAt` | string | yes | — | ISO 8601 UTC timestamp |
| `updatedAt` | string | yes | — | ISO 8601 UTC timestamp |

## Schedule Types

### Cron (`type: "cron"`)

Standard 5-field cron expression with IANA timezone.

```json
{ "type": "cron", "expression": "0 9 * * 1-5", "timezone": "America/New_York" }
```

- **expression**: `minute hour day-of-month month day-of-week` (5-field standard)
- **timezone**: IANA timezone (e.g. `America/New_York`, `Europe/London`). Defaults to UTC. Do NOT use abbreviations like `EST`.

Common patterns:
- `0 9 * * 1-5` — weekdays at 9am
- `*/15 * * * *` — every 15 minutes
- `0 0 1 * *` — first of every month at midnight
- `30 8 * * 1` — Mondays at 8:30am

### Interval (`type: "every"`)

Fixed interval in seconds. Minimum 10 seconds.

```json
{ "type": "every", "intervalSecs": 3600 }
```

- **intervalSecs**: seconds between runs (>= 10)
- **anchor** (optional): ISO 8601 datetime to anchor intervals to

### One-shot (`type: "at"`)

Fire once at a specific time, then auto-disable.

```json
{ "type": "at", "at": "2026-03-01T12:00:00Z" }
```

- **at**: ISO 8601 datetime (UTC)

## Payload Types

### Agent Turn (`type: "agentTurn"`)

Run an isolated agent session with a prompt. Most powerful — can use all tools.

```json
{
  "type": "agentTurn",
  "prompt": "Summarize today's logs and notify me of any errors"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `prompt` | string | yes | Must be non-empty. Write clear, detailed prompts — the agent runs without user interaction |
| `model` | string | no | Override model (defaults to server default) |
| `workspaceId` | string | no | Scope to workspace for context |
| `systemPrompt` | string | no | Custom system prompt |

### Shell Command (`type: "shellCommand"`)

Execute a shell command.

```json
{
  "type": "shellCommand",
  "command": "brew update && brew upgrade",
  "workingDirectory": "~",
  "timeoutSecs": 600
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `command` | string | yes | Must be non-empty |
| `workingDirectory` | string | no | Defaults to home directory |
| `timeoutSecs` | number | no | Default 300, max 3600 |

### Webhook (`type: "webhook"`)

Make an HTTP request.

```json
{
  "type": "webhook",
  "url": "https://api.example.com/trigger",
  "method": "POST",
  "headers": { "Authorization": "Bearer ..." },
  "body": "{\"key\": \"value\"}"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `url` | string | yes | Must be a valid URL |
| `method` | string | no | GET, POST, PUT, PATCH, DELETE (default POST) |
| `headers` | object | no | Key-value header pairs |
| `body` | string | no | Request body |
| `timeoutSecs` | number | no | Default 30, max 300 |

### System Event (`type: "systemEvent"`)

Inject a message into an existing session.

```json
{
  "type": "systemEvent",
  "sessionId": "sess_...",
  "message": "Reminder: check deployment status"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sessionId` | string | yes | Must be non-empty, session must exist |
| `message` | string | yes | Must be non-empty |

## Delivery Options

Array of delivery targets. Empty array or omitted = silent (log only).

### Silent (default)

```json
{ "type": "silent" }
```

### WebSocket

Push result to connected clients in real-time.

```json
{ "type": "websocket" }
```

### APNS (Push Notification)

Send push notification to user's phone.

```json
{ "type": "apns" }
```

Optional: `"title"` for a custom notification title.

### Webhook

POST result to a URL.

```json
{ "type": "webhook", "url": "https://hooks.example.com/cron-results" }
```

Optional: `"headers"` for custom headers.

**Examples:**
- Silent: `[]` or omit entirely
- Push + WebSocket: `[{"type": "apns"}, {"type": "websocket"}]`
- Webhook: `[{"type": "webhook", "url": "https://..."}]`

## Automation I/O Directory

All files produced or consumed by automation jobs — output logs, result artifacts, intermediate data, scripts, and working files — must be organized under AUTOMATIONS.

### Structure

Use one subdirectory per job, named after the job's `id` or a short slug derived from the job `name`:

```
AUTOMATIONS/
  <job-slug>/
    output/        # Result files written by the job (reports, exports, etc.)
    logs/          # Any plain-text logs or summaries the job writes
    state/         # Persistent state the job reads/writes between runs
    scripts/       # Shell scripts or helper files the job invokes
```

Only create subdirectories that are actually needed — a simple job may only need `output/`.

### Rules

- **Agent turn prompts** that produce file output must write to `AUTOMATIONS/<job-slug>/output/`.
- **Shell commands** must write any output files or logs to `AUTOMATIONS/<job-slug>/` — not to arbitrary tmp paths or the home directory.
- **State files** (e.g., last-run cursors, seen IDs, counters) live in `AUTOMATIONS/<job-slug>/state/`.
- **Scripts** invoked by `shellCommand` payloads should be stored in `AUTOMATIONS/<job-slug>/scripts/` so they are co-located with the job.
- The directory must be created before the job runs. Add `mkdir -p AUTOMATIONS/<job-slug>/output` (and other needed subdirs) to the beginning of any shell command, or include it in the agent turn prompt.

### Naming output files

Use timestamped filenames so runs don't overwrite each other:

```bash
AUTOMATIONS/<job-slug>/output/$(date +%Y-%m-%d_%H-%M-%S).txt
```

For state files that must persist a single value across runs, use a fixed filename (e.g., `last_seen.json`).

## CRUD Workflow

### Read (list all automations)

```
Read AUTOMATIONS_JSON
```

### Create

1. Read the file to get current state
2. Generate a new ID: `cron_<uuid_v7>` (use `uuidgen` or similar)
3. Add the new job to the `jobs` array with `createdAt` and `updatedAt` set to current ISO 8601 UTC time
4. Write the file back
5. Scheduler picks up the change within 5 seconds

### Update

1. Read the file
2. Find the job by `id`
3. Modify the desired fields
4. Update `updatedAt` to current ISO 8601 UTC time
5. Write the file back

### Delete

1. Read the file
2. Filter out the job by `id`
3. Write the file back
4. Run history is preserved in the database

## Validation Rules

The scheduler validates on reload. Invalid jobs are rejected:

- Job name must be non-empty
- Cron expression must be valid 5-field (minute hour dom month dow)
- Timezone must be valid IANA (e.g. `America/New_York`, not `EST`)
- Interval must be >= 10 seconds
- Shell command must be non-empty, timeout max 3600s
- Webhook URL must be valid, method must be GET/POST/PUT/PATCH/DELETE, timeout max 300s
- System event: session_id and message must be non-empty
- Agent turn: prompt must be non-empty
- Job names must be unique

## Run History

Query run history via the `tron-db` skill:

```sql
SELECT id, job_name, status, started_at, completed_at, duration_ms, error
FROM cron_runs WHERE job_id = ? ORDER BY started_at DESC LIMIT 20;
```

## Triggering Immediate Execution

Create a one-shot job with `at` set to the current time (or a few seconds in the future). The scheduler picks it up on the next tick and runs it immediately. After execution, one-shot jobs auto-disable.

## Best Practices

- Check existing automations before creating duplicates
- Confirm with the user before deleting — run history is preserved but the job config is gone
- After creating, summarize what was created: name, human-readable schedule, payload type
- For `agentTurn` payloads, write clear, detailed prompts — the agent session runs without user interaction
- Prefer cron expressions with timezones for time-of-day schedules; use interval for polling-style jobs
- Default to the user's local timezone, not UTC
- **All job I/O goes in `AUTOMATIONS/<job-slug>/`** — never scatter output to tmp dirs, home dir, or ad-hoc paths. Create the directory structure as part of job setup.

## Gotchas
