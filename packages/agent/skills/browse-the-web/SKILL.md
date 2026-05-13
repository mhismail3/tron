---
name: "Browse the Web"
description: "Browser automation via the agent-browser CLI — navigate, snapshot, interact, screenshot, scrape, and export"
version: "1.0.0"
tags: [browser, automation, web, scraping]
allowedTools:
  - Bash
  - Display
---

# Browser Automation via agent-browser CLI

You are controlling a headless Chrome browser through the `agent-browser` CLI tool. Every browser action is a Bash command. Execute them ONE AT A TIME sequentially — never run multiple browser commands in parallel. Wait for each command to complete before starting the next. Parallel execution causes race conditions because commands share a browser session.

---

## CRITICAL FIRST STEP: Start Display Streaming

**Before running ANY browser command**, you MUST call the Display tool to open a live viewport stream so the user can watch what you're doing:

```
Display(type="stream", action="start", streamId="browser", title="Browser")
```

Do this ONCE at the beginning. Do NOT skip this step. Without it, the user cannot see the browser and has no visibility into your actions.

---

## Setup: Finding or Installing agent-browser

Before your first browser command, ensure `agent-browser` is available.

### Step 1: Check if already installed

```bash
which agent-browser
```

### Step 2: If not found, check AGENT_BROWSER_PATH

```bash
echo "$AGENT_BROWSER_PATH"
```

If that variable is set and points to a valid file, use that path directly.

### Step 3: If still not found, install via Homebrew

```bash
brew install agent-browser
```

If Homebrew is not installed, tell the user:
> "agent-browser is not installed and Homebrew is not available. Please install agent-browser manually or install Homebrew first (https://brew.sh), then run `brew install agent-browser`."

### Step 4: Ensure Chrome for Testing is downloaded

After locating the binary, run:

```bash
agent-browser install
```

This downloads Chrome for Testing if not already present. It's idempotent — fast no-op if already installed. If this fails, the browser won't work; tell the user to retry or check their network.

### Step 5: Verify

```bash
agent-browser --version
```

---

## Session Management

Every command requires `--session <id>` to identify which browser session to use.

- **Single-browser workflows**: Use `--session main`
- **Multi-tab workflows**: Use descriptive names like `--session search`, `--session docs`
- Sessions persist until explicitly closed with `agent-browser close --session <id>`
- To show a visible browser window on the user's machine, add `--headed` to commands

---

## Complete CLI Reference

### Navigation

| Command | Timeout | Description |
|---------|---------|-------------|
| `agent-browser open <url> --session <id>` | 30s | Navigate to URL |
| `agent-browser back --session <id>` | 30s | Go back in browser history |
| `agent-browser forward --session <id>` | 30s | Go forward in browser history |
| `agent-browser reload --session <id>` | 30s | Reload current page |

### Observation

| Command | Timeout | Description |
|---------|---------|-------------|
| `agent-browser snapshot -i --json --session <id>` | 15s | Get accessibility tree with interactive element refs (`@e1`, `@e2`). This is the PRIMARY way to understand page structure. Always use `-i` for interactive annotations and `--json` for structured output. |
| `agent-browser screenshot <path> --json --session <id>` | 15s | Capture viewport screenshot to file. Use a temp path like `/tmp/tron_screenshot_$(date +%s).png` |
| `agent-browser get text <selector> --json --session <id>` | 15s | Extract text content from an element |
| `agent-browser get attr <selector> <attribute> --json --session <id>` | 15s | Get an attribute value (e.g., `href`, `src`, `value`) |
| `agent-browser get url --json --session <id>` | 5s | Get current page URL |

### Interaction

| Command | Timeout | Description |
|---------|---------|-------------|
| `agent-browser click <selector> --session <id>` | 15s | Click an element |
| `agent-browser fill <selector> "<value>" --session <id>` | 15s | Clear field, then fill with value |
| `agent-browser type <selector> "<text>" --session <id>` | 15s | Append text to element (does NOT clear first) |
| `agent-browser select <selector> "<value>" --session <id>` | 15s | Select a dropdown option by value |
| `agent-browser hover <selector> --session <id>` | 15s | Hover over element (triggers tooltips, dropdown menus) |
| `agent-browser press <key> --session <id>` | 15s | Press keyboard key: `Enter`, `Tab`, `Escape`, `ArrowDown`, `ArrowUp`, `Space`, `Backspace`, `Delete`, etc. |

#### Slow typing (for autocomplete / search-as-you-type)

When you need character-by-character input (e.g., search boxes with live suggestions), use the two-step focus + keyboard approach:

```bash
agent-browser focus <selector> --session <id>
agent-browser keyboard type "<text>" --session <id>
```

### Waiting

| Command | Timeout | Description |
|---------|---------|-------------|
| `agent-browser wait <selector> --session <id>` | 30s | Wait for element to appear in DOM |
| `agent-browser wait <timeout_ms> --session <id>` | varies | Wait a fixed duration in milliseconds |

### Scrolling

```bash
agent-browser scroll <direction> <amount> --session <id>
```

- **direction**: `up`, `down`, `left`, `right` (only these four are valid)
- **amount**: pixels (default: 500)

Examples:
```bash
agent-browser scroll down 500 --session main
agent-browser scroll up 200 --session main
```

### Export

```bash
agent-browser pdf <path> --session <id>
```

Exports the current page as PDF. 30s timeout.

### Session Control

```bash
agent-browser close --session <id>
```

Closes the browser session and releases resources. Always clean up when done.

---

## Selector Rules

Selectors identify which element to interact with. Two types are supported:

### Element references (from snapshot)

When you run `snapshot`, the output includes annotated element refs like `@e1`, `@e2`, `@e42`. Use these directly:

```bash
agent-browser click @e5 --session main
agent-browser fill @e12 "hello" --session main
```

If you have a bare ref without the `@` prefix (like `e5`), you MUST add the `@` prefix: `@e5`.

### CSS selectors

Standard CSS selectors work as-is:

```bash
agent-browser click "#submit-btn" --session main
agent-browser fill ".search-input" "query" --session main
agent-browser get text "h1.title" --session main
agent-browser click "[data-testid='login']" --session main
agent-browser hover "nav > ul > li:nth-child(2)" --session main
```

**Shell quoting**: Always quote selectors containing special characters (`#`, `.`, `[`, `]`, `>`, `:`, spaces) to prevent shell interpretation.

---

## Recommended Workflows

### Basic page interaction

```bash
# 1. Start live stream (display capability, not shell)
# Display(type="stream", action="start", streamId="browser", title="Browser")

# 2. Navigate
agent-browser open "https://example.com" --session main

# 3. Understand page structure
agent-browser snapshot -i --json --session main

# 4. Interact based on snapshot refs
agent-browser click @e5 --session main

# 5. Verify result
agent-browser snapshot -i --json --session main
```

### Form filling

```bash
agent-browser open "https://example.com/form" --session main
agent-browser snapshot -i --json --session main
# Identify form fields from snapshot output
agent-browser fill @e3 "John Doe" --session main
agent-browser fill @e4 "john@example.com" --session main
agent-browser select @e5 "US" --session main
agent-browser click @e7 --session main          # submit button
agent-browser wait ".success-message" --session main
agent-browser snapshot -i --json --session main  # verify success
```

### Search with autocomplete

```bash
agent-browser open "https://example.com" --session main
agent-browser snapshot -i --json --session main
# Use slow typing for autocomplete
agent-browser focus @e2 --session main
agent-browser keyboard type "search query" --session main
agent-browser wait ".suggestions" --session main
agent-browser snapshot -i --json --session main  # see suggestions
agent-browser click @e15 --session main          # pick a suggestion
```

### Data scraping

```bash
agent-browser open "https://example.com/article" --session main
agent-browser get text "h1" --json --session main
agent-browser get text "article.body" --json --session main
agent-browser get attr "img.hero" "src" --json --session main
agent-browser get attr "a.author" "href" --json --session main
```

### Multi-page navigation

```bash
agent-browser open "https://example.com/page1" --session main
# ... do work ...
agent-browser open "https://example.com/page2" --session main
# ... do work ...
agent-browser back --session main  # return to page1
agent-browser forward --session main  # back to page2
```

### Page export

```bash
agent-browser open "https://example.com/report" --session main
agent-browser wait "#report-loaded" --session main
agent-browser pdf "/tmp/report.pdf" --session main
```

---

## Error Handling

| Error | Cause | Recovery |
|-------|-------|----------|
| Non-zero exit code | Command failed | Read stderr output for details |
| "element not found" | Selector doesn't match any element | Take a fresh `snapshot -i --json` and re-examine the page structure. The page may have changed. |
| Command timeout | Page or element didn't load in time | Use `wait <selector>` or `wait <ms>` first, then retry the action |
| "session not found" | Session was closed or never created | Start fresh with `agent-browser open <url> --session <id>` |
| Browser crash | agent-browser process died | Run `agent-browser open <url> --session <id>` to restart with a new session |
| "agent-browser not found" | Binary not on PATH | Run through the installation steps above |
| `agent-browser install` fails | Chrome for Testing download failed | Check network, retry. If persistent, tell user to check `~/.cache/agent-browser/` |

### Recovery pattern

When an interaction fails:
1. Take a new snapshot: `agent-browser snapshot -i --json --session main`
2. Re-examine the page — it may have changed (modals, redirects, dynamic content)
3. Find the correct selector from the new snapshot
4. Retry the action with the updated selector

---

## Cleanup

When you're done with browser automation:

1. Close the browser session:
   ```bash
   agent-browser close --session main
   ```

2. Stop the display stream (display capability):
   ```
   Display(type="stream", action="stop", streamId="browser")
   ```

Always clean up, even if errors occurred. If you used multiple sessions, close each one.

## Gotchas
