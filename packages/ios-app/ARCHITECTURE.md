# iOS App Architecture

> Last verified: 2026-01-24

This document describes the iOS app architecture and patterns for developers working on the codebase.

## Directory Structure

```
Sources/
├── App/                    # App entry point, delegates, configuration
├── Core/                   # Business logic extracted from other modules
│   └── Events/             # Event handling infrastructure
│       └── Payloads/       # Event payload types
├── Database/               # SQLite event database, queries
├── Extensions/             # Swift extensions for common types
├── Models/                 # Data models, event transformers
│   ├── Events/             # Event types and registry
│   ├── Features/           # Feature-specific models (Attachment, Skill, etc.)
│   ├── Messages/           # Message models
│   └── RPC/                # RPC types and codables
├── Protocols/              # Protocol definitions
├── Services/               # Network, state management
│   ├── Audio/              # Recording and audio monitoring
│   ├── Cache/              # In-memory caching
│   ├── Events/             # Event store, sync, deduplication
│   ├── Infrastructure/     # Logging, error handling, keyboard
│   ├── Network/            # RPC, WebSocket, deep links
│   ├── Notifications/      # Push notifications
│   ├── Parsing/            # Tool result and UI canvas parsing
│   ├── Polling/            # Dashboard and state polling
│   └── Storage/            # Input history, skill store
├── Theme/                  # Colors, spacing, icons
├── Utilities/              # Helper functions, formatters
├── ViewModels/             # View state management
│   ├── Chat/               # ChatViewModel and extensions
│   ├── Handlers/           # Event handling logic
│   ├── Managers/           # Specialized state managers
│   └── State/              # State objects
└── Views/                  # SwiftUI views
    ├── AskUser/            # AskUserQuestion tool UI
    ├── Attachments/        # File/media attachment views
    ├── Browser/            # Web browser views
    ├── Chat/               # Core chat interface (ChatView, ContentView)
    ├── Components/         # Reusable UI components
    ├── ContextAudit/       # Context inspection views
    ├── InputBar/           # Message input components
    ├── MessageBubble/      # Message rendering
    ├── Session/            # Session management views
    ├── SessionTree/        # Session tree navigation
    ├── Settings/           # App settings UI
    ├── Skills/             # Skill/spell management
    ├── Subagents/          # Subagent chips and details
    ├── System/             # Debug/system views (logs, compaction)
    ├── Tools/              # Tool chips + detail sheets (paired)
    │   ├── NotifyApp/
    │   ├── RenderAppUI/
    │   ├── Thinking/
    │   └── Todo/
    ├── ToolViewers/        # Tool result visualizations
    ├── UICanvas/           # Dynamic UI rendering
    └── VoiceNotes/         # Voice recording UI
```

## Key Files

| File | Purpose | LOC |
|------|---------|-----|
| `Models/UnifiedEventTransformer.swift` | Event → Message transformation | ~1900 |
| `Views/SessionTree/SessionTreeView.swift` | Session history browser | ~1800 |
| `ViewModels/SessionHistoryViewModel.swift` | Session history state (extracted) | ~190 |
| `ViewModels/Chat/ChatViewModel.swift` | Main chat state (+ extensions) | ~3000 |
| `Services/Network/RPCClient.swift` | WebSocket RPC communication | ~500 |
| `Services/Events/EventStoreManager.swift` | Local event persistence | ~400 |

## Architectural Patterns

### MVVM with Extensions

The app uses MVVM. Large view models are split across extension files and grouped by feature:

```
ViewModels/
└── Chat/
    ├── ChatViewModel.swift            # Core state
    ├── ChatViewModel+Connection.swift # Connection management
    ├── ChatViewModel+Events.swift     # Event handling
    ├── ChatViewModel+Messaging.swift  # Message sending
    ├── ChatViewModel+Pagination.swift # History pagination
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
| Network/RPC | `Services/Network/` | `RPCClient.swift`, `WebSocketService.swift` |
| Event management | `Services/Events/` | `EventStoreManager.swift` |
| Audio | `Services/Audio/` | `AudioRecorder.swift` |
| Logging/errors | `Services/Infrastructure/` | `TronLogger.swift` |
| Message model | `Models/Messages/` | `Message.swift` |
| Feature model | `Models/Features/` | `Attachment.swift`, `Skill.swift` |
| Event types | `Models/Events/` | `Events.swift` |
| Event payload | `Core/Events/Payloads/` | `ToolPayloads.swift` |
| Core chat views | `Views/Chat/` | `ChatView.swift`, `ContentView.swift` |
| Tool chip+sheet | `Views/Tools/{ToolName}/` | `Views/Tools/Todo/TodoWriteChip.swift` |
| Feature views | `Views/{Feature}/` | `Views/Settings/SettingsView.swift` |
| Reusable component | `Views/Components/` | `LineNumberedContentView.swift` |
| Tool visualization | `Views/ToolViewers/` | `BashToolViewer.swift` |
| System/debug views | `Views/System/` | `LogViewer.swift` |
| View state | `ViewModels/Chat/` | `ChatViewModel.swift` |
| Protocol | `Protocols/` | `EventDatabaseProtocol.swift` |

### Naming Conventions

- Views: `*View.swift`, `*Sheet.swift`, `*Chip.swift`
- ViewModels: `*ViewModel.swift`
- State objects: `*State.swift`
- Managers: `*Manager.swift`
- Services: `*Service.swift`, `*Client.swift`
- Parsers: `*Parser.swift`
- Transformers: `*Transformer.swift`

### Folder Organization Patterns

**Chip+Sheet Pairing**: Tool features with inline chips and detail sheets belong together:
```
Views/Tools/FeatureName/
├── FeatureNameChip.swift
└── FeatureNameDetailSheet.swift
```

**Extension File Grouping**: Files with extensions stay together in a named folder:
```
ViewModels/Chat/
├── ChatViewModel.swift
├── ChatViewModel+Connection.swift
└── ChatViewModel+Events.swift
```

**Domain-Based Services**: Services grouped by responsibility, not alphabetically.

**Nesting Limit**: Maximum 3 levels: `Sources/Category/Feature/`

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
