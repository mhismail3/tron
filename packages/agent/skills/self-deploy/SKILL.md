---
name: "Self Deploy"
description: Deploy Tron server to production with crash-loop protection, startup self-test, auto-rollback, and APNS notifications.
version: "7.0.0"
tags: [deployment, devops, tron]
deniedTools: [SpawnSubagent]
---

# Self Deploy — Tron Deployment Skill

Deploy the Tron Rust server to production with automated safety guarantees.

## Architecture

Tron is a single Rust binary. One server on port **9847**. Deployment copies the release binary to `~/.tron/system/bin/tron` and restarts via a server-side HTTP API (the server exits gracefully after a delay, launchd restarts it with the new binary).

- **Server**: launchd-managed, port **9847**, binary at `~/.tron/system/bin/tron`
- **Dev mode**: `tron dev` stops prod, runs `cargo run` on the same port, restarts prod on exit
- **Build**: `cargo build --release` → `packages/agent/target/release/tron`
- **Service**: `com.tron.server` (launchd)
- **Deploy API**: `POST /deploy/restart` — returns immediately, server exits after delay

There is no separate beta/dev port. Dev takeover temporarily replaces prod on port 9847.

## 1. Status (Always Start Here)

```bash
~/.tron/system/deployment/tron-cli status
```

For deploy-specific status (binary path, sentinel, restart state):
```bash
curl -s http://localhost:9847/deploy/status | jq .
```

For deep infrastructure health (DB, auth, settings, disk, skills):
```bash
curl -s http://localhost:9847/health/deep | jq .
```

## 2. Deploy to Production

### Step-by-step (from within the agent):

1. **Pre-flight** — verify infrastructure:
   ```bash
   ~/Workspace/tron/scripts/tron preflight
   ```
   If preflight fails, use `@self-inspect` to diagnose before proceeding.

2. **Build and test** (visible output, can react to failures):
   ```bash
   cd ~/Workspace/tron/packages/agent && cargo build --release && cargo test --workspace
   ```
   If tests fail, STOP. Do NOT proceed to restart.

3. **Initiate restart** (returns immediately, server exits after delay):
   ```bash
   curl -s -X POST http://localhost:9847/deploy/restart \
     -H 'Content-Type: application/json' \
     -d '{"delayMs": 5000, "sessionId": "CURRENT_SESSION_ID"}'
   ```

4. **Tell the user**:
   > Deploy initiated. Server restarting in 5 seconds.
   > - The new binary will run 5 self-test checks on startup
   > - If any check fails, it will auto-rollback to the previous version
   > - If the binary crashes before self-test, it will auto-rollback after 3 attempts
   > - You'll receive a push notification when the deploy completes (or rolls back)
   > - After reconnect, verify: `curl localhost:9847/health/deep | jq .`

**IMPORTANT**: `tron deploy` will refuse to run if a dev takeover is active. Stop dev first (`Ctrl+C` or `~/Workspace/tron/scripts/tron dev --stop`).

### What happens after restart (automatic, no agent involvement):
1. **Crash-loop protection**: Startup attempt counter increments. After 3 failed starts → auto-rollback
2. **Self-test** (5 checks): database, settings, auth, binary, disk space
3. If self-test fails → immediate auto-rollback (before port binding)
4. If self-test passes → clear attempt counter, store results in sentinel
5. Server binds port and starts accepting connections
6. Sentinel marked "completed", `last-deployment.json` written
7. APNS push notification sent to all iOS devices
8. If a previous deploy was rolled back, pending notification is sent

## 3. Safety Guarantees

1. **Atomic binary install**: tmp → chmod → rename (no partial installs)
2. **Backup preserved**: `tron.bak` kept until deploy succeeds
3. **Crash-loop protection**: 3 startup attempts max, then auto-rollback
4. **Startup self-test**: DB, settings, auth, binary, disk checked before port binding
5. **Auto-rollback on self-test failure**: immediate, before accepting connections
6. **Push notification**: on both success AND rollback
7. **Audit trail**: `initiatedBy`, `selfTest` results in sentinel + `last-deployment.json`
8. **Sentinel state machine**: `restarting` → `completed`|`rolled_back`|`failed` (no re-triggering)

## 4. Error Handling

| Scenario | What Happens | Agent Action |
|----------|-------------|--------------|
| Build fails | cargo exits non-zero | Report errors to user |
| Tests fail | cargo test exits non-zero | Report failures to user |
| Server unreachable | curl fails | Check `~/.tron/system/deployment/tron-cli status`, try `~/.tron/system/deployment/tron-cli start` |
| Deploy already initiated | 409 Conflict | Wait or check `/deploy/status` |
| New binary crashes on startup | Auto-rollback after 3 attempts | Push notification sent, investigate |
| Self-test fails | Immediate auto-rollback | Push notification sent, investigate |
| Backup missing | Sentinel marked "failed" | Manual intervention required |
| Rollback binary also broken | Normal crash (no deploy loop) | Manual intervention required |
| Stuck sentinel (status=restarting) | `~/Workspace/tron/scripts/tron preflight` flags it | Use `@self-inspect deploy` to investigate |

## 5. Rollback

Restores `~/.tron/system/deployment/tron.bak` (only available immediately after a deploy).

```bash
nohup ~/.tron/system/deployment/tron-cli rollback --yes > /tmp/tron-rollback.log 2>&1 &
```

Run detached — rollback uses `scripts/tron` which restarts the launchd service.

## 6. Dev Server (Port Takeover)

Dev mode takes over port **9847** from production. It stops the launchd service, runs `cargo run --release` on the same port, and restarts production when dev exits.

| Action | Command |
|--------|---------|
| Start (takes over prod port) | `~/Workspace/tron/scripts/tron dev` |
| Build then start | `~/Workspace/tron/scripts/tron dev -b` |
| Build, test, then start | `~/Workspace/tron/scripts/tron dev -bt` |
| Stop dev and restart prod | `~/Workspace/tron/scripts/tron dev --stop` |
| Tail server log | `~/Workspace/tron/scripts/tron dev --log` |

## 7. Logs & Errors

| Action | Command |
|--------|---------|
| Recent logs (database) | `~/.tron/system/deployment/tron-cli logs` |
| Tail file log | `~/.tron/system/deployment/tron-cli logs -t` |
| Filter by level | `~/.tron/system/deployment/tron-cli logs -l error` |
| Search logs | `~/.tron/system/deployment/tron-cli logs -q "search term"` |
| Recent errors | `~/.tron/system/deployment/tron-cli errors` |
| Deployment result | `cat ~/.tron/system/deployment/last-deployment.json` |

## 8. Other Commands

| Command | Description |
|---------|-------------|
| `~/Workspace/tron/scripts/tron preflight` | Pre-deploy infrastructure validation |
| `~/Workspace/tron/scripts/tron install` | First-time setup: build, copy binary, create launchd plist, start service |
| `~/Workspace/tron/scripts/tron setup` | Project setup: check prerequisites, create dirs, build, symlink CLI |
| `~/.tron/system/deployment/tron-cli start` | Start launchd service |
| `~/.tron/system/deployment/tron-cli stop` | Stop launchd service |
| `~/.tron/system/deployment/tron-cli restart` | Stop then start service |
| `~/.tron/system/deployment/tron-cli login` | OAuth authentication with Claude (`--label` for multi-account) |
| `~/Workspace/tron/scripts/tron ci` | Run CI checks: fmt, check, clippy, test, doc |
| `~/Workspace/tron/scripts/tron bench` | Performance benchmarks (run, compare) |
| `~/Workspace/tron/scripts/tron uninstall` | Remove service and CLI (preserves data in `~/.tron/`) |

## 9. Quick Reference

| | Production | Dev Takeover |
|---|---|---|
| Port | 9847 | 9847 (same) |
| Health | `http://localhost:9847/health` | `http://localhost:9847/health` |
| Deep health | `http://localhost:9847/health/deep` | N/A |
| Deploy status | `http://localhost:9847/deploy/status` | N/A (not the deployed binary) |
| Binary | `~/.tron/system/bin/tron` | `cargo run --release` (source) |
| Database | `~/.tron/system/database/log.db` | `~/.tron/system/database/log.db` (same) |
| Managed by | launchd (`com.tron.server`) | Foreground process with EXIT trap |
| Log | `~/.tron/system/deployment/server.log` | stdout (or `tron dev --log` tails same file) |

## 10. Safety Rules

1. **Always start with `~/.tron/system/deployment/tron-cli status`.** Know what's running before changing anything.
2. **Run `~/Workspace/tron/scripts/tron preflight` before deploying.** Catches infrastructure issues early.
3. **Never skip tests** unless the user explicitly asks.
4. **Build and test first.** Run `cargo build --release && cargo test --workspace` as a separate step. Only call `/deploy/restart` after build+test succeed.
5. **Use `/deploy/restart` for agent deploys.** The server-side API returns the response before shutting down, so the agent can deliver a final message to the user.
6. **Include `sessionId` in deploy request.** Creates an audit trail of who deployed.
7. **Final message matters.** After initiating restart, your response reaches the user before disconnect. Include the safety guarantees in the message.
8. **Post-reconnect.** After deploy, verify with `curl localhost:9847/health/deep | jq .`.
9. **Rollback uses `tron-cli`.** Only `~/.tron/system/deployment/tron-cli rollback --yes` (via nohup) needs detached execution since it uses launchctl directly.
10. **No deploy during dev takeover.** `tron deploy` aborts if dev is active. Stop dev first.
