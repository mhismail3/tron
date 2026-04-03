# Synthesis & Report

How to organize research findings and produce the final report.

## Organization

Organize findings **by theme**, not by query or search round. Group related insights regardless of which search surfaced them. Build narrative from foundational context to nuanced conclusions.

## Tweet Citation Format

When citing tweets in the report:

> @username: "quoted text" (N likes) — [Tweet](https://x.com/username/status/TWEET_ID)

For paraphrased references: mention @username inline with a link to the tweet.

## Report Output

Write to: `~/.tron/memory/research/YYYY-MM-DD-x-<slug>/report.md`

Generate the timestamp from current time, slug from the research topic.

```markdown
---
title: "Research Title"
topic: "original query"
platform: x/twitter
researched: "ISO8601"
tweets_analyzed: count
accounts_consulted: count
confidence: high|medium|low
---

## Executive Summary

2-3 paragraphs: key findings, consensus vs contested points, confidence level.

## Background

Context needed to understand the discourse. Key players, timeline of events.

## Findings

### [Theme 1]

Thematic findings with tweet citations. Note engagement levels and whether
a view is widely held or from a single voice.

> @expert: "key quote here" (342 likes) — [Tweet](url)

### [Theme 2]

Continue with additional themes...

## Competing Perspectives

Major disagreements found. Present each side with its strongest tweets.

## Practical Implications

Actionable takeaways from the discourse.

## Limitations

- What perspectives might be missing from X discourse
- Where tweet volume was too low for confidence
- Time-sensitivity of findings

## Sources

Tweets cited, organized by theme or chronologically.
Linked articles fetched and referenced.
```

## Completion

When done:
1. Write the report to `~/.tron/memory/research/<timestamp>-x-<slug>/report.md`
2. Verify all tweet citations include @username and link
3. Return a summary: report path, tweets analyzed, accounts consulted, confidence level, key findings in 2-3 sentences
