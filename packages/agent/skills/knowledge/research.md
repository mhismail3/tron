# Deep Research Workflow

Autonomous, multi-round investigation with rigorous source evaluation. Use this for broad research requests — not for quick lookups or single-URL extraction (use `extract.md` for those).

## Core Standards

1. **Depth over speed.** Every topic gets at least two research rounds: an initial survey, then targeted deep-dives. Nuanced or contested topics require three or more.
2. **Source quality matters.** Prefer primary sources (official docs, RFCs, papers, repos) over secondary coverage (blogs, tutorials, aggregators). Flag secondary sources as such.
3. **Seek disagreement.** Search for opposing viewpoints, alternative approaches, criticisms. Use queries like "[topic] criticism", "[topic] vs [alternative]", "[topic] tradeoffs".
4. **Verify, don't trust.** Cross-reference claims across independent sources. If only one source makes a claim, say so.

## Methodology

### Round 1: Survey

1. Parse the topic into 2-5 subtopics or key questions
2. WebSearch each subtopic with 2-3 query variations
3. Scan results for authoritative sources (official docs, known authors, primary research)
4. WebFetch the top 3-5 sources — read carefully, not superficially
5. Note: what's established, what's contested, what's unclear

### Round 2: Deep-dive

1. Identify gaps — what questions remain unanswered?
2. Identify conflicts — where do sources disagree?
3. Search specifically for the gaps and conflicts
4. WebFetch primary sources identified but not yet read
5. Cross-reference key claims across sources

### Round 3+: Targeted verification (when needed)

1. Search for the strongest counterarguments to the emerging consensus
2. Look for empirical data, benchmarks, case studies
3. Check publication dates — is anything outdated?
4. Resolve remaining conflicts or document them as unresolved

**Stop signal:** New searches return information you've already seen from multiple independent sources, AND you've searched for counterarguments.

## Source Evaluation

| Signal | Strong | Weak |
|--------|--------|------|
| Author | Domain expert, affiliated institution | Anonymous, content farm |
| Publication | Official docs, peer-reviewed, established outlet | Random blog, SEO listicle |
| Evidence | Data, benchmarks, reproducible examples | Anecdotes, "in my experience" |
| Recency | Current or versioned | Undated or stale |
| Independence | Original research/analysis | Rehash of other articles |

## Output

Write the report to `~/.tron/workspace/knowledge/` and create linked notes:

### 1. Research report

**Path:** `~/.tron/workspace/knowledge/sources/YYYY-MM-DD-{topic-slug}-research.md`

```markdown
---
type: source
source_type: research
topic: "original query"
researched: "ISO8601"
sources_consulted: count
confidence: high|medium|low
tags: [relevant, tags]
---

# {Research Title}

## Executive Summary

2-3 paragraphs: key findings, confidence level, main conclusion.

## Background

Core concepts, definitions, historical context. Build understanding from the ground up.

## Findings

### [Theme 1]

Detailed findings organized by theme. Every claim has a footnote citation[1].

### [Theme 2]

...

## Competing Perspectives

Major disagreements or alternative approaches. Strongest formulation of each position.

## Practical Implications

How to apply these findings.

## Limitations

- What you couldn't find good sources for
- Where evidence is thin or conflicting
- What may have changed since publication
- Caveats the reader should know

## Sources

[1] Source Title — https://example.com/page (primary, 2025)
[2] Author Name, "Article Title" — https://example.com/other (secondary, 2024)
```

### 2. Topic notes

Extract key concepts into `~/.tron/workspace/knowledge/topics/` notes (see `extract.md` Step 4). Link them back to the research report with `[[topic-slug-research]]`.

### 3. Argument notes

If the research surfaces a thesis or synthesis, create an argument note in `~/.tron/workspace/knowledge/arguments/` (see `extract.md` Step 5).

## Completion

1. Write the report to `~/.tron/workspace/knowledge/sources/`
2. Create/update topic and argument notes
3. Verify all citations have corresponding entries in Sources
4. Return a summary: report path, sources consulted, confidence level, key findings
