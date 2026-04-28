---
name: "Self Deploy"
description: Contributor-only guidance for Tron release/deploy checks. Production Mac updates are notarized DMG replacement; no server-side deploy API exists.
version: "8.0.0"
tags: [deployment, devops, tron]
deniedTools: [SpawnSubagent]
---

# Self Deploy — Contributor Release Checks

Production Mac distribution is a notarized DMG. The installed app lives at `/Applications/Tron.app`, the server helper lives inside that app at `Contents/Library/LoginItems/Tron Server.app`, and registration is owned by `SMAppService`.

There is no production `/deploy/status` or `/deploy/restart` API. Do not try to restart the server through HTTP deploy endpoints, do not copy app bundles into `~/.tron/system/`, and do not place runtime locks in `~/.tron/system/deployment/`.

## Supported Checks

```bash
cd packages/agent
cargo fmt --all -- --check
cargo check --bin tron
cargo test --bin tron

cd ../mac-app
xcodegen generate
xcodebuild test -scheme TronMac -destination 'platform=macOS'
```

## Production Release Path

1. Build the Rust agent release binary.
2. Stage it with `packages/mac-app/scripts/bundle-agent.sh`.
3. Archive `Tron.app`.
4. Sign `Tron Server.app` first, then sign the outer `Tron.app`.
5. Notarize and staple the DMG.
6. Users replace `/Applications/Tron.app` from the DMG.

## Runtime Layout

| Purpose | Path |
|---|---|
| Distributed app | `/Applications/Tron.app` |
| Server helper | `/Applications/Tron.app/Contents/Library/LoginItems/Tron Server.app` |
| Bundled LaunchAgent plist | `/Applications/Tron.app/Contents/Library/LaunchAgents/com.tron.server.plist` |
| Settings | `~/.tron/system/settings.json` |
| Auth | `~/.tron/system/auth.json` |
| Bearer token | `~/.tron/system/auth.json` (`bearerToken`) |
| Runtime locks | `~/.tron/system/run/` |
| Database | `~/.tron/system/database/log.db` |
| Contributor deploy artifacts | `~/.tron/system/deployment/` |

## Diagnostics

```bash
curl -s http://localhost:9847/health | jq .
curl -s http://localhost:9847/health/deep | jq .
```

Use `logs.recent` over WebSocket or direct SQLite queries against `~/.tron/system/database/log.db` for recent logs. The Mac app does not shell out to a bundled runtime CLI.
