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

Tron is a single Rust binary. One server on port **9847**. Deployment copies the release binary into the app bundle at `~/.tron/system/Tron.app/` and restarts via a server-side HTTP API (the server exits gracefully after a delay, launchd restarts it with the new binary).

- **Server**: launchd-managed, port **9847**, binary at `~/.tron/system/Tron.app/Contents/MacOS/tron`
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

## 9. Code Signing & Notarization

Production deploys (`tron deploy`, `tron install`) sign the app bundle with the best-available identity, then notarize + staple it via Apple's notary service. This makes macOS TCC permissions (Screen Recording, Accessibility, Full Disk Access, System Audio) persist across deploys and lets distributed binaries pass Gatekeeper without warnings.

**Signing tiers** (automatic, best-available):
1. Developer ID Application cert — preferred; required for notarization and for TCC persistence across distributed updates
2. Apple Development cert — works for TCC persistence on the local machine but cannot be notarized
3. Ad-hoc (no cert) — dev-only fallback; TCC re-prompts on every rebuild because the signature hash changes

**One-time setup per developer machine** (required for notarization). End users who only install a distributed binary never do any of this.

**Step 1: Install a Developer ID Application certificate in the login Keychain.**

First check if one is already there:

```bash
security find-identity -v -p codesigning
```

If you see a line like `"Developer ID Application: NAME (TEAMID)"`, skip to Step 2 — note the `TEAMID` in parentheses, you'll need it.

Otherwise, pick one of these paths:

- **Option A — Import a `.p12` from another Mac that already has the cert.** On the source Mac, open Keychain Access → login → My Certificates → right-click "Developer ID Application: ..." → Export → save as `.p12` with an export password. Transfer the `.p12` over a secure channel (it contains a private key — never unencrypted email/Slack; use 1Password, an encrypted drive, or AirDrop). On the target Mac, double-click the `.p12` and enter the export password. This is the fastest path if you already have the cert somewhere.
- **Option B — Create a fresh cert via the Apple Developer portal.** Requires a paid Apple Developer Program membership. On the target Mac: Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority → enter your email → "Saved to disk" → generates a `.certSigningRequest` file. Upload it at https://developer.apple.com/account/resources/certificates/list → "+" → Developer ID Application → upload the CSR → download the resulting `.cer` → double-click to install. The private key stays on this Mac in its Keychain. Apple allows multiple Developer ID Application certs per team, so each dev can have their own without sharing private keys.

Verify the cert is usable:

```bash
security find-identity -v -p codesigning
```

Should now show `"Developer ID Application: <NAME> (<TEAMID>)"`. Note the `TEAMID` for Step 2.

**Step 2: Generate an app-specific password** at https://appleid.apple.com → Sign-In and Security → App-Specific Passwords → "+" → label it "tron notarization". Copy the password immediately; Apple will not show it again.

**Step 3: Store notarytool credentials in Keychain:**

```bash
xcrun notarytool store-credentials "tron-notarize" \
  --apple-id <your-apple-id-email> \
  --team-id <TEAMID>
```

It will prompt for the app-specific password from Step 2. Verify with:

```bash
xcrun notarytool history --keychain-profile tron-notarize
```

Should return without any credential error (history may be empty — that's fine).

After these three steps, all future `tron deploy` and `tron install` runs on this machine will automatically sign and notarize.

**Dev builds** (`tron dev`) sign but do not notarize — notarization takes 1-5 minutes per submission and would destroy iteration velocity. Dev builds aren't distributed, and TCC persistence works via signing alone.

**Rollback and recovery paths** (`cmd_deploy` rollback, `ensure_prod_binary` restore) sign but do not notarize — these are emergency recovery flows that must stay fast. The next normal deploy re-notarizes.

**Verify signing**: `codesign -dvvv ~/.tron/system/Tron.app` — should show `Authority=Developer ID Application: ...`, not `Signature=adhoc`.
**Verify notarization**: `spctl --assess --type execute -vvv ~/.tron/system/Tron.app` — should show `accepted` and `source=Notarized Developer ID`.
**Verify stapled ticket** (works offline): `xcrun stapler validate ~/.tron/system/Tron.app`.

Notarization failures are **non-fatal** — deploy still succeeds, TCC still works via signing. On Apple rejection, `notarize_bundle` in `scripts/tron-lib.sh` prints the submission ID with the exact `xcrun notarytool log <id> --keychain-profile tron-notarize` command for investigation.

## 10. Quick Reference

| | Production | Dev Takeover |
|---|---|---|
| Port | 9847 | 9847 (same) |
| Health | `http://localhost:9847/health` | `http://localhost:9847/health` |
| Deep health | `http://localhost:9847/health/deep` | N/A |
| Deploy status | `http://localhost:9847/deploy/status` | N/A (not the deployed binary) |
| Binary | `~/.tron/system/Tron.app/Contents/MacOS/tron` | `cargo run --release` (source) |
| Database | `~/.tron/system/database/log.db` | `~/.tron/system/database/log.db` (same) |
| Managed by | launchd (`com.tron.server`) | Foreground process with EXIT trap |
| Log | `~/.tron/system/deployment/server.log` | stdout (or `tron dev --log` tails same file) |

## 11. Safety Rules

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

## Gotchas
