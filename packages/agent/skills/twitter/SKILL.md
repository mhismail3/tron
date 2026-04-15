---
name: "Twitter"
description: "Fetch X/Twitter tweets by URL — zero-auth, returns structured JSON via fxtwitter public API"
version: "5.0.0"
tags: [twitter, social-media, x]
subagent: ask
---

# Fetch Tweet

Fetch any public tweet by URL. No auth, cookies, or API keys needed.

## Usage

Given a tweet URL like `https://x.com/USER/status/ID`, extract the username and tweet ID, then:

```bash
curl -sf -H "User-Agent: tron/1.0" "https://api.fxtwitter.com/USER/status/TWEET_ID"
```

The response is JSON. The tweet data is in `.tweet`. Key fields:

| Field | Description |
|-------|-------------|
| `.tweet.text` | Tweet text |
| `.tweet.author.name` | Display name |
| `.tweet.author.screen_name` | @ handle |
| `.tweet.likes` / `.tweet.retweets` / `.tweet.replies` | Engagement metrics |
| `.tweet.replying_to` | Screen name of parent tweet author, or null |
| `.tweet.replying_to_status` | Tweet ID of parent tweet, or null |
| `.tweet.article` | Long-form article content (if present) |
| `.tweet.url` | Canonical tweet URL |
| `.tweet.created_at` | Timestamp |

For article tweets, the full body is in `.tweet.article.content.blocks[].text`.

## URL Parsing

All of these URL formats work — extract the username and numeric ID from the path:

- `https://x.com/USER/status/ID`
- `https://twitter.com/USER/status/ID`
- `https://mobile.twitter.com/USER/status/ID`
- URLs with query params or fragments

## Thread Walking

`replying_to_status` lets you walk UP a self-reply thread. Fetch a tweet, check if `replying_to_status` is non-null and `replying_to` matches the same author — if so, fetch the parent and repeat. Stop when `replying_to_status` is null or the author changes. Reverse for chronological order.

This only walks up. There is no zero-auth way to discover replies below a tweet.

## Gotchas

- Only works for public tweets
- If fxtwitter is down, the call fails — there is no fallback
- Rate limits are undocumented but generous; don't abuse it
