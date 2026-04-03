# Knowledge Extraction Workflow

Extract knowledge from a URL into **Source**, **Topic**, and **Argument** notes. Every extraction produces all three note types.

## Workflow

### Step 1: Fetch content

Use WebFetch to read the URL. Extract:
- Author name(s)
- Title
- Publication date (if available)
- Core claims and concepts
- Key evidence and data

| URL type | Extraction method |
|---|---|
| Articles, blogs | WebFetch directly |
| Twitter/X posts | WebFetch — extract tweet text, author, date |
| PDFs, papers | WebFetch with PDF extraction |
| YouTube, video | WebFetch — title, description, transcript if available |

### Step 2: Survey existing notes (mandatory)

Before creating or modifying anything, check what already exists:

```
Find *.md in ~/.tron/memory/knowledge/sources/
Find *.md in ~/.tron/memory/knowledge/topics/
Search for "<key concept>" in ~/.tron/memory/knowledge/
```

Read any notes that look relevant. Update existing notes instead of creating duplicates.

### Step 3: Create/update source note

One per URL. If a source note for this URL already exists, update it.

**Path:** `~/.tron/memory/knowledge/sources/YYYY-MM-DD-{author-last-name}-{short-title}.md`

```markdown
---
type: source
url: "https://..."
accessed: "YYYY-MM-DD"
source_type: article|paper|blog|book|video|podcast|tweet
author: "Full Name"
published: "YYYY-MM-DD"
tags: [topic1, topic2]
---

# {Author} - {Short Title}

## Summary

2-3 paragraph summary of the source's core argument and contribution.

## Key Takeaways

- Specific takeaway with data/evidence, not vague generality
- Another takeaway — include numbers and details when available

## Related Topics

- [[Topic Name]] — how this source relates to the topic
```

### Step 4: Create/update topic notes

Topics are atomic — one concept per note. They grow as multiple sources contribute.

Search first. If a topic exists, read it and use Edit to integrate new information. If not, create one.

**Path:** `~/.tron/memory/knowledge/topics/{topic-name}.md` (living document — topic slug, no date prefix)

```markdown
---
topic: {topic-name}
type: topic
tags: [relevant, tags]
created: "YYYY-MM-DD"
updated: "YYYY-MM-DD"
---

## YYYY-MM-DD HH:MM — {Update title}

{Clear explanation. Every factual claim cites its source.}

Source A found that X [[Author - Short Title]]. This was corroborated by Source B [[Other Author - Title]].

## Open Questions

- Unresolved questions or contradictions between sources
```

At least one topic note per extraction. Keep notes atomic — if a note covers two distinct concepts, split it. When updating an existing topic, bump `updated` and add a new timestamped section at the top.

### Step 5: Create/update argument notes

Arguments are synthesis — a thesis, question, or connection emerging from multiple topics and sources. At least one per extraction.

**Path:** `~/.tron/memory/knowledge/arguments/{thesis-or-question}.md` (living document — topic slug, no date prefix)

```markdown
---
topic: {thesis-or-question}
type: argument
tags: [relevant, tags]
created: "YYYY-MM-DD"
updated: "YYYY-MM-DD"
---

# {Thesis Statement or Question}

## Position

{The argument, connecting multiple topics and sources.}

## Supporting Evidence

- Evidence with citation [[Source]]

## Counterarguments

- Known objections or limitations

## Status

Draft | Developing | Strong
```

## Update vs create logic

1. Search for existing notes matching the concept/URL
2. If found: read the note, integrate new content with Edit
3. If not found: create a new note with Write
4. Never create duplicates — one source note per URL, one topic note per concept

## Output

After processing, report:
1. Source note created/updated (with path)
2. Topic notes created/updated (list each)
3. Argument notes created/updated
4. Connections found to existing notes
