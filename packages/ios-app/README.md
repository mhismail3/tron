# Tron Mobile - iOS Client

Native iOS client for the Tron AI assistant, connecting via WebSocket to your Tron server.

## Requirements

- macOS 15+ (Sequoia)
- Xcode 26+
- iOS 26.0+ device or simulator
- An Apple ID (free account works for sideloading)

## Quick Start

### 1. Install XcodeGen (if not installed)

```bash
brew install xcodegen
```

### 2. Generate Xcode Project

```bash
cd packages/ios-app
xcodegen generate
```

### 3. Open in Xcode

```bash
open TronMobile.xcodeproj
```

### 4. Configure Signing

1. Select the TronMobile project in the navigator
2. Select the TronMobile target
3. Go to "Signing & Capabilities"
4. Enable "Automatically manage signing"
5. Select your Personal Team (your Apple ID)

### 5. Build and Run

- **Simulator**: Select an iPhone simulator and press Cmd+R
- **Device**: Connect your iPhone via USB, select it, and press Cmd+R

## Connecting to Your Tron Server

The app connects to the Tron engine over the `/engine` WebSocket endpoint. The
Mac wrapper pairing QR carries the server address, port, bearer token, and
label. Physical-device testing can use a local network address or Tailscale.

For local development from this checkout:

```bash
scripts/tron dev -bdt
```

The default paired server port is `9847`. If pairing times out, verify
`http://<mac-or-tailscale-ip>:9847/health` from the network you expect the
device to use, and accept the iOS local-network permission prompt if it appears.

## Sideloading to Device

### First-Time Setup

1. Enable Developer Mode on iPhone:
   - Settings > Privacy & Security > Developer Mode > On
   - Restart when prompted

2. Connect iPhone to Mac via USB

3. Build and run from Xcode (Cmd+R)

4. First run will fail with "Untrusted Developer"

5. On iPhone: Settings > General > VPN & Device Management
   - Tap your developer certificate
   - Tap "Trust"

6. Build and run again

### Re-sideloading

Free Apple accounts require re-sideloading every 7 days. Just:
1. Connect iPhone
2. Build and run from Xcode

## Project Structure

```
packages/ios-app/
├── project.yml              # XcodeGen project definition
├── Sources/
│   ├── App/
│   │   └── Lifecycle/              # App entry point and scene coordination
│   ├── Engine/
│   │   ├── Transport/              # /engine WebSocket, clients, retry, deep links
│   │   ├── Protocol/               # Engine protocol frames and domain payloads
│   │   ├── Events/                 # Live events, plugins, payloads, reconstruction
│   │   └── Persistence/            # Local SQLite cache, repositories, sync cursor
│   ├── Session/                    # Chat workflow, timeline, parsing, attachments
│   ├── UI/                         # Chat, settings, onboarding, runtime surfaces
│   ├── Support/                    # Composition, diagnostics, pairing, storage
│   ├── Assets.xcassets/            # App icons and image assets
│   └── Resources/                  # Fonts and generated icon layers
├── Tests/
│   ├── Engine/
│   ├── Session/
│   ├── UI/
│   ├── Support/
│   └── Infrastructure/
└── TronMobile.xcodeproj     # Generated Xcode project
```

## Building from Command Line

```bash
# Build for simulator (production)
xcodebuild -project TronMobile.xcodeproj \
  -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build

# Build for simulator (beta)
xcodebuild -project TronMobile.xcodeproj \
  -scheme 'Tron Beta' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

## Troubleshooting

### "Untrusted Developer" Error
Go to Settings > General > VPN & Device Management and trust your developer certificate.

### Connection Failed
- Ensure server is running with `--host 0.0.0.0`
- Check that both devices are on the same network
- Verify the IP address and port in app settings

### Build Errors
Regenerate the Xcode project:
```bash
xcodegen generate
```

## Features

- Real-time streaming responses
- Capability invocation visualization
- Session management
- Image attachments
- Thinking indicator
- Token usage display
- Dark mode forest green theme

## License

Part of the Tron project.
