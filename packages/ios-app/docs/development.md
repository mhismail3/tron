# iOS Development

## Setup

### Prerequisites

- Xcode 16+ with iOS 18 SDK
- XcodeGen (`brew install xcodegen`)
- Tron server running locally

### Project Generation

```bash
cd packages/ios-app
xcodegen generate
open TronMobile.xcodeproj
```

### Server Connection

The app connects to the Tron server:
- **Beta**: `localhost:8082` (run `tron dev`)
- **Production**: `localhost:8080` (run `tron start`)

## Build Configurations

| Config | Server | Use Case |
|--------|--------|----------|
| Debug-Beta | localhost:8082 | Development |
| Release-Beta | localhost:8082 | TestFlight beta |
| Debug-Prod | localhost:8080 | Production testing |
| Release-Prod | localhost:8080 | App Store |

## Running Tests

### Command Line

```bash
xcodebuild test \
  -scheme TronMobile \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

### Xcode

1. Open `TronMobile.xcodeproj`
2. Select TronMobile scheme
3. Cmd+U to run tests

### Test Structure

```
Tests/
├── ViewModels/        # ViewModel tests
├── Services/          # Service tests
├── Core/              # Event plugin tests
├── Mocks/             # Test doubles
└── Navigation/        # Deep link tests
```

## Debugging

### Console Logging

```swift
TronLogger.shared.debug("Message", category: .network)
TronLogger.shared.error("Error: \(error)", category: .session)
```

Categories: `.network`, `.session`, `.events`, `.notification`, `.audio`

### Network Inspector

View WebSocket traffic:
1. Run in Debug-Beta
2. Check Xcode console for `[Network]` logs
3. Or use Proxyman/Charles for detailed inspection

### Event Debugging

```swift
// In ChatViewModel
eventPublisherV2.sink { event in
    print("Event: \(event.type) - \(event.sessionId ?? "nil")")
}
```

## Common Tasks

### Adding a New Screen

1. Create view in `Views/<Feature>/`
2. Create view model if needed in `ViewModels/`
3. Add navigation in parent view or sheet coordinator
4. Add deep link route if applicable

### Adding a Tool Visualization

1. Create chip in `Views/Tools/<ToolName>/<Name>Chip.swift`
2. Create detail sheet in same folder
3. Add case in `ToolChipFactory.swift`
4. Add sheet case in `SheetCoordinator`

### Updating Event Handling

See `docs/events.md` for the complete event handling guide.

## Known Issues

| Issue | Status | Notes |
|-------|--------|-------|
| DeepLinkRouter URL parsing | Bug | Host vs path confusion |
| StreamingManager timing test | Flaky | `testRapidDeltasGetBatched` |

## Performance

### Memory Management

- Event arrays capped (100 events per subagent)
- Messages windowed for large sessions
- Images loaded lazily

### UI Performance

- Streaming batched at 16ms intervals
- Scroll state tracked to avoid unnecessary updates
- Heavy transforms run on background threads

## Code Style

- SwiftLint configured via `.swiftlint.yml`
- Run `swiftlint` before committing
- Use `@MainActor` for all UI-touching code
- Prefer `@Observable` over `ObservableObject`
