# iOS App Architecture

> Last verified: 2026-01-24

This document describes the iOS app architecture and patterns for developers working on the codebase.

## Directory Structure

```
Sources/
├── App/                    # App entry point, delegates, configuration
├── Core/                   # Business logic extractd from other modules
│   └── Events/             # Event handling infrastructure
│       └── Payloads/       # Event payload types
├── Database/               # SQLite event database, queries
├── Extensions/             # Swift extensions for common types
├── Models/                 # Data models, event transformers
├── Protocols/              # Protocol definitions
├── Services/               # Network, state management
├── Theme/                  # Colors, spacing, icons
├── Utilities/              # Helper functions, formatters, parsers
├── ViewModels/             # View state management
│   ├── Handlers/           # Event handling logic
│   ├── Managers/           # Specialized state managers
│   └── State/              # State objects
└── Views/                  # SwiftUI views
    ├── AskUser/            # AskUserQuestion tool UI
    ├── Browser/            # Web browser views
    ├── Components/         # Reusable UI components
    ├── ContextAudit/       # Context inspection views
    ├── InputBar/           # Message input components
    ├── MessageBubble/      # Message rendering
    ├── Session/            # Session management views
    ├── Settings/           # App settings UI
    ├── Skills/             # Skill/spell management
    ├── Subagents/          # Subagent chips and details
    ├── ToolViewers/        # Tool result visualizations
    ├── UICanvas/           # Dynamic UI rendering
    └── VoiceNotes/         # Voice recording UI
```

## Key Files

| File | Purpose | LOC |
|------|---------|-----|
| `Models/UnifiedEventTransformer.swift` | Event → Message transformation | ~1900 |
| `Views/SessionTreeView.swift` | Session history browser | ~1800 |
| `ViewModels/SessionHistoryViewModel.swift` | Session history state (extracted) | ~190 |
| `ViewModels/ChatViewModel.swift` | Main chat state (+ extensions) | ~3000 |
| `Services/RPCClient.swift` | WebSocket RPC communication | ~500 |
| `Services/EventStoreManager.swift` | Local event persistence | ~400 |

## Architectural Patterns

### MVVM with Extensions

The app uses MVVM. Large view models are split across extension files:

```
ViewModels/
├── ChatViewModel.swift            # Core state
├── ChatViewModel+Events.swift     # Event handling
├── ChatViewModel+Subagent.swift   # Subagent logic
└── ChatViewModel+Transcription.swift  # Voice transcription
```

### Event Sourcing

All session state is derived from immutable events:

1. **Server Events** → WebSocket → RPCClient
2. **Event Processing** → UnifiedEventTransformer
3. **UI State** → Message[] → ChatViewModel
4. **Local Persistence** → EventDatabase (SQLite)

### State Reconstruction

When loading a session:
1. Fetch events from server or local DB
2. Sort by turn, then timestamp
3. Transform each event to Message
4. Merge streaming deltas with base messages

## File Placement Guidelines

### Where to put new code

| Type | Location | Example |
|------|----------|---------|
| Pure function | `Utilities/` | `TokenFormatter.swift`, `ContentLineParser.swift` |
| Network call | `Services/` | `RPCClient.swift` |
| Data structure | `Models/` | `Message.swift` |
| Event payload | `Core/Events/Payloads/` | `ToolPayloads.swift` |
| SwiftUI view | `Views/` | `ChatView.swift` |
| Feature views | `Views/{Feature}/` | `Views/Settings/SettingsView.swift` |
| Reusable component | `Views/Components/` | `LineNumberedContentView.swift` |
| Tool visualization | `Views/ToolViewers/` | `BashToolViewer.swift` |
| View state | `ViewModels/` | `ChatViewModel.swift` |
| Protocol | `Protocols/` | `EventDatabaseProtocol.swift` |

### Naming Conventions

- Views: `*View.swift`, `*Sheet.swift`, `*Chip.swift`
- ViewModels: `*ViewModel.swift`
- State objects: `*State.swift`
- Managers: `*Manager.swift`
- Services: `*Service.swift`, `*Client.swift`
- Parsers: `*Parser.swift`
- Transformers: `*Transformer.swift`

## Testing

Tests mirror the source structure:

```
Tests/
├── ViewModels/             # ViewModel tests
├── Services/               # Service tests
├── Mocks/                  # Test doubles
└── Navigation/             # Deep link tests
```

### Running Tests

```bash
xcodebuild test -scheme TronMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Known Issues

| Issue | Status | Notes |
|-------|--------|-------|
| DeepLinkRouter URL parsing | Bug | Host vs path confusion in URL scheme |
| StreamingManager timing test | Flaky | `testRapidDeltasGetBatched` |

## Build Configuration

The app uses XcodeGen with `project.yml`:

- **Configs**: Debug-Beta, Release-Beta, Debug-Prod, Release-Prod
- **Minimum iOS**: 18.0
- **Swift**: 6.0

To regenerate the Xcode project:
```bash
xcodegen generate
```
