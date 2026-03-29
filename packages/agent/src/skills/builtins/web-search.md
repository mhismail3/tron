---
name: Web Search
description: Search the web using the Brave Search API
version: "1.0.0"
tags: [search, web]
allowedTools: [Bash]
display:
  label: Web Search
  icon: magnifyingglass.circle
  color: "#50C878"
guards:
  rateLimitMs: 1000
  secrets:
    - env: BRAVE_API_KEY
      setting: web.brave_api_key
  cache:
    ttl: 300
    keyExtractor: auto
---

# Web Search

Search the web using the Brave Search API via `curl`. The API key is automatically injected as the `$BRAVE_API_KEY` environment variable.
Always include `skill: "web-search"` in your Bash call when using this skill.

## Basic Web Search

```bash
# Simple search
curl -sS -H "Accept: application/json" \
  -H "X-Subscription-Token: $BRAVE_API_KEY" \
  "https://api.search.brave.com/res/v1/web/search?q=rust+async+tutorial"
```

## Search Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `q` | Search query (required, max 400 chars) | `q=rust+error+handling` |
| `count` | Results per page (1-20, default 10) | `count=5` |
| `offset` | Pagination offset | `offset=10` |
| `freshness` | Time filter | `freshness=pd` (past day), `pw` (week), `pm` (month) |
| `country` | Country filter (2-char code) | `country=US` |
| `search_lang` | Search language | `search_lang=en` |
| `safesearch` | Content filter | `safesearch=moderate` |

## Search Endpoints

```bash
# Web search (default)
curl -sS -H "Accept: application/json" \
  -H "X-Subscription-Token: $BRAVE_API_KEY" \
  "https://api.search.brave.com/res/v1/web/search?q=query"

# News search
curl -sS -H "Accept: application/json" \
  -H "X-Subscription-Token: $BRAVE_API_KEY" \
  "https://api.search.brave.com/res/v1/news/search?q=query&freshness=pd"
```

## Response Processing

The JSON response contains `web.results[]` with:
- `title` — result title
- `url` — result URL
- `description` — snippet text

Use `jq` to extract relevant fields:
```bash
curl -sS -H "Accept: application/json" \
  -H "X-Subscription-Token: $BRAVE_API_KEY" \
  "https://api.search.brave.com/res/v1/web/search?q=query" \
  | jq '.web.results[:5] | .[] | {title, url, description}'
```

## Rate Limiting

Calls are rate-limited to 1 per second. If rate-limited, wait and retry.

## Results are Cached

Search results are cached for 5 minutes (keyed by the full request URL).
