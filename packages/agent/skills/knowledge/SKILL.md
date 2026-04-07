---
name: "Knowledge"
description: "LLM-maintained personal wiki — ingest URLs, capture session insights, deep research, search notes, lint for health, process Raindrop bookmarks"
version: "2.0.0"
tags: [knowledge, wiki, research, raindrop]
---

# Knowledge Wiki

A persistent, compounding knowledge base. The wiki is maintained by LLM agents — you curate sources and ask questions, the agent does the summarizing, cross-referencing, and bookkeeping.

## Paths

All paths below are derived from the system prompt's PATH REFERENCE. This section is the single source of truth for this skill.

| Alias | Path |
|-------|------|
| WIKI_ROOT | `~/.tron/workspace/knowledge/` |
| WIKI_SCHEMA | `~/.tron/workspace/knowledge/SCHEMA.md` |
| WIKI_INDEX | `~/.tron/workspace/knowledge/index.md` |
| WIKI_LOG | `~/.tron/workspace/knowledge/log.md` |
| WIKI_SOURCES | `~/.tron/workspace/knowledge/sources/` |
| WIKI_PAGES | `~/.tron/workspace/knowledge/wiki/` |
| AUTOMATIONS | `~/.tron/workspace/automations/` |

**Before any operation**, read WIKI_SCHEMA. The schema is the ground truth for conventions. If this skill and the schema disagree, the schema wins.

## Structure

```
WIKI_ROOT
  SCHEMA.md      # Ground truth — conventions, frontmatter, naming
  index.md       # Page catalog (rebuildable cache)
  log.md         # Operation log (append-only, observability)
  sources/       # What you read — one note per URL (dated snapshots)
  wiki/          # What you think — concepts, synthesis, references (living docs)
```

## Routing

Match user intent to the correct workflow file. **Read the file** before executing.

| User wants... | Read file |
|---|---|
| Ingest a URL, save a quick note, capture session insights, file an answer back | `ingest.md` |
| Deep multi-round autonomous research on a topic | `research.md` |
| Health-check, lint, reorganize, fix issues | `maintain.md` |
| Process Raindrop.io bookmarks, set up Raindrop automation | `raindrop.md` |

**Defaults:**
- URL provided → `ingest.md` (extract mode)
- "research X for me" → `research.md`
- "save this" mid-conversation → `ingest.md` (capture mode)
- "lint" / "health check" / "organize" → `maintain.md`
- "raindrop" / "bookmarks" → `raindrop.md`

## Search

When the user invokes `@knowledge search` or asks a question about wiki contents:

1. Read WIKI_INDEX for the full page catalog
2. Identify relevant entries from the index
3. Read those pages
4. If the index doesn't surface what you need, full-text search:
   ```
   Search for "query" in WIKI_ROOT
   ```
5. Follow wikilinks to discover connected notes
6. If WIKI_INDEX doesn't exist, skip to step 4 — the wiki still works without it

Synthesize an answer from the wiki pages. If the answer is particularly good, offer to file it back: "Want me to save this synthesis to the wiki?"

## Session Capture

Watch for high-value synthesis during conversations:
- Novel connections between ideas
- Conclusions that took significant reasoning
- Frameworks or mental models that crystallized

When you notice these, ask: **"Want me to save this to the wiki?"** Proceed only if the user confirms. Follow `ingest.md` capture mode.

Also triggered explicitly with `@knowledge capture` or "save this to the wiki".

## Epilogue — After Every Operation

Every operation that creates or modifies a note must:

1. **Update WIKI_INDEX** — read it, add/update the entry, bump `updated` and `page_count`. If missing, skip (lint rebuilds it).
2. **Append to WIKI_LOG** — one pipe-delimited line per note affected. If missing, create with `# Knowledge Log` header first.
3. **Git commit** — at the end of a session or cron run, commit all changes:
   ```bash
   cd WIKI_ROOT && git add -A && git commit -m "wiki: {operation} — {brief description}"
   ```
   Do not push unless asked.

## Reference Paths

```
WIKI_SCHEMA                                  # Ground truth
~/.tron/skills/knowledge/ingest.md          # Ingest, capture, save, fileback
~/.tron/skills/knowledge/research.md        # Deep autonomous research
~/.tron/skills/knowledge/maintain.md        # Lint, organize, health check
~/.tron/skills/knowledge/raindrop.md        # Raindrop.io integration
```
