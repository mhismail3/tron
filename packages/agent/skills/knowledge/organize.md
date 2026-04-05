# Knowledge Organization Workflow

Maintain, restructure, and clean up the knowledge base.

## Operations

### Move a note

```bash
mv ~/.tron/workspace/knowledge/old-category/note.md ~/.tron/workspace/knowledge/new-category/note.md
```

After moving, search for `[[Note Name]]` across the vault and update broken references if the display name changed.

### Rename a note

```bash
mv ~/.tron/workspace/knowledge/category/old-name.md ~/.tron/workspace/knowledge/category/new-name.md
```

Then search for `[[Old Name]]` and replace with `[[New Name]]` across the vault.

### Add/update tags

Use the Edit tool to modify frontmatter:

```yaml
---
tags: [existing-tag, new-tag]
---
```

### Split a note

If a note covers multiple distinct concepts:
1. Read the note
2. Identify the separate concepts
3. Create new notes for each concept (Write)
4. Update the original to reference the new notes
5. Move wikilinks from other notes to point to the correct split note

### Merge duplicate notes

1. Read both notes
2. Combine content, keeping the best of each
3. Write the merged content to one path
4. Delete the other
5. Update backlinks to point to the surviving note

### Create a new category

```bash
mkdir -p ~/.tron/workspace/knowledge/new-category/
```

### Audit for orphans

Find notes with no inbound wikilinks:

```
Find *.md in ~/.tron/workspace/knowledge/
```

For each note, check if any other note references it:
```
Search for "[[Note Name]]" in ~/.tron/workspace/knowledge/
```

Notes with zero backlinks may need better cross-referencing or may be candidates for removal.

## Naming conventions

- Use lowercase kebab-case for filenames: `topic-name.md`
- Source notes: `{author-last-name}-{short-title}.md`
- Topic notes: `{concept-name}.md`
- Argument notes: `{thesis-slug}.md`
- No spaces in filenames — use hyphens
