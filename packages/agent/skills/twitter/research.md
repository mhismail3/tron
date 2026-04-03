# Research Methodology

Multi-round research loop for deep X/Twitter investigation. For search operator details, read `search-operators.md`.

## Quick vs Deep

- **Quick lookup**: Single search, scan results, answer directly. Use for factual questions, recent events, or "what are people saying about X right now."
- **Deep research**: Multi-round loop with decomposition, thread following, link analysis, and synthesis. Use for nuanced questions, sentiment analysis, emerging trends, or contested topics.

Match depth to the question. A simple "what happened with [event]?" needs one search. "What's the developer sentiment on [technology] and how has it shifted?" needs the full loop.

## Round 1 — Decompose & Survey

1. **Parse the question** into 3-5 targeted search queries, each attacking the topic from a different angle:
   - **Core query**: Direct keywords + `-filter:retweets` + `min_faves:10`
   - **Expert voices**: `from:known_expert` or combine with `min_faves:50` for authoritative takes
   - **Pain points**: Keywords + "broken" OR "frustrating" OR "disappointed" + `-filter:retweets`
   - **Positive signal**: Keywords + "shipped" OR "launched" OR "love" + `min_faves:20`
   - **Resources**: Keywords + `filter:links` to find articles, papers, repos
   - **Recency**: Add `since:YYYY-MM-DD` (last 7 days) for fast-moving topics

2. **Execute each query**: `tron-twitter --format text search "QUERY" --count 20 --product Top`

3. **Assess signal quality** per query:
   - High signal → note key tweets, users, and threads to follow up
   - Low signal → adjust operators (see Refinement Heuristics in `search-operators.md`)
   - No signal → broaden terms, try `--product Latest`, drop filters

## Round 2 — Deep-Dive

Based on Round 1 findings:

1. **Follow threads**: For high-engagement tweets, fetch the full tweet with `tron-twitter tweet TWEET_ID`, then search for replies with `tron-twitter search "to:USERNAME" --count 20` to find the conversation
2. **Profile deep-dives**: For key voices identified in Round 1, scan their recent output with `tron-twitter timeline USERNAME --count 20`
3. **Linked content**: WebFetch URLs shared in high-signal tweets — blog posts, GitHub repos, papers, documentation
4. **Cross-reference**: WebSearch to verify claims made in tweets against external sources

## Round 3+ — Refinement

For contested or complex topics:

1. Search for **counterarguments**: "[topic] overrated" OR "problem with [topic]" + `-filter:retweets`
2. Look for **empirical data**: `filter:links` + keywords targeting benchmarks, studies, case studies
3. **Timeline checks**: Compare takes from 3 months ago vs now — has sentiment shifted?
4. Resolve conflicts or explicitly document them as unresolved

## Saturation Signal

Stop when new searches return already-seen tweets and you've actively searched for counterarguments. At this point, move to synthesis — read `report.md` for the report format.
