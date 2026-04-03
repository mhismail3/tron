# Quick Save Workflow

Save a piece of knowledge quickly — a fact, reference, preference, or observation. For URL extraction, use `extract.md` instead.

## Workflow

### Step 1: Determine the note type

| Content | Type | Category |
|---|---|---|
| A factual claim, data point, or observation | `fact` | `topics/` or root |
| A link, bookmark, or external reference | `reference` | `references/` |
| A user preference, habit, or personal context | `fact` | `topics/` |
| A research finding or technique | `topic` | `topics/` |
| A thesis or synthesis connecting ideas | `argument` | `arguments/` |

### Step 2: Check for existing notes

```
Search for "<key terms>" in ~/.tron/memory/knowledge/
```

If a related note exists, update it with Edit rather than creating a duplicate.

### Step 3: Write the note

**Path:** `~/.tron/memory/knowledge/{category}/{slug}.md` — name by topic slug, no date prefix (these are living documents).

```markdown
---
topic: {slug}
type: {type}
tags: [{relevant}, {tags}]
created: "{YYYY-MM-DD}"
updated: "{YYYY-MM-DD}"
---

## {YYYY-MM-DD HH:MM} — {Title}

{Content — be specific and concrete. Include context that makes this useful later.}
```

When updating an existing knowledge file, bump `updated` in frontmatter and add a new `## YYYY-MM-DD HH:MM — Update title` section at the top (reverse chronological order).

### Guidelines

- Be specific. "User prefers Vim keybindings in all editors" is useful. "User likes Vim" is not.
- Include context. Why is this worth saving? What prompted it?
- Link to related notes with `[[wikilinks]]` when connections exist.
- One concept per note. If you're writing about two things, make two notes.
