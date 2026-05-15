---
name: "Sandbox"
description: Create and manage sandboxed Linux containers using Apple's container CLI. Create, execute commands, manage lifecycle, and inspect logs.
version: "1.0.0"
tags: [containers, sandbox, devops]
deniedContracts: [agent::spawn_subagent]
---

# Sandbox — Container Management Skill

Manage sandboxed Linux containers via Apple's `container` CLI on macOS 26+ Apple Silicon.

**Containers are your workshop.** Use them aggressively — not just for "safety" but as your primary way of doing real work that goes beyond reading and writing files. Need a tool that isn't installed? Container. Need to run something you're not 100% sure about? Container. Need to stand up a service, process data, build something interactive? Container. The host machine stays clean; the containers are yours to use, break, rebuild, and throw away. Default to containment: if you're reaching for `apt-get install` or `pip install` on the host, stop and spin up a container instead.

**Containers are single-use.** Each container serves exactly one purpose. Never repurpose or reuse a container for a different task. Need something new? Create a new container. This keeps the sandbox dashboard accurate and prevents stale state from polluting new work. Containers are cheap — always create a fresh one.

## When to Use Containers

**Default to containers** for anything that installs software, runs unfamiliar code, or produces side effects you wouldn't want on the host:

- **Ephemeral processing.** Need a tool that isn't on the host? Spin up a fresh container, install it, use it, tear it down. Examples: parse a PDF with Python + pdfplumber, convert media with ffmpeg, analyze data with pandas/numpy, process documents with pandoc or LibreOffice.
- **Running services.** Start databases, web servers, API backends — anything that listens on a port. Interact via exec (curl, psql, redis-cli, etc.) from inside the container.
- **Tool augmentation.** When you need capabilities the host doesn't have — different language runtimes, system libraries, CLI tools — a container gives you a full Linux userspace.
- **Clean builds and testing.** Verify that something works from scratch in a clean environment, without relying on the host's installed packages.

### User-facing web apps and UIs

When you build something the user should see and interact with — a dashboard, a form, a visualization, a prototype — serve it from a container and open it on their phone. The container's mapped port is reachable at the same IP address the iOS app uses to connect to this server. **Always use OpenURL** to push the URL to the user's in-app browser — don't just tell them the URL.

The pattern:
1. Create with ports (e.g. `--publish 3000:3000`) and a descriptive name
2. Exec: install dependencies, scaffold the app, write code — all in `/workspace`
3. Exec with `--detach`: start the server **bound to 0.0.0.0**
4. Exec: verify it's running (`curl -s http://localhost:3000`)
5. Get the machine's Tailscale IP from `settings.server.tailscaleIp` in `~/.tron/profiles/user/profile.toml` — always use this for OpenURL, never `hostname` or `.local` addresses
6. OpenURL with `http://{tailscale-ip}:3000`
7. **Keep the container running.** Don't stop or remove it — the user is actively using it. Only clean up when they ask.

## Pre-flight Check

**MANDATORY.** Execute these steps before the first container operation in every session. Do not skip any step. Do not proceed past a failed step.

### Step 1 — Verify the `container` CLI is installed

```bash
which container && container --version
```

**If `container` is found**: note the version and continue to Step 2.

**If `container` is not found**: install it.

First, confirm Homebrew is available:
```bash
which brew
```

If `brew` is not found, stop and tell the user:
> "Apple's `container` CLI requires Homebrew to install. Install Homebrew from https://brew.sh, then re-run this skill. Alternatively, install the `container` CLI manually from https://github.com/apple/container/releases."

Do not proceed.

If `brew` is available, install:
```bash
brew install container
```

If the install fails, check the error output:
- **Xcode too old** (`Xcode >= 26.0` error) → tell the user to update Xcode from the App Store
- **macOS too old** (`macOS >= 26` error) → tell the user their macOS version does not support Apple containers
- **Any other failure** → show the full error output and stop

After a successful install, verify:
```bash
which container && container --version
```

If this still fails, stop and report the error. Do not proceed.

### Step 2 — Ensure the container daemon is running

Test if the daemon is already running:
```bash
container list --all 2>&1
```

**If exit code is 0**: the daemon is running. Continue to Step 3.

**If it fails** (e.g. "daemon not running", connection refused, or any non-zero exit): start the daemon.

Preferred — persistent across reboots:
```bash
brew services start container
```

Wait 3 seconds for the daemon to initialize, then test again:
```bash
sleep 3 && container list --all 2>&1
```

If `container list --all` still fails after `brew services start`, fall back to session-only mode:
```bash
container system start &
sleep 5 && container list --all 2>&1
```

Note: `container system start` runs in the foreground, so background it with `&` and give it time to initialize.

If `container list --all` still fails after both attempts, stop and report the full error output to the user. Common causes:
- **Virtualization not enabled** → the user may need to enable virtualization in system settings
- **Resource exhaustion** → not enough disk space or memory
- **Permission denied** → the user may need to grant permissions in System Settings > Privacy & Security

Do not proceed.

### Step 3 — Confirm readiness

Run a final end-to-end check:
```bash
container list --all --format json
```

This must return valid JSON (even if the containers array is empty). If it does, the pre-flight check passes. Proceed with the requested container work.

If this fails, stop and report the error. Do not proceed.

### Quick reference

After the first successful session, subsequent sessions typically only need:
```bash
which container && container list --all
```
If both succeed, skip the full pre-flight and proceed directly. Only run the full sequence if either command fails.

## 1. Create Container

```bash
container run --detach --name <name> --volume <host-path>:/workspace --publish <host-port>:<container-port> <image> sleep infinity
```

- Default image: `ubuntu:latest`
- Always mount the working directory at `/workspace`
- `sleep infinity` keeps it alive for interactive use
- CPU/memory limits: `--cpus <n>` `--memory <size>` (e.g. `512m`, `2g`)
- Multiple ports: repeat `--publish` flags
- Environment variables: `--env KEY=VALUE` (repeat for multiple)

Example:
```bash
container run --detach --name my-sandbox --volume ~/my-project:/workspace --publish 3000:3000 ubuntu:latest sleep infinity
```

## 2. Execute Commands

```bash
container exec <name> sh -c "<command>"
```

Wrap in `sh -c` to enable pipes, `&&`, redirects, and shell expansion.

Background process:
```bash
container exec --detach <name> sh -c "<command>"
```

Example:
```bash
container exec my-sandbox sh -c "apt-get update && apt-get install -y python3"
container exec my-sandbox sh -c "cd /workspace && python3 app.py"
```

## 3. Lifecycle

| Action | Command |
|--------|---------|
| Stop | `container stop <name>` |
| Start (stopped) | `container start <name>` |
| Remove | `container delete <name>` |

**IMPORTANT:** Containers must be stopped before they can be deleted. Always run `container stop <name>` before `container delete <name>`. Attempting to delete a running container will fail.

Example cleanup sequence:
```bash
container stop my-sandbox
container delete my-sandbox
```

## 4. List Containers

```bash
container list --all --format json
```

Shows all containers including stopped ones.

## 5. Logs

```bash
container logs <name>
container logs --tail 50 <name>
```

## 6. Registry

The iOS dashboard reads container state from `~/.tron/profiles/user/containers.json`. After creating or removing a container, update this file so the dashboard stays in sync.

**Structure:**
```json
{
  "containers": [
    {
      "name": "my-sandbox",
      "image": "ubuntu:latest",
      "createdAt": "2026-02-09T12:00:00.000Z",
      "createdBySession": "<session-id>",
      "workingDirectory": "~/my-project",
      "ports": ["3000:3000"],
      "purpose": "Python dev environment"
    }
  ]
}
```

After `container run`:
```bash
# Read current registry, add entry, write back
```

After `container delete`:
```bash
# Read current registry, remove entry by name, write back
```

Use `filesystem::read_file` to read the file and `process::run` with a small script for the atomic write.

## 7. Networking

Services inside the container must bind to `0.0.0.0`, not `localhost` or `127.0.0.1`.

```bash
# Python
container exec my-sandbox sh -c "python3 -m http.server 3000 --bind 0.0.0.0"

# Node.js
container exec my-sandbox sh -c "node server.js --host 0.0.0.0"

# Flask
container exec my-sandbox sh -c "flask run --host 0.0.0.0 --port 3000"
```

## 8. Key Mechanics

- **Workspace mount**: `/workspace` inside the container maps to the host path you specify with `--volume`. Files flow both ways — write a script on the host, exec it in the container; generate output in the container, read it from the host.
- **Each exec is a separate command.** No persistent shell session. Set environment variables per-call via `--env`.
- **Long-running processes**: Use `--detach` for servers and daemons — the process persists in the container after exec returns. Interact via subsequent exec calls.
- **Containers survive sessions.** The registry at `~/.tron/profiles/user/containers.json` tracks everything. Use `container list --all` to see what's running. Clean up with `container delete` when done.

## 9. Safety Rules

- Always use descriptive container names (project/purpose based)
- Clean up containers when done: stop first (`container stop <name>`), then delete (`container delete <name>`)
- **Never delete a running container** — always stop it first or the command will fail
- Don't expose privileged ports (< 1024) without the user asking
- Remove the registry entry when deleting a container
- Use `--volume` to share files rather than copying

## Gotchas
