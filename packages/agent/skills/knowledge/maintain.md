# Knowledge Maintenance Workflow

Health-checking, self-healing, and organization. Running maintenance is always safe and idempotent.

Read WIKI_RULES before starting. Paths are defined in the skill's Paths table.

---

## Lint (Health Check)

Run all checks in order. Collect findings into a report. Apply auto-fixes per the scope rules below.

### Auto-Fix Scope

| Category | Auto-fix? |
|---|---|
| Index rebuild (missing entries, stale entries, missing file) | **Yes, always** — index is a rebuildable cache |
| Log recovery (missing or truncated WIKI_LOG) | **Yes, always** — create/repair header |
| Missing frontmatter fields (type, created, updated) | **Yes** — infer from directory and file timestamps |
| Filename convention violations | **Report only** — renaming has backlink implications |
| Orphan notes (no inbound wikilinks) | **Report only** — suggest where to add links |
| Dangling wikilinks (target doesn't exist) | **Report only** — could be intentional future pages |
| Contradictions between notes | **Report only** — requires human judgment |
| Stale notes (not updated in 90+ days on evolving topics) | **Report only** — suggest sources to check |

### Check 1: Schema Compliance

Scan all `.md` files in WIKI_SOURCES, WIKI_TOPICS, and WIKI_ARGUMENTS (skip rules.md, index.md, log.md).

For each note:
- Has YAML frontmatter?
- Has `type` field? (auto-fix: infer from directory — `sources/` → `source`, `topics/` → `topic`, `arguments/` → `argument`)
- Has `created`? (auto-fix: use file modification time)
- Has `updated`? (auto-fix: use file modification time)
- Has `tags`? (report if missing, don't auto-fix — tags need thought)
- Filename matches naming conventions for its type?
- Arguments should reference at least 2 topics in their `topics` frontmatter (warning if not)
- Arguments should have a `## Thesis` section (warning if missing)

### Check 2: Index Rebuild

Compare WIKI_INDEX against actual files on disk.

```
Find *.md in WIKI_SOURCES
Find *.md in WIKI_TOPICS
Find *.md in WIKI_ARGUMENTS
```

- Files on disk not in index → **add** (read frontmatter for one-line summary)
- Index entries for deleted files → **remove**
- If WIKI_INDEX missing → **rebuild from scratch**
- Bump `updated`, recalculate `page_count`
- Index rebuild must include Arguments section with correct count

Always auto-fix — the index is a cache.

### Check 3: Orphan Detection

For each note in the index, search for `[[note-slug]]` across all knowledge files (excluding index.md).

Notes with zero inbound wikilinks are orphans.

Report: list orphans with their type. Suggest which existing notes could link to them based on shared tags or related content.

### Check 4: Dangling References

Search all files for `[[wikilink]]` patterns:
```
Search for "\[\[[^\]]+\]\]" in WIKI_ROOT
```

For each unique wikilink target, check if a file with that slug exists in WIKI_SOURCES, WIKI_TOPICS, or WIKI_ARGUMENTS.

Report: list dangling references with the file that contains them.

### Check 5: Contradiction Scan

Read topic notes that share tags or wikilinks. Flag cases where notes make opposing claims without acknowledging each other.

Report only — contradictions are valuable signals, not errors.

### Check 6: Staleness

Find topic notes where `updated` is more than 90 days old and the topic is likely evolving (technology, current events, active research areas).

Report: list stale notes with last updated date. Suggest searching for recent developments.

### Check 7: Log Continuity

- If WIKI_LOG missing → create with `# Knowledge Log` header
- If WIKI_LOG exists but empty or no header → prepend header

### Lint Report

```markdown
# Knowledge Lint Report — YYYY-MM-DD

## Schema Compliance
- N notes checked, M issues found
- [list auto-fixes applied]
- [list issues requiring attention]

## Index
- N entries synced, M added, K removed

## Orphans (N)
- [[slug]] — suggested link targets: ...

## Dangling References (N)
- [[missing-slug]] referenced in: file1.md, file2.md

## Contradictions (N)
- [[note-a]] vs [[note-b]] — brief description

## Staleness (N)
- [[slug]] — last updated YYYY-MM-DD

## Actions Taken
- [list of auto-fixes applied]
```

Append to WIKI_LOG:
```
2026-04-07T15:00:00Z | lint | report | — | N issues, M auto-fixed
```

---

## Organize

Manual reorganization operations. Use when the user asks to restructure, rename, merge, or clean up.

### Move a note

After moving, search for `[[old-slug]]` across WIKI_ROOT and update all wikilinks.

### Rename a note

Same as move — rename the file, then update all `[[old-slug]]` references to `[[new-slug]]`.

### Split a note

If a topic note covers multiple distinct concepts:
1. Read the note
2. Create new notes for each concept
3. Update the original to reference the new notes
4. Update backlinks

### Merge duplicate notes

1. Read both notes
2. Combine content, keeping the best of each
3. Write merged content to one path
4. Delete the other
5. Update all backlinks to point to the survivor

### Add/update tags

Use `filesystem::edit_file` to modify frontmatter. Keep tags consistent across the knowledge base — check what tags already exist before inventing new ones.

---

## Git Commit

After any maintenance operation, commit:

```bash
cd WIKI_ROOT && git add -A && git commit -m "knowledge: maintain — {description}"
```

## Gotchas
