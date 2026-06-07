# Push Notifications (APNs)

Push notifications let the agent alert the iOS app when background work completes, fails, or needs attention.

## Architecture

Tron uses one production push path:

```text
iOS App -> Tron Server -> Cloudflare Worker relay -> api.push.apple.com
                             (owns APNs signing credentials)
```

The local server never reads Apple `.p8` keys and never creates an APNs config directory under `~/.tron/internal/`. If relay config is absent, `notifications::send` uses the stub delegate and reports that push delivery is disabled. If relay config is present but no active device token is registered, `notifications::send` returns a warning instead of claiming delivery.

## Relay Configuration

Distributed server builds receive the relay URL and HMAC secret as compile-time environment variables:

| Variable | When Set | Description |
|----------|----------|-------------|
| `TRON_RELAY_URL` | Build time, runtime override allowed | Cloudflare Worker URL |
| `TRON_RELAY_SECRET` | Build time, runtime override allowed | HMAC shared secret used to sign relay requests |
| `TRON_RELAY_ENVIRONMENT` | Runtime optional | Default APNs environment for relay metadata; token rows still carry their own environment |

Release users do not configure these values. The Mac DMG workflow reads `TRON_RELAY_URL` and `TRON_RELAY_SECRET` from GitHub Actions secrets while building the bundled server, and uses `TRON_RELAY_ENVIRONMENT=production`. Developer builds may set the same variables in the shell, or place them in the ignored `packages/mac-app/.env.local`; both `packages/mac-app/scripts/bundle-agent.sh` and `scripts/tron dev` load that file before compiling the helper. Relay config is never read from `~/.tron/profiles/auth.json`.

## Relay Deployment

The relay Worker lives at `packages/relay/`. Its secrets belong in Cloudflare, not on the user's machine:

```bash
cd packages/relay
npm install
npx wrangler login
npx wrangler deploy
npx wrangler secret put APNS_KEY_P8
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put TRON_RELAY_SECRET
```

The `TRON_RELAY_SECRET` value must match the secret compiled into the server build.

## Token Routing

The APNs environment is determined per device token. The iOS app reads the effective `aps-environment` entitlement from `embedded.mobileprovision` and sends that value with each `device.register` call.

APNs device tokens are opaque variable-length bytes. The iOS app forwards the token as lowercase hex without assuming a 32-byte/64-character length, and `device::register` accepts bounded even-length hex tokens. This matches Apple's `didRegisterForRemoteNotificationsWithDeviceToken` contract and keeps simulator and future APNs token lengths from failing registration.

Each iOS scheme has its own bundle ID: `com.tron.mobile` for production and `com.tron.mobile.beta` for beta. APNs requires the `apns-topic` header to match the bundle that issued each token, so the iOS app also sends `Bundle.main.bundleIdentifier`. The server stores that in `device_tokens.bundle_id` and sends relay batches grouped by `(environment, bundle_id)`.

## Delivery Model

Every `notifications::send` invocation fans out to all active device tokens for the user. A user with the same app on multiple devices should receive the same notification everywhere. Routing by environment and bundle ID prevents beta/prod cross-delivery.

Tokens that return `DeviceTokenNotForTopic`, `BadDeviceToken`, or `Unregistered` are deactivated so the database self-heals; the iOS app re-registers on next launch.

Foreground iOS notification state is also driven by `/engine` stream events. When a `notifications::send` capability completion arrives over the active engine stream, the app refreshes the notification inbox through `notifications::list`; APNs remains the background delivery transport.

## iOS Implementation

Device token registration:

```swift
func application(_ application: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    pushNotificationService.deviceToken = token
    NotificationCenter.default.post(name: .deviceTokenDidUpdate, userInfo: ["token": token])
}
```

After an active server is paired, the iOS app checks the local notification
permission. A clean shell launch without an active paired server returns before
requesting OS notification authorization, so first-run/empty-shell screenshots
do not show a product prompt over the primitive UI. If the status is
`notDetermined` after pairing, iOS asks for permission and then registers with
APNs. The App settings page exposes the same control for manual repair: App ->
Push Notifications shows `Allow`, `Register`, `Enabled`, or `Settings` based on
the local OS state. After APNs returns a token, the thin client sends one
canonical `device::register` engine invocation with the token, bundle ID, and
APNs environment. The server stores that routing metadata in `device_tokens` and
all later delivery is engine-owned. Concurrent APNs callbacks and
reconnect-triggered permission checks are deduplicated in-flight on the client;
durable identity and idempotent upsert semantics still live on the server.

Notification handling:

```swift
.onReceive(NotificationCenter.default.publisher(for: .navigateToSession)) { notification in
    guard let userInfo = notification.userInfo else { return }
    container.deepLinkRouter.handle(notificationPayload: userInfo)
}
```

Payload shape:

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

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `Push service is not configured` | Local server was built or launched without `TRON_RELAY_URL` / `TRON_RELAY_SECRET` | Add both keys to `packages/mac-app/.env.local` or export them, then rebuild/restart with `tron dev -b` or the Mac bundle script |
| `no active iOS device tokens are registered` | APNs relay exists, but the iOS app has not granted notification permission or has not registered a token with the server | Keep the app connected after pairing so it can request permission and register; if needed open App → Push Notifications, grant permission/register, and confirm `device_tokens` has an active row |
| `BadDeviceToken` | Token invalid or wrong environment | Auto-deactivated; app re-registers on next launch |
| `DeviceTokenNotForTopic` | Token bundle does not match `apns-topic` | Auto-deactivated; app re-registers with current bundle |
| `TopicDisallowed` | Worker APNs credentials do not own the bundle | Check Cloudflare APNs secrets and Apple key permissions |
| `InvalidProviderToken` | Worker APNs signing failed | Verify Worker APNs key ID, team ID, and private key secret |
| `no valid aps-environment` | Missing push entitlement | Add Push Notifications capability in Xcode |
| `Unregistered` (410) | Token expired | Auto-deactivated; app re-registers on reconnect |
| `relay: invalid signature` | HMAC mismatch | Verify server `TRON_RELAY_SECRET` matches Worker secret |
| `relay timeout` | Worker unreachable | Check Cloudflare Worker status |

Push notifications require a physical device; Simulator does not receive APNs pushes.
