# Search Operators

Build precise queries by combining operators directly in the search string. Operators go inside the quoted query argument to `tron-twitter search`.

## Operator Reference

| Operator | Effect | Example |
|----------|--------|---------|
| `from:user` | Tweets by user | `from:karpathy "transformers"` |
| `to:user` | Replies to user | `to:elonmusk "API"` |
| `since:YYYY-MM-DD` | After date | `"LLM" since:2026-03-01` |
| `until:YYYY-MM-DD` | Before date | `"GPT" until:2026-01-01` |
| `min_faves:N` | Minimum likes | `"RAG" min_faves:100` |
| `min_retweets:N` | Minimum retweets | `"breaking" min_retweets:50` |
| `-filter:replies` | Exclude replies | `"rust" -filter:replies` |
| `-filter:retweets` | Exclude retweets | `"golang" -filter:retweets` |
| `filter:links` | Only with links | `"paper" filter:links` |
| `url:domain.com` | Links to domain | `url:arxiv.org "attention"` |
| `lang:xx` | Language filter | `"AI regulation" lang:en` |
| `OR` | Broaden matches | `"LLM" OR "large language model"` |
| `-keyword` | Exclude term | `"crypto" -airdrop -giveaway` |

## Intent → Query Mapping

| Intent | Query Construction |
|--------|-------------------|
| Top/popular posts | `--product Top` flag |
| Latest/chronological | `--product Latest` flag |
| Quality filter | `min_faves:10` in query |
| Expert voices | `from:username` in query |
| No retweets | `-filter:retweets` in query |
| No replies | `-filter:replies` in query |
| Has external links | `filter:links` in query |
| Time-bounded | `since:YYYY-MM-DD` in query |

## Combining Operators

Operators compose freely inside the query string:

```bash
# Expert takes on RAG with links, last 7 days, 50+ likes
tron-twitter --format text search "RAG min_faves:50 filter:links since:2026-02-27 -filter:retweets" --count 20 --product Top

# Pain points about a library from two users
tron-twitter search "from:user1 OR from:user2 \"broken\" OR \"bug\" -filter:retweets" --count 20

# Research papers on a topic
tron-twitter search "url:arxiv.org \"attention mechanism\" since:2026-01-01" --count 20
```

## Refinement Heuristics

| Problem | Fix |
|---------|-----|
| Too noisy / low quality | Add `-filter:replies`, use `--product Top`, narrow keywords, add `min_faves:10` |
| Too few results | Broaden with `OR`, try `--product Latest`, drop `min_faves`, use shorter date range |
| Crypto/spam pollution | Add `-airdrop -giveaway -whitelist -presale` |
| Want expert takes only | Use `from:known_expert` or raise to `min_faves:50` |
| Want substance over hot takes | Add `filter:links` to find tweets with external references |
| Too many retweets | Add `-filter:retweets` (always include this in research queries) |
| Non-English noise | Add `lang:en` |

## Gotchas
