---
name: Code Search
description: Text and structural code search using ripgrep and ast-grep
version: "1.0.0"
tags: [search, code]
allowedTools: [Bash]
display:
  label: Code Search
  icon: magnifyingglass
  color: "#4A90D9"
guards:
  maxOutputLines: 500
  truncation: head_tail
---

# Code Search

Use `rg` (ripgrep) for text search and `ast-grep` for structural code search.

When using this skill, always include `skill: "code-search"` in your Bash call.
