# Push Notifications (APNS)

Push notifications allow the agent to alert the iOS app when tasks complete or need attention.

## Architecture

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

## Apple Developer Setup

### 1. Create App ID with Push Capability

1. Go to [developer.apple.com/account](https://developer.apple.com/account) → Certificates, Identifiers & Profiles
2. Identifiers → Click **+** → App IDs → App
3. Bundle ID: `com.yourteam.TronMobile` (must match Xcode)
4. Enable **Push Notifications** capability
5. Register

### 2. Create APNS Key

1. Go to **Keys** → Click **+**
2. Name: `TronAPNS`
3. Enable **Apple Push Notifications service (APNs)**
4. Download the `.p8` file (one-time download!)
5. Note the **Key ID** (e.g., `ABC123DEFG`)

### 3. Get Team ID

- Membership Details → Copy **Team ID**

### 4. Store Credentials on Server

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

### 5. Xcode Setup

1. Open `TronMobile.xcodeproj`
2. Target → Signing & Capabilities → **+ Capability** → **Push Notifications**
3. Xcode regenerates provisioning profile automatically

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

| Field | Description |
|-------|-------------|
| `keyId` | From Apple Developer Keys page |
| `teamId` | From Membership Details |
| `bundleId` | Must match Xcode target |
| `environment` | `sandbox` for dev, `production` for App Store |

## Production Release

When releasing to App Store:

1. Change `config.json`: `"environment": "production"`
2. Build with Release-Prod configuration
3. Ensure production entitlements are set

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `BadDeviceToken` | Environment mismatch | Match config environment to build type |
| `InvalidProviderToken` | Wrong credentials | Verify keyId, teamId, bundleId |
| `no valid aps-environment` | Missing entitlements | Add Push Notifications capability in Xcode |
| `Unregistered` | Token expired | App re-registers automatically on reconnect |

### Debug Checklist

1. **Token not registering**
   - Check notification permissions granted
   - Verify Push Notifications capability in Xcode
   - Check console for registration errors

2. **Notifications not received**
   - Verify server has valid APNS credentials
   - Check environment matches (sandbox vs production)
   - Verify device token was sent to server

3. **Deep link not working**
   - Check notification payload includes sessionId
   - Verify DeepLinkRouter handles payload correctly

## Testing

### Simulator Limitations

Push notifications don't work on Simulator. Use a physical device.

### Manual Testing

```bash
# On server, trigger notification
sqlite3 ~/.tron/db/prod.db "SELECT token FROM device_tokens LIMIT 1"

# Use curl to test APNS directly (requires JWT generation)
```

### In-App Testing

1. Background the app
2. Trigger NotifyApp tool from agent
3. Verify notification appears
4. Tap notification, verify deep link works
