# Ingest Workflow

All the ways content enters the knowledge base. Four modes, one workflow.

Read WIKI_RULES before starting for frontmatter and naming conventions. Paths are defined in the skill's Paths table.

---

## Mode Selection

| Input | Mode |
|---|---|
| User provides a URL (or pastes one in chat) | **Extract** |
| User says "save this" / "capture this" mid-conversation | **Capture** |
| User says "save that answer" after a good synthesis | **Fileback** |
| User wants to save a quick fact, preference, or reference | **Save** |

---

## Extract Mode (URL → source + topic updates)

### Step 1: Fetch

Use WebFetch to read the URL. Extract:
- Author, title, publication date
- Core claims, concepts, evidence

| URL type | Method |
|---|---|
| Articles, blogs | WebFetch directly |
| Twitter/X posts (`x.com/*/status/*`, `twitter.com/*/status/*`) | See the Twitter skill — `curl` the fxtwitter API (zero auth, structured JSON). Falls back to WebFetch if API unavailable. |
| PDFs, papers | WebFetch with PDF handling |
| YouTube, video | WebFetch — title, description, transcript if available |

> **Why not WebFetch for tweets?** X's pages are heavily JavaScript-dependent — WebFetch often gets incomplete or empty content. The fxtwitter public API (`api.fxtwitter.com`) returns structured JSON reliably, including full article content for long-form posts. No auth needed. See the Twitter skill for details.

### Step 2: Survey existing topics

```
Read: WIKI_INDEX
Search for "<key concepts>" in WIKI_ROOT
```

Read relevant existing topic notes. Update instead of duplicating.

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
```

No Connections section. Sources are immutable after creation.

### Step 4: Create/update topic notes

Read the index to understand what topics already exist. For each key concept in the source:

1. **Does an existing topic already cover this?** → Read that topic. If the source adds something new, write it into the topic where it fits. If it just confirms what's there, append the source link to the existing claim.
2. **Is this a genuinely distinct concept with substance?** → Create a new topic. A concept earns its own page when it has its own claims, evidence, and questions — not when it's merely mentioned.
3. **Passing mention with nothing new to say?** → Skip it. Don't add noise.

Path: `WIKI_TOPICS/{concept-slug}.md`

```markdown
---
type: topic
tags: [relevant, tags]
sources: [YYYY-MM-DD-author-title]
created: "YYYY-MM-DD"
updated: "YYYY-MM-DD"
---

# {Concept}

Core explanation from [[source-slug]] — what it is, why it matters.

Further detail: specific claim with evidence, also from [[source-slug]].

## Open Questions

- Unresolved questions or contradictions
```

**Content rules per WIKI_RULES:**
- Free-form but bias towards conciseness — every sentence carries signal
- Cite sources inline via `[[source-slug]]` (the date in the slug serves as timestamp)
- Link to related topics with `[[topic-slug]]` only when the connection adds insight
- New insight: write it out. Confirming evidence: just add the source link to the existing claim
- When updating existing: bump `updated`, add source slug to `sources` list

### Step 5: Epilogue

Update WIKI_INDEX, append to WIKI_LOG, git commit. See SKILL.md epilogue section.

### Step 6: Report

1. Source note path
2. Topic notes created/updated (list each with what was added)
3. Cross-references established

---

## Capture Mode (session insights → topics)

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
- Format as concise statements with timestamps

### Step 3: Epilogue and report

Same as Extract steps 5-6.

---

## Fileback Mode (good answer → topic note)

### Step 1: Identify the synthesis

The user says "save that answer" or `@knowledge fileback`. Identify the most recent substantive synthesis — not a simple lookup but something that connected ideas or produced a useful framework.

### Step 2: Create topic note

- Rewrite to standalone concise statements
- Add wikilinks and source citations
- Check for existing topic notes — integrate, don't duplicate

### Step 3: Epilogue and report

Same as Extract steps 5-6.

---

## Save Mode (quick note)

### Step 1: Determine where it goes

| Content | Directory |
|---|---|
| A link or bookmark | WIKI_SOURCES (even without deep extraction) |
| A fact, concept, preference, technique | WIKI_TOPICS |

### Step 2: Check for existing notes

```
Search for "<key terms>" in WIKI_ROOT
```

Update existing notes instead of duplicating.

### Step 3: Write

Create the note with appropriate frontmatter per WIKI_RULES. Keep it concise but specific. Format topic content as concise statements, not prose.

### Step 4: Epilogue

Update WIKI_INDEX, append to WIKI_LOG, git commit.

---

## Update vs Create Logic

This applies to all modes:

1. Search for existing notes matching the concept/URL
2. If found: read the note, integrate new content with Edit, bump `updated`
3. If not found: create a new note with Write
4. Never create duplicates — one source note per URL, one topic note per concept
