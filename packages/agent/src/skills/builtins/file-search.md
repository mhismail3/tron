---
name: File Search
description: Find files by name patterns using fd or find
version: "1.0.0"
tags: [search, files]
allowedTools: [Bash]
display:
  label: File Search
  icon: folder
  color: "#F5A623"
guards:
  maxOutputLines: 200
---

# File Search

Use `fd` (preferred) or `find` to locate files by name, extension, or pattern.

When using this skill, always include `skill: "file-search"` in your Bash call.
