---
name: "Twitter"
description: "Fetch X/Twitter tweets by URL — zero-auth via fxtwitter API. Automatically walks reply chains to reconstruct threads and conversations."
version: "5.1.0"
tags: [twitter, social-media, x]
subagent: ask
---

# Fetch Tweet

Fetch any public tweet by URL and automatically reconstruct the full chain above it. No auth, cookies, or API keys needed.

## Fetching a Tweet

Given a tweet URL like `https://x.com/USER/status/ID`, extract the username and tweet ID, then:

```bash
curl -sf -H "User-Agent: tron/1.0" "https://api.fxtwitter.com/USER/status/TWEET_ID"
```

The response is JSON with tweet data in `.tweet`. Key fields:

| Field | Description |
|-------|-------------|
| `.tweet.text` | Tweet text |
| `.tweet.author.screen_name` | @ handle |
| `.tweet.author.name` | Display name |
| `.tweet.likes` / `.tweet.retweets` / `.tweet.replies` | Engagement metrics |
| `.tweet.replying_to` | Screen name of parent tweet author, or null |
| `.tweet.replying_to_status` | Tweet ID of parent tweet, or null |
| `.tweet.article` | Long-form article content (if present) |
| `.tweet.url` | Canonical tweet URL |
| `.tweet.created_at` | Timestamp |

For article tweets, the full body is in `.tweet.article.content.blocks[].text`.

URL formats — all work, extract the username and numeric ID from the path: `x.com`, `twitter.com`, `mobile.twitter.com`, with or without query params.

## Always Walk the Chain

**Every time you fetch a tweet, check `replying_to_status`.** If it is non-null, this tweet is part of a chain — walk up to get the full picture.

### Algorithm

```
tweets = [fetch(starting_url)]
while tweets[0].replying_to_status is not null:
    parent = fetch(tweets[0].replying_to_status)
    prepend parent to tweets
    stop after 50 hops (safety cap)
```

The result is the full chain in chronological order (oldest first).

### Classify the Result

Look at the authors across the collected chain:

| All tweets by the same author | **Thread** — one person's extended post on a topic |
|------|------|
| Multiple authors | **Conversation** — a back-and-forth exchange between people |

Include this classification when presenting results. For threads, present as a continuous read. For conversations, attribute each message to its author.

### Single Tweet

If `replying_to_status` is null on the first fetch, it's a standalone tweet — no chain to walk.

## Gotchas

- Only works for public tweets
- Chain walking only goes up — there is no zero-auth way to discover replies below a tweet
- If fxtwitter is down, the call fails with no fallback
