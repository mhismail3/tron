# Push Notifications (APNs)

Push notifications allow the agent to alert the iOS app when tasks complete or need attention.

## Architecture

Two delivery modes, selected at server startup:

```
Direct mode (developer machine with .p8 key):
  iOS App ──► Tron Server ──► api.push.apple.com

Relay mode (distributed builds, no .p8 needed):
  iOS App ──► Tron Server ──► Cloudflare Worker relay ──► api.push.apple.com
                               (holds .p8 key)
```

Selection priority: direct (.p8 on disk) > relay (build-time env vars) > disabled.

## Relay Mode (Default for Distributed Builds)

Users who install the Tron server get push notifications automatically — no credential setup required. The relay URL and HMAC secret are compiled into release builds from `~/.tron/system/auth.json`.

### Build Integration

The build scripts (`tron deploy`, `tron dev -b`) read relay credentials from auth.json:

```json
{
  "relay": {
    "url": "https://tron-push-relay.<subdomain>.workers.dev",
    "secret": "<shared HMAC secret>"
  }
}
```

These are passed as compile-time env vars (`TRON_RELAY_URL`, `TRON_RELAY_SECRET`) and baked into the binary via `option_env!()`. Users never see or configure these values.

### Deploying the Relay

The relay is a Cloudflare Worker at `packages/relay/` (see its README for full details):

```bash
cd packages/relay
npm install
npx wrangler login
npx wrangler deploy
# Set secrets (one-time):
cat ~/.tron/system/deployment/AuthKey_*.p8 | npx wrangler secret put APNS_KEY_P8
npx wrangler secret put APNS_KEY_ID       # 10-char key ID
npx wrangler secret put APNS_TEAM_ID      # 10-char team ID
npx wrangler secret put TRON_RELAY_SECRET  # same secret as in auth.json
```

### Environment Routing

The APNs environment (sandbox vs production) is determined per-device-token, not per-server. When the iOS app registers its token, it includes its environment. The relay routes each token to the correct APNs host automatically.

### Per-Build Bundle ID

Each scheme (Tron vs Tron Beta) ships with a distinct bundle ID — respectively `com.tron.mobile` and `com.tron.mobile.beta`. APNs requires the `apns-topic` header to match the bundle that issued each token, so the iOS app sends `Bundle.main.bundleIdentifier` with every `device.register` call. The server stores it in `device_tokens.bundle_id` and includes it in each relay request. The relay worker uses it as the `apns-topic` header, falling back to `env.APNS_BUNDLE_ID` only when the server doesn't supply one (legacy tokens registered before v006).

Tokens that surface `DeviceTokenNotForTopic` or `BadDeviceToken` are auto-deactivated so the DB self-heals — the iOS app re-registers with the correct bundle on the next launch.

### Runtime environment detection

The iOS app does NOT use `#if DEBUG` to decide the APNs environment. Compile-time flags are brittle: Xcode-rebuilt Prod-scheme apps still get Development provisioning profiles (Apple ID personal signing), which override the entitlements file's `aps-environment` from `production` to `development`. Reporting the wrong environment produces `BadDeviceToken` errors on every send.

Instead, [`APNsEnvironment.swift`](../Sources/Services/Infrastructure/APNsEnvironment.swift) parses `embedded.mobileprovision` at runtime and reads the `Entitlements.aps-environment` key that is *actually in force*. Results:

- Xcode-rebuilt (dev-signed) → `sandbox`, regardless of scheme.
- TestFlight / ad-hoc → whatever the distribution profile carries (typically `production`).
- App Store → falls back to `#if DEBUG` → `production` for release builds, since App Store binaries may not ship the profile.
- Simulator / malformed profile → `sandbox` fallback (sandbox rejects fewer tokens than production).

### Delivery model

Every `NotifyApp` tool call fans out to all active device tokens, grouped by `(environment, bundle_id)` so the relay picks the right APNs topic per batch. This is intentional: a single user may have the same app on multiple devices (iPhone + iPad), and all of them should receive the notification regardless of which specific device initiated the session. The environment and bundle-ID routing (above) already prevents cross-app mis-delivery on the same device.

## Direct Mode (Developer Setup)

For local development with direct APNs access (bypasses relay):

### Apple Developer Setup

1. [developer.apple.com/account](https://developer.apple.com/account) → Keys → Create APNs key → download `.p8`
2. Note the **Key ID** and **Team ID**

### Store Credentials

```bash
mv ~/Downloads/AuthKey_ABC123DEFG.p8 ~/.tron/system/deployment/
chmod 600 ~/.tron/system/deployment/AuthKey_*.p8

cat > ~/.tron/system/deployment/apns.json << 'EOF'
{
  "keyId": "ABC123DEFG",
  "teamId": "XYZ789TEAM",
  "bundleId": "com.tron.mobile",
  "environment": "sandbox"
}
EOF
```

### Xcode Setup

1. Target → Signing & Capabilities → **+ Capability** → **Push Notifications**

## iOS App Implementation

### Device Token Registration

```swift
// AppDelegate.swift
func application(_ application: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    pushNotificationService.deviceToken = token
    NotificationCenter.default.post(name: .deviceTokenDidUpdate, userInfo: ["token": token])
}
```

### Handling Notifications

```swift
// TronMobileApp.swift
.onReceive(NotificationCenter.default.publisher(for: .navigateToSession)) { notification in
    guard let userInfo = notification.userInfo else { return }
    container.deepLinkRouter.handle(notificationPayload: userInfo)
}
```

### Notification Payload

```json
{
  "aps": {
    "alert": {
      "title": "Task Complete",
      "body": "Your analysis is ready"
    },
    "sound": "default"
  },
  "sessionId": "sess_abc123",
  "eventId": "evt_xyz789"
}
```

## Configuration Reference

### Direct Mode (`~/.tron/system/deployment/apns.json`)

| Field | Description |
|-------|-------------|
| `keyId` | From Apple Developer Keys page |
| `teamId` | From Membership Details |
| `bundleId` | Must match Xcode target |
| `environment` | `sandbox` for dev, `production` for App Store |

### Relay Mode (Environment Variables)

| Variable | When Set | Description |
|----------|----------|-------------|
| `TRON_RELAY_URL` | Build time | Relay worker URL |
| `TRON_RELAY_SECRET` | Build time | HMAC shared secret |
| `TRON_RELAY_ENVIRONMENT` | Runtime (optional) | Override APNs environment (default: `production`) |

## Production Release

When releasing to App Store:

1. Ensure relay is deployed with production APNs credentials
2. Build with `TRON_RELAY_URL` and `TRON_RELAY_SECRET` set
3. Direct mode: change `apns.json` to `"environment": "production"`

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `BadDeviceToken` | Token invalid (stale or wrong env) | Auto-deactivated; re-registers on next launch |
| `DeviceTokenNotForTopic` | Token's bundle ≠ `apns-topic` | Auto-deactivated; fixed when iOS sends `bundleId` |
| `TopicDisallowed` | Cert/team doesn't own the bundle | Check APNs key permissions — **not** a token issue |
| `InvalidProviderToken` | JWT signing broken | Verify `keyId`, `teamId`, `.p8` key |
| `no valid aps-environment` | Missing entitlements | Add Push Notifications capability in Xcode |
| `Unregistered` (410) | Token expired | Auto-deactivated; re-registers on reconnect |
| `relay: invalid signature` | HMAC mismatch | Verify `TRON_RELAY_SECRET` matches Worker secret |
| `relay timeout` | Worker unreachable | Check Cloudflare Worker status |

### Auto-deactivation

`process_send_results` (in `server/platform/apns/push_helpers.rs`) deactivates tokens on terminal APNs failures:

- HTTP 410 (`Unregistered`) — device removed
- HTTP 400 `BadDeviceToken` — malformed or wrong environment
- HTTP 400 `DeviceTokenNotForTopic` — wrong bundle ID

Transient failures (403, 404, 429, 5xx, other 400 reasons including `TopicDisallowed`) do NOT deactivate — they're retried on the next `NotifyApp`.

### Debug Checklist

1. **Token not registering** — Check notification permissions, Push Notifications capability
2. **Notifications not received** — Verify environment matches, device token sent to server
3. **Relay mode not activating** — Check `TRON_RELAY_URL` is compiled in (`strings tron | grep relay`)
4. **Deep link not working** — Check notification payload includes sessionId

## Testing

Push notifications don't work on Simulator — use a physical device.

1. Background the app
2. Trigger NotifyApp tool from agent
3. Verify notification appears
4. Tap notification, verify deep link works
