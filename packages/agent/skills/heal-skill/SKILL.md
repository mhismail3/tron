---
name: "Heal Skill"
description: "Validate, fix, and adapt skills to conform to Tron's format, tools, directory layout, and conventions — works on existing skills and external imports"
version: "1.0.0"
tags: [maintenance, skills, validation, import]
---

Analyze, validate, and fix Tron skills. Use this when:
- A first-party skill is outdated (references old paths, dead tables, removed tools)
- A third-party skill needs adaptation to Tron's format
- Importing a skill from Claude Code, generic markdown, or another agent framework
- Bulk-healing all installed skills

## Procedure

### 1. Identify Target

| User says | Action |
|-----------|--------|
| "heal `@X`" / "fix `@X`" / "validate `@X`" | Heal the named skill |
| "import skill from `<path>`" | Copy to `~/.tron/skills/<name>/`, then heal |
| "heal all skills" | Iterate every skill in `~/.tron/skills/` |

### 2. Read Everything

```bash
# Read the skill's SKILL.md
cat ~/.tron/skills/<name>/SKILL.md

# List all files in the skill directory
ls -R ~/.tron/skills/<name>/

# Read every sub-file (.md files, scripts, etc.)
```

### 3. Validate Frontmatter

The Rust parser (`skills/discovery/parser.rs`) recognizes ONLY these keys:

| Key | Type | Required | Notes |
|-----|------|----------|-------|
| `name` | string | Yes | Should match folder name (lowercase, hyphenated) |
| `description` | string | Yes | 1-2 sentences, under 200 chars for iOS display |
| `version` | string | Recommended | Semver (e.g., `"1.0.0"`) |
| `tags` | string[] | Recommended | For discovery and categorization |
| `allowedTools` | string[] | Optional | Preferred tools (prompt guidance, not enforced) |
| `deniedTools` | string[] | Optional | Forbidden tools (prompt guidance, not enforced) |
| `subagent` | enum | Optional | `yes` / `ask` / `no` |
| `subagentModel` | string | Optional | Model override for subagent execution |

**Common mistakes to fix:**
- `tools:` key → **silently ignored by parser**. Convert to `allowedTools:` if intent is to declare tool preferences
- `tool:` (singular) → ignored. Convert to `allowedTools:`
- Missing `---` fences → frontmatter not parsed at all
- Unclosed frontmatter (no closing `---`) → entire file treated as body, no metadata
- `subagent: true` → should be `subagent: yes`

**Array formats** (both valid):
```yaml
tags: [tag1, tag2, tag3]
# or
tags:
  - tag1
  - tag2
  - tag3
```

### 4. Validate Tool References

Tools referenced in `allowedTools`, `deniedTools`, or in the skill content must be valid Tron tool names.

**Available tools:**

| Category | Tools |
|----------|-------|
| Filesystem | `Read`, `Write`, `Edit`, `Find` |
| System | `Bash` |
| Search | `Search` |
| Web | `WebFetch`, `WebSearch` |
| Interactive | `AskUserQuestion`, `GetConfirmation`, `Display`, `ComputerUse`, `NotifyApp` |
| Subagent | `SpawnSubagent`, `WaitForAgents` |
| MCP | `McpSearch`, `McpCall` |

**Import translation table:**

| External name | Tron equivalent | Notes |
|--------------|-----------------|-------|
| `Grep` / `rg` | `Search` | Tron's Search covers grep, ripgrep, AST search |
| `Glob` | `Find` | Tron's Find covers glob/file pattern matching |
| `Agent` / `Subagent` | `SpawnSubagent` | |
| `TodoWrite` / `TodoRead` | *(remove)* | Not available in Tron |
| `WebBrowser` / `Browser` | `ComputerUse` | Screenshot, click, type, scroll |
| `Cat` / `Head` / `Tail` | `Read` | |
| `Sed` / `Awk` | `Edit` | |
| `NotebookEdit` | *(remove)* | Not available in Tron |
| `TaskCreate` / `TaskUpdate` | *(remove)* | Not available in Tron |

### 5. Validate Path References

Check all `~/.tron/` paths in the skill content against the current directory layout.

**Current layout** (anything else is stale):

| Correct path | Purpose |
|-------------|---------|
| `~/.tron/system/bin/tron` | Server binary |
| `~/.tron/system/auth.json` | OAuth tokens and API keys |
| `~/.tron/system/settings.json` | Configuration |
| `~/.tron/system/db/log.db` | Main SQLite database |
| `~/.tron/system/deployment/` | Deploy scripts and state |
| `~/.tron/system/mods/` | Optional modules (apns, google, transcribe, twitter) |
| `~/.tron/skills/` | Installed skills |
| `~/.tron/memory/rules/` | System rules (SYSTEM.md) |
| `~/.tron/memory/knowledge/` | Knowledge base |
| `~/.tron/memory/sessions/` | Session notes |
| `~/.tron/memory/cron/` | Cron working files |
| `~/.tron/memory/scratch/` | Temporary files |
| `~/.tron/user/voice/` | Voice I/O |

**Stale path translations:**

| Old path | Current path |
|----------|-------------|
| `~/.tron/database/tron.db` | `~/.tron/system/db/log.db` |
| `~/.tron/settings.json` | `~/.tron/system/settings.json` |
| `~/.tron/auth.json` | `~/.tron/system/auth.json` |
| `~/.tron/tron` (binary) | `~/.tron/system/bin/tron` |
| `~/.tron/mods/` | `~/.tron/system/mods/` |
| `~/.tron/artifacts/` | `~/.tron/system/deployment/` |
| `~/.tron/artifacts/deployment/` | `~/.tron/system/deployment/` |
| `~/.tron/knowledge/` | `~/.tron/memory/knowledge/` |
| `~/.tron/database/` | `~/.tron/system/db/` |

### 6. Validate Database References

If the skill contains SQL queries or references database tables, verify against the actual schema.

**Existing tables** (in `~/.tron/system/db/log.db`):
`sessions`, `events`, `blobs`, `branches`, `logs`, `workspaces`, `cron_jobs`, `cron_runs`, `device_tokens`, `notification_read_state`, `schema_version`

**Tables that do NOT exist** (remove any references):
`tasks`, `projects`, `areas`, `task_dependencies`, `task_activity`, `task_backlog`, `memory_vectors`, `events_fts`, `logs_fts`

**Columns that do NOT exist:**
- `cron_jobs.prod_only` — removed

### 7. Validate File References

Check that any sub-files referenced in routing tables or content actually exist:

```bash
# For each referenced file path in the skill content
ls ~/.tron/skills/<name>/<referenced-file>
```

### 8. Content Structure Check

For skills with multiple files:
- SKILL.md should have a routing table directing to sub-files
- Sub-files should be at depth 1 (no nested subdirectories beyond `reference/`)
- All `.md` files appear in the iOS app's `additionalFiles` list

For single-file skills:
- Content should be self-contained
- Clear sections with headers

### 9. Import-Specific Conversions

**From Claude Code plugins:**
- `~/.claude/` paths → `~/.tron/` equivalents
- Strip Claude Code-specific instructions (permission modes, hook formats, `CLAUDE.md` references)
- Convert tool names per translation table above
- `slash_command` / `command` → not applicable, remove or convert to skill instructions
- Plugin `settings.json` / `plugin.json` → not applicable, extract useful config into skill content

**From generic markdown instructions:**
- Wrap in `---` frontmatter fences
- Infer `name` from filename or first heading
- Infer `description` from first paragraph
- Infer `tags` from content keywords
- Identify tool dependencies and add to `allowedTools`
- If complex, restructure into routing table + sub-files

### 10. Apply Fixes

After analysis, rewrite the skill files:
1. Fix frontmatter (add missing fields, rename invalid keys, fix values)
2. Update all stale paths
3. Replace invalid tool names
4. Remove references to non-existent tables/files
5. Fix SQL queries
6. Clean up content structure

### 11. Verify

After healing, re-read and confirm:
- Frontmatter parses correctly (all recognized keys present)
- No stale paths remain
- No invalid tool names remain
- All referenced files exist
- SQL queries target correct DB and valid tables

## Example Report Format

```
=== Skill Health Report: <name> ===

Frontmatter:
  [PASS] name: "My Skill"
  [PASS] description: present (127 chars)
  [FAIL] tools: key ignored by parser → convert to allowedTools
  [WARN] version: missing (recommended)
  [WARN] tags: missing (recommended)

Tools:
  [FAIL] References "Grep" → should be "Search"
  [PASS] "Bash" is valid

Paths:
  [FAIL] ~/.tron/database/tron.db → should be ~/.tron/system/db/log.db
  [PASS] ~/.tron/skills/ is current

Database:
  [FAIL] Query references "memory_vectors" table (does not exist)
  [PASS] "sessions" table exists

Files:
  [FAIL] Routing table references "reference/api.md" but file does not exist
  [PASS] "reference/schema.md" exists

Fixes applied: 4
Warnings: 2
```
