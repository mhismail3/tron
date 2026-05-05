---
name: generate
description: "Generate interactive web UIs with @json-render/shadcn, displayed in-app via WebView"
version: "2.0.0"
tags: [ui, generate, webview, react, shadcn]
allowedTools:
  - Bash
  - Display
---

# Generate UI

Generate interactive web UIs using `@json-render/shadcn` (Vercel). You produce a JSON spec, the bundled toolchain renders it to a standalone HTML file with hydrated React, and the user sees it in an embedded WebView.

All toolchain files live in this skill's directory: `~/.tron/skills/generate/`.

## Pre-flight Check (once per session)

### 1. Check Node.js

```bash
which node && node --version
```

If not found, install via Homebrew:

```bash
brew install node
```

Requires Node.js >= 18.

### 2. Check rendering toolchain

```bash
node ~/.tron/skills/generate/render.mjs --version
```

If this fails with a module error, dependencies need installing:

```bash
cd ~/.tron/skills/generate && npm install
```

If `render.mjs` itself is missing, the skill directory is incomplete. Recreate the toolchain files (see Toolchain Setup below), then run `npm install`.

## Render Workflow

### 1. Get the spec format reference

On your first render, read the full component catalog prompt so you know the exact spec format, available components, and their props:

```bash
node ~/.tron/skills/generate/prompt.mjs
```

This outputs the complete json-render system prompt including all 36 available components, the spec format, state management, dynamic props, actions, and validation. Read it carefully before generating your first spec.

### 2. Create output directory

```bash
mkdir -p ~/.tron/workspace/artifacts/renders/<slug-name>
```

Use a descriptive slug (e.g., `todo-app`, `sales-dashboard`, `user-profile`).

### 3. Write the JSON spec

Write your spec to `~/.tron/workspace/artifacts/renders/<slug-name>/spec.json`.

The spec format uses `root` (element ID), `elements` (map of ID → component), and optionally `state`:

```json
{
  "title": "My Dashboard",
  "root": "main",
  "elements": {
    "main": {
      "type": "Card",
      "props": { "title": "Dashboard", "description": "Overview" },
      "children": ["stats", "actions"]
    },
    "stats": {
      "type": "Text",
      "props": { "text": "42 active users", "variant": "lead" }
    },
    "actions": {
      "type": "Button",
      "props": { "label": "Refresh", "variant": "default" }
    }
  }
}
```

**Key rules:**
- Every element MUST have `props` (use `{}` if no props needed)
- `children` is always an array of element IDs (never raw text)
- Text content goes in `props.text`, not `children`
- Use `state` + dynamic props (`$state`, `$bindState`) for interactive UIs
- Use `repeat` for dynamic lists backed by state arrays

### 4. Render to HTML

```bash
node ~/.tron/skills/generate/render.mjs ~/.tron/workspace/artifacts/renders/<slug-name>/spec.json ~/.tron/workspace/artifacts/renders/<slug-name>/index.html
```

This produces a standalone HTML file with:
- Server-rendered HTML (fast initial paint)
- Tailwind CSS via CDN
- Client-side hydration for interactivity (React 19 via esm.sh)

### 5. Start HTTP server

**CRITICAL: The server is long-running. Mishandling this WILL block your entire session.**

Rules:
- NEVER run a server as a foreground command
- NEVER chain server startup with other commands using `&&`, `;`, or newlines
- Use TWO separate Bash calls: one to start, one to verify

**Step 5a — Start the server (Bash call 1):**

Pick a port (start at 8170, increment if in use). Use `python3` (always on macOS, no npm needed):

```bash
python3 -m http.server 8170 --directory ~/.tron/workspace/artifacts/renders/<slug-name> > /tmp/tron-serve-<slug-name>.log 2>&1 & echo $! > /tmp/tron-serve-<slug-name>.pid && echo "started pid=$(cat /tmp/tron-serve-<slug-name>.pid)"
```

This backgrounds the server immediately and prints the PID. The Bash call returns instantly.

**Step 5b — Verify it's running (Bash call 2):**

```bash
sleep 1 && curl -s -o /dev/null -w "%{http_code}" http://localhost:8170/index.html
```

Expect `200`. If the port was taken (connection refused), kill the old PID, pick a different port, and retry step 5a.

### 6. Get the Tailscale IP and build the URL

**CRITICAL: The iOS device CANNOT reach `localhost` on the Mac server. You MUST use the Tailscale IP. NEVER pass `localhost` to the Display tool — the WebView runs on the phone.**

```bash
python3 -c "import pathlib,tomllib; p=pathlib.Path.home()/'.tron/profiles/user/profile.toml'; data=tomllib.loads(p.read_text()) if p.exists() else {}; print(data.get('settings',{}).get('server',{}).get('tailscaleIp',''))"
```

If the Tailscale IP is empty or missing, tell the user: "Tailscale IP is not configured. The UI won't load on your device. Set `settings.server.tailscaleIp` in `~/.tron/profiles/user/profile.toml`."

The display URL is: `http://<tailscale-ip>:<port>`

### 7. Display in app

```
Display(type="webview", url="http://<tailscale-ip>:<port>", title="<name>")
```

This opens an interactive WebView in the iOS app's detail sheet.

## Iteration

To update the UI:

1. Write the updated spec to the same `spec.json`
2. Re-run `render.mjs` (overwrites `index.html`)
3. Call `Display(type="webview", ...)` again with the same URL — the browser refreshes

The HTTP server auto-serves the updated files.

## Available Components (36)

**Layout:** Card, Stack, Grid, Separator
**Navigation:** Tabs, Accordion, Collapsible, Pagination
**Overlay:** Dialog, Drawer, Tooltip, Popover, DropdownMenu
**Content:** Heading, Text, Image, Avatar, Badge, Alert, Carousel, Table
**Feedback:** Progress, Skeleton, Spinner
**Input:** Button, Link, Input, Textarea, Select, Checkbox, Radio, Switch, Slider, Toggle, ToggleGroup, ButtonGroup

For full prop definitions and examples, run `node ~/.tron/skills/generate/prompt.mjs`.

## Backend UIs (auto-sandbox)

When the generated UI needs a backend API (data fetching, form submission, etc.):

1. Use the **Sandbox** skill to create a container with published ports
2. Install dependencies and start the backend server inside the container
3. Generate the frontend JSON spec with API URLs pointing at the container's Tailscale IP and port
4. Render and display as above

The sandbox provides full isolation — the generated frontend talks to the containerized backend over the network.

## Cleanup

Stop a running server by its PID file:

```bash
kill $(cat /tmp/tron-serve-<slug-name>.pid) 2>/dev/null && rm -f /tmp/tron-serve-<slug-name>.pid
```

Or kill by port:

```bash
kill $(lsof -t -i:<port>) 2>/dev/null
```

Render files persist at `~/.tron/workspace/artifacts/renders/<name>/` across sessions.

**Always clean up servers when done.** If the user ends the conversation or you're finished with the UI, stop the server.

## Toolchain Setup


If the toolchain files are missing from this skill directory, recreate them:

**`~/.tron/skills/generate/package.json`:**
```json
{
  "name": "tron-json-render",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "dependencies": {
    "@json-render/core": "^0.16.0",
    "@json-render/react": "^0.16.0",
    "@json-render/shadcn": "^0.16.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0"
  }
}
```

Then install: `cd ~/.tron/skills/generate && npm install`

The `render.mjs` and `prompt.mjs` scripts should also be present in this directory. If missing, they need to be recreated — see the source files alongside this SKILL.md.

## Gotchas
