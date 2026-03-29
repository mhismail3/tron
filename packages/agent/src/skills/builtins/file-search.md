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

Find files by name, extension, or pattern using `fd` (preferred) or `find`.
Always include `skill: "file-search"` in your Bash call when using this skill.

## fd (preferred)

`fd` is fast, respects .gitignore, and has sensible defaults.

**Common patterns:**
```bash
# Find files by name pattern
fd 'pattern'

# Find by extension
fd -e rs
fd -e ts -e tsx

# Find in a specific directory
fd 'config' src/

# Find directories only
fd -t d 'test'

# Find files only (excludes dirs)
fd -t f 'README'

# Include hidden files
fd -H '.env'

# Find by exact name
fd -g 'Cargo.toml'

# Limit depth
fd -d 3 'mod.rs'

# Exclude specific directories
fd -E node_modules -E dist 'index'

# Find and show file sizes
fd -e json --exec ls -lh {}
```

**Default exclusions:** .git, node_modules, and anything in .gitignore.

## find (fallback)

Use `find` when `fd` is unavailable or you need advanced filters.

```bash
# Find by name pattern
find . -name '*.rs' -type f

# Find modified in last 24 hours
find . -name '*.py' -mtime -1

# Find files larger than 1MB
find . -type f -size +1M

# Find and exclude directories
find . -name '*.ts' -not -path '*/node_modules/*' -not -path '*/.git/*'
```

## Decision Guide

| Need | Command |
|------|---------|
| Find files by extension | `fd -e ext` |
| Find files by name pattern | `fd 'pattern'` |
| Find directories | `fd -t d 'name'` |
| Find hidden/ignored files | `fd -H -I 'pattern'` |
| Find with size/time filters | `find` with `-size`/`-mtime` |
| Find in specific subtree | `fd 'pattern' path/` |
