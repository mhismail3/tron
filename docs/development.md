# Development

<!--
PURPOSE: Everything needed to develop, test, and deploy Tron.
AUDIENCE: Developers modifying the codebase.

AGENT MAINTENANCE:
- Update commands if scripts/tron changes
- Update port numbers if they change
- Add test cases when features are added
- Last verified: 2026-01-20
-->

## Commands

| Command | Purpose |
|---------|---------|
| `tron setup` | First-time project setup |
| `tron dev` | Build, test, start beta server |
| `tron deploy` | Build, test, deploy to production |
| `tron status` | Show service status |

## Setup

```bash
./scripts/tron setup
```

Installs Bun, dependencies, builds packages, creates config directories.

## Development Workflow

```bash
tron dev
```

Builds all packages, runs tests, starts beta server on:
- WebSocket: `localhost:8082`
- Health: `localhost:8083`

## Testing

```bash
bun run test           # Run all tests
bun run test:watch     # Watch mode
```

**Known Issue:** Vitest may fail 1 test file with heap memory error (pre-existing Vitest issue).

### Manual Test Sequence

```bash
# 1. Clean slate
rm -rf ~/.tron

# 2. Setup and start
./scripts/tron setup
tron dev

# 3. In another terminal
bun run dev:tui

# 4. Test interaction
"Hello, read the README.md file"

# 5. Test commands
/help
/context

# 6. Exit and verify
/exit
ls ~/.tron/db/
```

### Test Checklist

**Tools:**
- [ ] `read` returns file contents
- [ ] `write` creates files
- [ ] `edit` modifies files
- [ ] `bash` executes commands
- [ ] Dangerous commands blocked

**Sessions:**
- [ ] New session creates DB entry
- [ ] Resume works (`tron -c`)
- [ ] Graceful exit saves state

**Skills:**
- [ ] Load from `~/.tron/skills/`
- [ ] Load from `.claude/skills/`
- [ ] `@skill-name` reference works

## Production

### Initial Install

```bash
tron install
```

Creates launchd service, symlinks CLI to `~/.local/bin/tron`.

### Deploy Updates

```bash
git pull
tron deploy
```

Production runs on:
- WebSocket: `localhost:8080`
- Health: `localhost:8081`

### Service Management

```bash
tron status      # Status and health
tron start       # Start service
tron stop        # Stop service
tron restart     # Restart service
tron logs        # Query logs
tron rollback    # Revert to previous deploy
```

## Troubleshooting

### Port in Use

```bash
kill $(lsof -t -i :8082)
```

### Native Module Errors

```bash
cd node_modules/.bun/better-sqlite3@*/node_modules/better-sqlite3
rm -rf build
PYTHON=/opt/homebrew/bin/python3 npx node-gyp rebuild --release
```

### PATH Issues

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

## File Locations

| Location | Purpose |
|----------|---------|
| `~/.tron/db/` | SQLite databases |
| `~/.tron/skills/` | Global skills |
| `~/.tron/rules/` | Global context |
| `~/.tron/mods/apns/` | Push notification credentials |
| `.claude/skills/` | Project skills |
| `.claude/AGENTS.md` | Project context |

## Push Notifications (APNS)

Push notifications allow the agent to alert the iOS app when tasks complete or need attention.

### Apple Developer Setup

1. **Create App ID with Push Capability**
   - Go to [developer.apple.com/account](https://developer.apple.com/account) → Certificates, Identifiers & Profiles
   - Identifiers → Click **+** → App IDs → App
   - Bundle ID: `com.yourteam.TronMobile` (must match Xcode)
   - Enable **Push Notifications** capability
   - Register

2. **Create APNS Key**
   - Go to **Keys** → Click **+**
   - Name: `TronAPNS`
   - Enable **Apple Push Notifications service (APNs)**
   - Download the `.p8` file (one-time download!)
   - Note the **Key ID** (e.g., `ABC123DEFG`)

3. **Get Team ID**
   - Membership Details → Copy **Team ID**

4. **Store Credentials**
   ```bash
   mkdir -p ~/.tron/mods/apns
   mv ~/Downloads/AuthKey_ABC123DEFG.p8 ~/.tron/mods/apns/
   chmod 600 ~/.tron/mods/apns/AuthKey_*.p8

   cat > ~/.tron/mods/apns/config.json << 'EOF'
   {
     "keyId": "ABC123DEFG",
     "teamId": "XYZ789TEAM",
     "bundleId": "com.yourteam.TronMobile",
     "environment": "sandbox"
   }
   EOF
   ```

5. **Xcode Setup**
   - Open `TronMobile.xcodeproj`
   - Target → Signing & Capabilities → **+ Capability** → **Push Notifications**
   - Xcode regenerates provisioning profile automatically

### Configuration

| Field | Description |
|-------|-------------|
| `keyId` | From Apple Developer Keys page |
| `teamId` | From Membership Details |
| `bundleId` | Must match Xcode target |
| `environment` | `sandbox` for dev, `production` for App Store |

### Production Release

When releasing to App Store:
1. Change `config.json`: `"environment": "production"`
2. Build with Release-Prod configuration (uses production entitlements)

### Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `BadDeviceToken` | Environment mismatch | Match config environment to build type |
| `InvalidProviderToken` | Wrong credentials | Verify keyId, teamId, bundleId |
| `no valid aps-environment` | Missing entitlements | Add Push Notifications capability in Xcode |
| `Unregistered` | Token expired | App re-registers automatically on next connect |

### Architecture

```
iOS App                          Server
   │                               │
   ├─► Register device token ─────►│ Store in device_tokens table
   │                               │
   │   Agent calls NotifyApp ◄─────┤
   │                               │
   │◄── APNS push notification ◄───┤ HTTP/2 to api.push.apple.com
   │                               │
```

- Device tokens registered globally (any session can notify)
- Multiple agents can send notifications in parallel
- Tokens auto-invalidated on APNS 410 response
