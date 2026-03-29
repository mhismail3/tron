---
name: Testing
description: Discover and run tests across frameworks
version: "1.0.0"
tags: [testing, ci]
allowedTools: [Bash]
display:
  label: Testing
  icon: checkmark.circle
  color: "#22C55E"
guards:
  maxOutputLines: 1000
---

# Testing

Discover and run tests using the appropriate framework for the project.

When using this skill, always include `skill: "testing"` in your Bash call.
