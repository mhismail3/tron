# Deep Research Workflow

Autonomous, multi-round investigation with rigorous source evaluation. Use this for broad research requests — not for quick lookups or single-URL extraction (use `ingest.md` for those).

Read WIKI_SCHEMA before starting. Paths are defined in the skill's Paths table.

---

## Standards

1. **Depth over speed.** Every topic gets at least two research rounds: initial survey, then targeted deep-dives.
2. **Source quality matters.** Prefer primary sources (official docs, RFCs, papers, repos) over secondary coverage (blogs, tutorials, aggregators). Flag secondary sources.
3. **Seek disagreement.** Search for opposing viewpoints, criticisms. Use queries like "[topic] criticism", "[topic] vs [alternative]", "[topic] tradeoffs".
4. **Verify, don't trust.** Cross-reference claims across independent sources. If only one source makes a claim, say so.

---

## Methodology

### Round 1: Survey

1. Parse the topic into 2-5 subtopics or key questions
2. WebSearch each subtopic with 2-3 query variations
3. Scan results for authoritative sources
4. WebFetch the top 3-5 sources — read carefully
5. Note: what's established, what's contested, what's unclear

### Round 2: Deep-dive

1. Identify gaps and conflicts from Round 1
2. Search specifically for gaps and conflicts
3. WebFetch primary sources not yet read
4. Cross-reference key claims across sources

### Round 3+: Targeted verification (when needed)

1. Search for counterarguments to the emerging consensus
2. Look for empirical data, benchmarks, case studies
3. Check publication dates — is anything outdated?
4. Resolve remaining conflicts or document them

**Stop signal:** New searches return already-seen information from multiple independent sources, AND you've searched for counterarguments.

---

## Source Evaluation

| Signal | Strong | Weak |
|--------|--------|------|
| Author | Domain expert, institution | Anonymous, content farm |
| Publication | Official docs, peer-reviewed | Random blog, SEO listicle |
| Evidence | Data, benchmarks, reproducible | Anecdotes, "in my experience" |
| Recency | Current or versioned | Undated or stale |
| Independence | Original research | Rehash of other articles |

---

## Output

### 1. Research report (source note)

Path: `WIKI_SOURCES/YYYY-MM-DD-{topic-slug}-research.md`

```markdown
---
type: source
source_type: research
tags: [relevant, tags]
sources_consulted: 8
created: "YYYY-MM-DD"
updated: "YYYY-MM-DD"
---

# {Research Title}

## Summary

2-3 paragraphs: key findings, main conclusion.

## Background

Core concepts, definitions, historical context.

## Findings

### {Theme 1}

Detailed findings organized by theme. Every claim has a citation[1].

### {Theme 2}

...

## Competing Perspectives

Major disagreements or alternative approaches.

## Practical Implications

How to apply these findings.

## Limitations

- What you couldn't find good sources for
- Where evidence is thin or conflicting
- Caveats

## Sources

[1] Source Title — URL (primary, 2025)
[2] Author, "Article Title" — URL (secondary, 2024)
```

### 2. Wiki pages

Extract key concepts into WIKI_PAGES. Link them back to the research report with `[[topic-slug-research]]`. Follow the wiki page format from WIKI_SCHEMA.

### 3. Conflicts

Where sources disagree, flag and preserve both positions per WIKI_SCHEMA conflict conventions.

### 4. Epilogue

Update WIKI_INDEX, append to WIKI_LOG, git commit. Log operation type: `research`.

### 5. Completion report

1. Research report path
2. Sources consulted (count and list)
3. Wiki pages created/updated
4. Key findings summary
5. Open questions / gaps

## Gotchas
