# Tron Mobile - iOS Client

Native iOS client for the Tron AI assistant, connecting via WebSocket to your Tron server.

## Requirements

- macOS 15+ (Sequoia)
- Xcode 16+
- iOS 18.0+ device or simulator
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

### Same Network (Easiest)

1. Find your Mac's local IP:
   ```bash
   ipconfig getifaddr en0
   ```

2. Start Tron server on Mac:
   ```bash
   pnpm tron --server --host 0.0.0.0 --ws-port 8080
   ```

3. In the iOS app Settings, enter:
   - Host: Your Mac's IP (e.g., `192.168.1.100`)
   - Port: `8080`
   - TLS: Off

### Via Tailscale (Recommended for Remote)

1. Install Tailscale on both Mac and iPhone
2. Get your Mac's Tailscale IP:
   ```bash
   tailscale ip -4
   ```
3. Use the Tailscale IP in the app settings

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
│   │   └── TronMobileApp.swift     # App entry point
│   ├── Models/
│   │   ├── AnyCodable.swift        # Dynamic JSON handling
│   │   ├── Events.swift            # Server event types
│   │   ├── Message.swift           # Chat message models
│   │   └── RPCTypes.swift          # JSON-RPC types
│   ├── Services/
│   │   ├── RPCClient.swift         # High-level RPC client
│   │   └── WebSocketService.swift  # WebSocket connection
│   ├── ViewModels/
│   │   └── ChatViewModel.swift     # Chat state management
│   ├── Views/
│   │   ├── ChatView.swift          # Main chat interface
│   │   ├── InputBar.swift          # Message input
│   │   ├── MessageBubble.swift     # Message rendering
│   │   ├── SessionListView.swift   # Session browser
│   │   └── SettingsView.swift      # App settings
│   ├── Theme/
│   │   ├── TronColors.swift        # Forest green palette
│   │   └── TronIcons.swift         # SF Symbols mapping
│   └── Extensions/
│       ├── Date+Extensions.swift
│       ├── String+Extensions.swift
│       └── View+Extensions.swift
└── TronMobile.xcodeproj     # Generated Xcode project
```

## Building from Command Line

```bash
# Build for simulator
xcodebuild -project TronMobile.xcodeproj \
  -scheme TronMobile \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  build

# Build for device (requires signing)
xcodebuild -project TronMobile.xcodeproj \
  -scheme TronMobile \
  -destination 'platform=iOS,name=My iPhone' \
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
- Tool use visualization
- Session management
- Image attachments
- Thinking indicator
- Token usage display
- Dark mode forest green theme

## License

Part of the Tron project.
