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

Search code using `rg` (ripgrep) for text patterns and `ast-grep` for structural/AST patterns.
Always include `skill: "code-search"` in your Bash call when using this skill.

## Text Search (ripgrep)

Use `rg` for fast regex-based text search across files.

**Recommended flags:**
- `-n` — show line numbers (always include)
- `--glob '*.ext'` or `-g '*.ext'` — filter by file extension
- `-C 3` — show 3 lines of context around matches
- `-i` — case-insensitive search
- `-w` — match whole words only
- `-l` — list matching files only (no content)
- `-c` — show match count per file
- `--type rust` (or `py`, `js`, `ts`, etc.) — filter by language type
- `--hidden` — include hidden files (excluded by default)
- `-F` — fixed string (not regex)
- `-m N` — limit to N matches per file

**Examples:**
```bash
# Search for a function definition
rg -n 'fn execute' --glob '*.rs' -C 3

# Case-insensitive search for error handling
rg -ni 'error|err' --type rust -C 2

# Find files containing a pattern
rg -l 'TODO|FIXME' --type ts

# Search with fixed string (no regex interpretation)
rg -nF 'Vec<String>' --glob '*.rs'

# Count matches per file
rg -c 'import' --type py
```

**Default exclusions (rg respects .gitignore):** node_modules, .git, dist, build, target, __pycache__, .next, coverage.

## Structural Search (ast-grep)

Use `ast-grep` (or `sg`) for AST-aware code search when you need to match code structure rather than text patterns. Prefer ast-grep when:
- Searching for specific syntax patterns (function calls, variable declarations)
- The text pattern would produce too many false positives
- You need to match across formatting variations

**Examples:**
```bash
# Find all function calls to a specific function
ast-grep --pattern 'foo($$$)' --lang rust

# Find async functions
ast-grep --pattern 'async fn $NAME($$$) $BODY' --lang rust

# Find if-let patterns
ast-grep --pattern 'if let Some($VAR) = $EXPR { $$$ }' --lang rust

# Find React component usage
ast-grep --pattern '<Button $$$>$$$</Button>' --lang tsx
```

**Pattern syntax:**
- `$VAR` — matches a single AST node (named capture)
- `$$$` — matches zero or more AST nodes (variadic)
- Use `--lang` to specify the language

## Decision Guide

| Use Case | Tool | Why |
|----------|------|-----|
| Find text in files | `rg` | Fast, respects .gitignore |
| Find function/class definitions | `rg` with `-n` | Simple pattern matching |
| Find structural code patterns | `ast-grep` | AST-aware, ignores formatting |
| List files matching a pattern | `rg -l` | Just file paths |
| Count occurrences | `rg -c` | Quick metrics |

## Output Notes

- Keep searches focused: use `--glob` or `--type` to limit scope
- For large codebases, add `-m 50` to limit matches per file
- If output is excessive, narrow the search pattern or file scope
