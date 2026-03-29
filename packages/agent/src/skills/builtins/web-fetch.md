---
name: Web Fetch
description: Fetch web content using curl with optional summarization
version: "1.0.0"
tags: [web, http]
allowedTools: [Bash, SpawnSubagent]
display:
  label: Web Fetch
  icon: globe
  color: "#7B68EE"
guards:
  maxOutputBytes: 500000
  cache:
    ttl: 900
    keyExtractor: url
---

# Web Fetch

Fetch web content using `curl`. For large HTML responses, spawn a subagent to summarize.
Always include `skill: "web-fetch"` in your Bash call when using this skill.

## Basic GET Requests

```bash
# Fetch a URL and get the body
curl -sS 'https://example.com/api/data'

# Follow redirects
curl -sSL 'https://example.com/page'

# Get headers + body
curl -sSi 'https://example.com'

# Get only headers
curl -sSI 'https://example.com'

# Get only status code
curl -so /dev/null -w '%{http_code}' 'https://example.com'
```

## API Requests

```bash
# GET with JSON accept header
curl -sS -H 'Accept: application/json' 'https://api.example.com/data'

# POST JSON data
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"key": "value"}' 'https://api.example.com/endpoint'

# PUT with auth header
curl -sS -X PUT -H 'Authorization: Bearer $TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"update": true}' 'https://api.example.com/resource/1'

# DELETE
curl -sS -X DELETE -H 'Authorization: Bearer $TOKEN' \
  'https://api.example.com/resource/1'
```

## Recommended Flags

| Flag | Purpose |
|------|---------|
| `-sS` | Silent but show errors (always use) |
| `-L` | Follow redirects |
| `-i` | Include response headers |
| `-I` | Headers only (HEAD request) |
| `-H 'Header: value'` | Add custom header |
| `-d 'data'` | POST data |
| `-X METHOD` | HTTP method |
| `-o file` | Save output to file |
| `-w '%{http_code}'` | Output status code |
| `--connect-timeout 10` | Connection timeout |
| `--max-time 30` | Total request timeout |

## Large Response Handling

If a response is very large (e.g., full HTML pages), consider:

1. **Pipe through text extraction:** `curl -sSL url | sed 's/<[^>]*>//g'` for crude HTML stripping
2. **Spawn a subagent for summarization:** Fetch first, then spawn a subagent with the content and a summarization prompt
3. **Request specific formats:** Use `Accept: application/json` or API-specific formats to get structured data

## Output is Cached

Results are cached for 15 minutes (keyed by URL). Subsequent fetches of the same URL within the cache window return the cached response without making a new request.
