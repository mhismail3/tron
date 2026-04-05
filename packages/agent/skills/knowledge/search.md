# Knowledge Search Workflow

Find information across the knowledge base using a combination of file discovery and content search.

## Search strategies

### Full-text search

```
Search for "query terms" in ~/.tron/workspace/knowledge/
```

Use regex for flexible matching:
```
Search for "pattern|alternative" in ~/.tron/workspace/knowledge/
Search for "concept.*related" in ~/.tron/workspace/knowledge/
```

### Category-scoped search

Narrow to a specific category when you know the note type:
```
Search for "query" in ~/.tron/workspace/knowledge/sources/
Search for "query" in ~/.tron/workspace/knowledge/topics/
Search for "query" in ~/.tron/workspace/knowledge/arguments/
```

### Tag search

```
Search for "tags:.*tagname" in ~/.tron/workspace/knowledge/
```

### Backlink search

Find all notes that reference a specific note:
```
Search for "[[Note Name]]" in ~/.tron/workspace/knowledge/
```

### Browse by directory

```
Find *.md in ~/.tron/workspace/knowledge/
Find *.md in ~/.tron/workspace/knowledge/topics/
```

## Search order

1. Start with full-text search across the entire knowledge base
2. If too many results, narrow by category
3. Read the most relevant hits
4. Follow wikilinks to discover connected notes
5. Check backlinks to find notes that reference what you found

## Presenting results

When reporting search results:
- List matching notes with their paths
- Include a brief preview (first sentence or frontmatter title)
- Highlight the matching context
- Note any connections between results (shared tags, wikilinks)
