---
name: Web Fetch
description: Fetch web content using curl
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

Use `curl` to fetch web content. For large HTML responses, spawn a subagent to summarize.

When using this skill, always include `skill: "web-fetch"` in your Bash call.
