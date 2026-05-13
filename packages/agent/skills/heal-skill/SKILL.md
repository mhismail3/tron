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
| "heal all skills" | Iterate every skill in both `~/.tron/skills/` and `~/.claude/skills/` (Tron scans both) |

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

**Available capability contracts:**

| Category | Capability contracts |
|----------|----------------------|
| Filesystem | `filesystem::read_file`, `filesystem::write_file`, `filesystem::edit_file`, `filesystem::find` |
| Process | `process::run`, `process::start_job`, `process::wait`, `process::cancel` |
| Search | `filesystem::search_text`, `capability::search` |
| Web | `web::fetch`, `web::search` |
| Interactive | `agent::ask_user`, `agent::request_approval`, `display::show`, `browser::computer_action`, `notifications::send` |
| Agent | `agent::spawn_subagent`, `sandbox::spawn_worker`, `sandbox::stop_spawned_worker` |
| Plugin sources | MCP/OpenAPI capabilities appear as normal plugin-provided implementations discovered through `capability::search` and invoked through `capability::execute`. |

**Import translation table:**

| External name | Tron equivalent | Notes |
|--------------|-----------------|-------|
| `Grep` / `rg` | `filesystem::search_text` | Search across file contents through the filesystem capability plugin |
| `Glob` | `filesystem::find` | File discovery is owned by the filesystem capability plugin |
| `Agent` / `Subagent` | `agent::spawn_subagent` | |
| `TodoWrite` / `TodoRead` | *(remove)* | Not available in Tron |
| `WebBrowser` / `Browser` | `ComputerUse` | Screenshot, click, type, scroll |
| `Cat` / `Head` / `Tail` | `Read` | |
| `Sed` / `Awk` | `Edit` | |
| `NotebookEdit` | *(remove)* | Not available in Tron |
| `TaskCreate` / `TaskUpdate` | *(remove)* | Not available in Tron |

### 5. Validate Path References

Check all `~/.tron/` paths in the skill content against the **PATH REFERENCE** table in the profile-backed core prompt. That table is the model-visible summary of the current directory layout.

Do not maintain a second translation table inside the skill. If a skill contains a path that disagrees with the prompt's **PATH REFERENCE** table or `core::foundation::paths`, replace it with the canonical named path from that source of truth. Remove obsolete production-artifact, deployment, and pre-profile-first home references instead of translating them ad hoc.

### 6. Validate Database References

If the skill contains SQL queries or references database tables, verify against the actual schema.

**Existing tables** (in `~/.tron/internal/database/log.db`):
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

### 9. Validate Gotchas Section

Every skill file (SKILL.md and sub-files with procedural content) must have a `## Gotchas` section as its **final** `##`-level section. Router-only SKILL.md files (those that just direct to sub-files) and pure reference tables are exempt.

**Check:** `grep -c '## Gotchas' <file>`

**If missing:**
1. Scan the file for inline warnings, edge case tables, "Critical"/"Important" notes.
2. Extract 2-5 non-obvious behaviors as bullet points.
3. Append a `## Gotchas` section at the end of the file with those bullets.
4. If nothing extractable: `- No known gotchas yet. Update this section as edge cases are discovered.`

**If present:**
- Verify it contains at least one bullet point (not empty).
- Verify it is the last `##`-level section in the file.
- If not last, move it to the end.

### 10. Preflight & Self-Sufficiency Check

Every skill should be able to set itself up from scratch without asking the user. Check for and add the following if missing:

**A. Dependency installation**

If the skill relies on any CLI tool, binary, or brew formula, it must check for it and install if absent:

```bash
# Pattern — check then install
if ! command -v <tool> &>/dev/null; then
  brew install <formula>
fi
```

Add this to a clearly labeled `## Setup` or `## Preflight` section in the skill.

**B. Auth / credentials**

If the skill requires authentication:
- Check if credentials are already stored in the vault under a well-known name.
- If yes, document the vault key and show how to retrieve them:
  ```bash
  ~/.tron/skills/vault/scripts/vault.sh get <vault-name> --field <field>
  ```
- If credentials are not in the vault yet, the skill should prompt Tron to ask the user for them once and store them via the vault skill — **not** require the user to configure things manually every time.
- Never hardcode credentials in skill files.

**C. Directory / file structure**

If the skill writes state to disk (e.g., under `~/.tron/workspace/scratch/<name>/`), it must `mkdir -p` that path before first use.

**D. Idempotency**

All preflight steps must be safe to run repeatedly. A second run should detect everything is already in place and proceed silently.

**What to add when healing:**

If the skill is missing a preflight section, add one. Model it on the vault skill's pattern:
1. Check each dependency (binary, brew formula, directory, vault entry).
2. Auto-fix anything that can be auto-fixed (install, mkdir).
3. For anything requiring user input (first-time credentials), guide Tron to collect and vault them, then continue.
4. Output clear pass/fail status so future runs can confirm the environment is ready.

### 12. Import-Specific Conversions

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

### 13. Apply Fixes

After analysis, rewrite the skill files:
1. Fix frontmatter (add missing fields, rename invalid keys, fix values)
2. Update all stale paths
3. Replace invalid tool names
4. Remove references to non-existent tables/files
5. Fix SQL queries
6. Clean up content structure
7. Add or fix `## Gotchas` section (must be last `##`-level section)

### 14. Verify

After healing, re-read and confirm:
- Frontmatter parses correctly (all recognized keys present)
- No stale paths remain
- No invalid tool names remain
- All referenced files exist
- SQL queries target correct DB and valid tables
- `## Gotchas` section present and is last `##`-level section

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
  [FAIL] ~/.tron/database/tron.db → should be ~/.tron/internal/database/log.db
  [PASS] ~/.tron/skills/ is current

Database:
  [FAIL] Query references "memory_vectors" table (does not exist)
  [PASS] "sessions" table exists

Files:
  [FAIL] Routing table references "reference/api.md" but file does not exist
  [PASS] "reference/schema.md" exists

Preflight:
  [FAIL] No preflight/setup section found → added dependency check and vault credential retrieval
  [FAIL] CLI tool "tron-twitter" used but no install check → added brew install guard
  [WARN] Auth required but no vault integration → added vault lookup for "twitter-account"
  [PASS] State directory created with mkdir -p

Gotchas:
  [PASS] ## Gotchas present (5 bullets), last section
  -- or --
  [FAIL] No ## Gotchas section → added with 3 extracted bullets
  [WARN] ## Gotchas is empty → added placeholder bullet
  [WARN] ## Gotchas is not the last section → moved to end

Fixes applied: 4
Warnings: 2
```

## Gotchas
