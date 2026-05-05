---
name: "Knowledge"
description: "Source-topic knowledge base — ingest URLs, build living topic documents, deep research, lint for health, process Raindrop bookmarks"
version: "3.0.0"
tags: [knowledge, research, raindrop, topics]
---

# Knowledge Base

A persistent, compounding knowledge base built on two active layers: **sources** (what you read) and **topics** (what you know). **Arguments** (what you think) emerge from natural conversations and are created by the retain system — not by explicit skill invocation. The agent does the summarizing, cross-referencing, and bookkeeping — you curate sources and ask questions.

## Paths

All paths below are derived from the Constitution path reference. This section is the single source of truth for this skill.

| Alias | Path |
|-------|------|
| WIKI_ROOT | `~/.tron/workspace/knowledge/` |
| WIKI_RULES | `~/.tron/workspace/knowledge/rules.md` |
| WIKI_INDEX | `~/.tron/workspace/knowledge/index.md` |
| WIKI_LOG | `~/.tron/workspace/knowledge/log.md` |
| WIKI_SOURCES | `~/.tron/workspace/knowledge/sources/` |
| WIKI_TOPICS | `~/.tron/workspace/knowledge/topics/` |
| WIKI_ARGUMENTS | `~/.tron/workspace/knowledge/arguments/` |
| AUTOMATIONS | `~/.tron/workspace/automations/` |

**Before any operation**, read WIKI_RULES. The rules file is the ground truth for conventions. If this skill and the rules disagree, the rules win.

## Structure

```
WIKI_ROOT
  rules.md       # Ground truth — conventions, frontmatter, naming
  index.md       # Page catalog (rebuildable cache)
  log.md         # Operation log (append-only, observability)
  sources/       # What you read — one note per URL (immutable snapshots)
  topics/        # What you know — living knowledge documents
  arguments/     # What you think — synthesized connections between topics
```

## Routing

Match user intent to the correct workflow file. **Read the file** before executing.

| User wants... | Read file |
|---|---|
| Ingest a URL, save a quick note, capture session insights, file an answer back | `ingest.md` |
| Deep multi-round autonomous research on a topic | `research.md` |
| Health-check, lint, reorganize, fix issues | `maintain.md` |
| Process Raindrop.io bookmarks | `raindrop.md` |

**Defaults:**
- URL provided (http/https link in message) → `ingest.md` (extract mode)
- "research X for me" / "investigate" / "deep dive" → `research.md`
- "save this" mid-conversation → `ingest.md` (capture mode)
- "lint" / "health check" / "organize" → `maintain.md`
- "raindrop" / "bookmarks" / "process bookmarks" → `raindrop.md`

**Direct URL handling:** If the user's message contains a URL (http/https), route directly to `ingest.md` extract mode. The user should be able to just paste a link.

## Search

When the user asks a question about knowledge base contents:

1. Read WIKI_INDEX for the full page catalog
2. Identify relevant entries from the index
3. Read those pages
4. If the index doesn't surface what you need, full-text search:
   ```
   Search for "query" in WIKI_ROOT
   ```
5. Follow wikilinks to discover connected notes
6. If WIKI_INDEX doesn't exist, skip to step 4 — the knowledge base still works without it

Synthesize an answer from the pages. Arguments emerge naturally from conversations — the retain system captures them automatically when knowledge topics are discussed.

## Session Capture

Watch for high-value synthesis during conversations:
- Novel connections between ideas
- Conclusions that took significant reasoning
- Frameworks or mental models that crystallized

When you notice these, ask: **"Want me to save this to the knowledge base?"** Proceed only if the user confirms. Follow `ingest.md` capture mode.

## Epilogue — After Every Operation

Every operation that creates or modifies a note must:

1. **Update WIKI_INDEX** — read it, add/update the entry, bump `updated` and `page_count`. If missing, skip (lint rebuilds it).
2. **Append to WIKI_LOG** — one pipe-delimited line per note affected. If missing, create with `# Knowledge Log` header first. Log all decisions religiously for auditing.
3. **Git commit** — at the end of a session or cron run, commit all changes:
   ```bash
   cd WIKI_ROOT && git add -A && git commit -m "knowledge: {operation} — {brief description}"
   ```
   Do not push unless asked.

## Reference Paths

```
WIKI_RULES                                     # Ground truth
~/.tron/skills/knowledge/ingest.md            # Ingest, capture, save, fileback
~/.tron/skills/knowledge/research.md          # Deep autonomous research
~/.tron/skills/knowledge/maintain.md          # Lint, organize, health check
~/.tron/skills/knowledge/raindrop.md          # Raindrop.io integration
```
