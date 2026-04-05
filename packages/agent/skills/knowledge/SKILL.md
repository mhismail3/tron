---
name: "Knowledge"
description: "Maintain a persistent knowledge base — save research, extract from URLs, search notes, organize by topic"
version: "1.0.0"
tags: [knowledge, notes, research, vault]
---

# Knowledge

Maintain a persistent knowledge base at `~/.tron/workspace/knowledge/`. Notes are plain Markdown files with optional YAML frontmatter. Use your standard tools — Read, Write, Edit, Find, Search — to manage everything directly.

## Knowledge folder

```
~/.tron/workspace/knowledge/
  sources/       -- one note per URL (articles, papers, tweets)
  topics/        -- one note per atomic concept (grows over time)
  arguments/     -- synthesis notes connecting topics
  references/    -- bookmarks, links, quick-reference material
  voice-notes/   -- transcribed voice recordings (managed by iOS)
```

Create subdirectories as needed. The structure above is a starting point, not a constraint.

## Routing table

Match user intent to the correct reference file. **Read the file** before executing the workflow.

| User wants... | Read file |
|---|---|
| Save a URL, extract knowledge from a link | `extract.md` |
| Deep research on a topic (multi-round, autonomous) | `research.md` |
| Find information, search across notes | `search.md` |
| Reorganize, tag, rename, clean up notes | `organize.md` |
| Save a quick fact, reference, or preference | `save.md` |

If a URL is provided, default to **extract**. For broad "research X for me" requests, use **research**. If the user is asking about existing notes, default to **search**.

## Quick operations

For simple operations that don't need a sub-file:

### Save a quick note

```
Write to: ~/.tron/workspace/knowledge/{category}/{slug}.md
```

Include frontmatter:

```yaml
---
type: fact|reference|topic|source
tags: [relevant, tags]
created: "YYYY-MM-DD"
updated: "YYYY-MM-DD"
---
```

### Search notes

```
# Full-text search
Search for "query" in ~/.tron/workspace/knowledge/

# Find all notes in a category
Find *.md in ~/.tron/workspace/knowledge/topics/

# Find by tag
Search for "tags:.*tagname" in ~/.tron/workspace/knowledge/
```

### Read a note

```
Read: ~/.tron/workspace/knowledge/{category}/{slug}.md
```

## When to save knowledge

Save proactively when you encounter:
- Research findings, patterns, or techniques discovered during work
- Facts, preferences, or context the user shares
- Synthesized understanding that emerged from a conversation
- References, links, or resources worth keeping

Don't save:
- Session-specific actions (the memory ledger handles that)
- Temporary scratch work
- Information already in the memory ledger

The memory ledger captures *what happened*. Knowledge captures *what's true*.

## Frontmatter conventions

All notes use YAML frontmatter between `---` fences. Required fields vary by type:

| Field | Required | Description |
|-------|----------|-------------|
| `type` | Yes | `source`, `topic`, `argument`, `fact`, `reference`, `voice` |
| `tags` | No | Array of tags for discovery |
| `created` | No | ISO 8601 timestamp |
| `url` | Sources only | Original URL |
| `author` | Sources only | Author name |

## Wikilinks

Use `[[wikilinks]]` to connect notes:
- Source citation: `[[Author - Short Title]]`
- Topic link: `[[Topic Name]]`
- Cross-reference: `[[Any Note Name]]`

## Reference file paths

```
~/.tron/skills/knowledge/extract.md
~/.tron/skills/knowledge/research.md
~/.tron/skills/knowledge/search.md
~/.tron/skills/knowledge/organize.md
~/.tron/skills/knowledge/save.md
```
