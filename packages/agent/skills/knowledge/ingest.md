# Ingest Workflow

All the ways content enters the wiki. Four modes, one workflow.

Read WIKI_SCHEMA before starting for frontmatter and naming conventions. Paths are defined in the skill's Paths table.

---

## Mode Selection

| Input | Mode |
|---|---|
| User provides a URL | **Extract** |
| User says "save this" / "capture this" mid-conversation | **Capture** |
| User says "save that answer" after a good synthesis | **Fileback** |
| User wants to save a quick fact, preference, or reference | **Save** |

---

## Extract Mode (URL → source + wiki pages)

### Step 1: Fetch

Use WebFetch to read the URL. Extract:
- Author, title, publication date
- Core claims, concepts, evidence

| URL type | Method |
|---|---|
| Articles, blogs | WebFetch directly |
| Twitter/X posts | WebFetch — extract tweet text, author, date |
| PDFs, papers | WebFetch with PDF handling |
| YouTube, video | WebFetch — title, description, transcript if available |

### Step 2: Survey existing notes

```
Read: WIKI_INDEX
Search for "<key concepts>" in WIKI_ROOT
```

Read relevant existing notes. Update instead of duplicating.

### Step 3: Create source note

One per URL. Path: `WIKI_SOURCES/YYYY-MM-DD-{author-last-name}-{short-title}.md`

```markdown
---
type: source
url: "https://..."
author: "Full Name"
published: "YYYY-MM-DD"
accessed: "YYYY-MM-DD"
source_type: article
tags: [topic1, topic2]
created: "YYYY-MM-DD"
updated: "YYYY-MM-DD"
---

# {Author} — {Short Title}

## Summary

2-3 paragraph summary of the core argument and contribution.

## Key Takeaways

- Specific takeaway with evidence — not vague generality
- Another takeaway — include numbers and details

## Connections

- [[wiki-page]] — how this source relates
```

### Step 4: Create/update wiki pages

For each key concept or thesis in the source, create or update a wiki page.

Search first — if a page for the concept exists, read it and use Edit to integrate. If not, create one.

Path: `WIKI_PAGES/{concept-slug}.md`

```markdown
---
type: wiki
tags: [relevant, tags]
sources: [YYYY-MM-DD-author-title]
created: "YYYY-MM-DD"
updated: "YYYY-MM-DD"
---

# {Concept}

## YYYY-MM-DD HH:MM — {Update title}

{Clear explanation. Every claim cites its source [[slug]].}

## Open Questions

- Unresolved questions or contradictions
```

Cross-link selectively — only when there's a meaningful connection between this concept and existing wiki pages.

When updating an existing wiki page: bump `updated`, add `source-slug` to `sources` list, add a new timestamped section at the top.

### Step 5: Epilogue

Update WIKI_INDEX, append to WIKI_LOG, git commit. See SKILL.md epilogue section.

### Step 6: Report

1. Source note path
2. Wiki pages created/updated (list each)
3. Connections to existing wiki pages

---

## Capture Mode (session insights → wiki)

### Step 1: Identify

Scan the conversation for:
- Synthesized insights or conclusions
- Novel connections between ideas
- Frameworks or patterns that emerged
- Decisions and rationale (if broadly applicable)

If user specified what to capture, focus on that. Otherwise, present the 1-3 most significant insights and ask for confirmation.

### Step 2: Survey and create

Same as Extract steps 2 and 4, but:
- Add `capture_context: "session"` to frontmatter
- No source note unless the conversation referenced a specific URL
- Make the content standalone — remove conversational phrasing

### Step 3: Epilogue and report

Same as Extract steps 5-6.

---

## Fileback Mode (good answer → wiki page)

### Step 1: Identify the synthesis

The user says "save that answer" or `@knowledge fileback`. Identify the most recent substantive synthesis — not a simple lookup but something that connected ideas or produced a useful framework.

### Step 2: Create wiki page

- Determine type: concept explanation → standard wiki page, curated reference → reference wiki page
- Add `origin: "fileback"` to frontmatter
- Rewrite to standalone form: remove conversational phrasing, add wikilinks and source citations
- Check for existing notes — integrate, don't duplicate

### Step 3: Epilogue and report

Same as Extract steps 5-6.

---

## Save Mode (quick note)

### Step 1: Determine where it goes

| Content | Directory |
|---|---|
| A link or bookmark | WIKI_SOURCES (even without deep extraction) |
| A fact, concept, preference, technique | WIKI_PAGES |

### Step 2: Check for existing notes

```
Search for "<key terms>" in WIKI_ROOT
```

Update existing notes instead of duplicating.

### Step 3: Write

Create the note with appropriate frontmatter per WIKI_SCHEMA. Keep it concise but specific. Include enough context that the note is useful months later.

### Step 4: Epilogue

Update WIKI_INDEX, append to WIKI_LOG, git commit.

---

## Update vs Create Logic

This applies to all modes:

1. Search for existing notes matching the concept/URL
2. If found: read the note, integrate new content with Edit, bump `updated`
3. If not found: create a new note with Write
4. Never create duplicates — one source note per URL, one wiki page per concept
