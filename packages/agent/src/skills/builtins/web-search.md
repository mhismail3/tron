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

Use `curl` with the Brave Search API. The API key is injected as `$BRAVE_API_KEY`.

When using this skill, always include `skill: "web-search"` in your Bash call.
