---
paths:
  - "**/Services/**"
---

# Services Layer

Network, storage, and infrastructure services. Injected via `DependencyContainer`.

## Network Architecture

```
RPCClient (WebSocket transport)
    ├── SessionClient    - session lifecycle
    ├── AgentClient      - message sending, forking
    ├── ModelClient      - model listing
    ├── FilesystemClient - file operations
    ├── EventSyncClient  - event synchronization
    ├── ContextClient    - context management
    ├── MediaClient      - transcription, voice notes
    ├── CronClient       - automation scheduling
    ├── NotificationClient - inbox notifications
    ├── AuthClient       - provider auth, OAuth
    ├── MCPClient        - MCP server management
    ├── ProcessClient    - background processes
    ├── BlobClient       - display tool images
    ├── DisplayClient    - display stream control
    ├── WorktreeClient   - worktree status, commits, merges, diffs, branches
    ├── SkillClient      - skill listing, getting, refreshing, removing
    ├── SandboxClient    - container lifecycle (list, start, stop, kill, remove)
    ├── ImportClient     - Claude Code session import (discover, preview, execute)
    ├── PromptLibraryClient - Prompt history + snippets (list, create, update, delete, clear)
    └── MiscClient       - system, device tokens, memory, messages, logs
```

## RPC Pattern

Domain clients use `RPCTransport` protocol:

```swift
struct MyClient {
    let transport: RPCTransport

    func doThing() async throws -> Response {
        try await transport.call(method: "my.method", params: params)
    }
}
```

## Key Services

- `EventStoreManager` - Session list, event sync, dashboard polling. Refresh via `requestSessionRefresh(reason:)` (coalesced by `SessionRefreshService`).
- `SessionRefreshService` - Single coalescing coordinator for `session.list` refresh. Dedups concurrent requests, debounces `.foreground` reason (1s), queues disconnected requests via `ConnectionManager.runOnReconnect`.
- `WebSocketService` - Low-level WebSocket with jittered exponential backoff (`BackoffPolicy`: 10 attempts, 1→30s cap). Attaches `Authorization: Bearer <token>` header from `PresetTokenStore` on upgrade when the active preset has a token.
- `BackoffPolicy` - Pure value type. `baseDelay(forAttempt:)` deterministic; `delay(forAttempt:)` adds 0–30% jitter.
- `AsyncClock` - Protocol for time-based code. Production: `SystemAsyncClock`. Tests: `MockAsyncClock`.
- `ConnectionManager` - Policy layer over `RPCClient`. Exposes `state`, `runOnReconnect(label:_:)` single-shot dedup'd hooks, `cancelHook(label:)`, `manualRetry()`. Single source of truth for connection state. Exposes `.unauthorized` when the server rejects the bearer (401) — a parked state that requires user action (tap pill → re-pair sheet).
- `InteractionPolicy` - Central read-only / "can-mutate" policy read by all mutation UI (`canSendMessage`, `canRecordAudio`, `canCreateSession`, `canMutateSession`, `canCommitWorktree`, `canManageMCP`, `canManageSkills`, `canManageAutomations`, `canLoadServerData`). 500ms debounce on reconnect. Accessed via `@Environment(\.interactionPolicy)`.
- `ToastCenter` - Non-blocking banner queue. Replaces modal `.alert()` for transient errors. Severity-based auto-dismiss, dedup by key, overflow trimming preferring retry toasts.
- `ErrorHandler` - Router. `handle()` → `ToastCenter` (transient); `handleFatal()` → modal queue (actionable errors like session-not-found). Connection-class errors dedup under key `"connection.transient"`.
- `SkillStore` - Cached skill definitions
- `DraftStore` - Per-session draft persistence (debounced save, file-based attachment storage)
- `KeychainItem` - Thin wrapper over Security framework (`SecItemCopyMatching`/`SecItemAdd`/`SecItemDelete`). Storage class: `kSecAttrAccessibleAfterFirstUnlock` so the server can reconnect post-reboot before unlock. Access group reserved for share-extension forward-compat.
- `PresetTokenStore` - Bearer token registry keyed by `ConnectionPreset.id`. API: `set(token:forPresetId:)`, `token(forPresetId:)`, `remove(presetId:)`. Migration-safe: renaming a preset preserves its token because lookup is by ID, not label.
- `PairingURLParser` - Parses `tron://pair?host=…&port=…&token=…[&label=…]` into a typed struct. Powers Mac QR deep links, universal-paste auto-fill in the onboarding pairing form, and settings re-pair. The optional `label` value is displayed as the server name.
- `SentryRedactor` - PII scrubber used inside Sentry's `beforeSend` hook. Strips bearer tokens (length-only), absolute file paths under `~/.tron/workspace/` + `~/.tron/system/database/`, and chat message content. Shared implementation between iOS and Mac (`packages/mac-app/Sources/Services/Observability/SentryRedactor.swift` is a near-mirror).
- `FeedbackComposer` - Pure value type that builds the subject + body for "Send feedback" mail with a redacted log tail. `FeedbackMailView` wraps `MFMailComposeViewController` to present the composer; the delegate hop uses `nonisolated` + `Task { @MainActor }` because `MFMailComposeViewControllerDelegate` is ObjC-bridged.
- `TelemetryClient` + `NullTelemetryClient` - Protocol-backed PostHog emitter with a no-op default. Flipping `@AppStorage("telemetryEnabled")` to ON rebuilds the client with a real backing; OFF reverts to `NullTelemetryClient` mid-session (no app restart needed).
- `TokenBucket` - Lazy refill rate limiter guarding Sentry + PostHog quota. Default: 10 events/min Sentry, 100 events/min PostHog, shared across callers per surface.

## Fail-fast RPC

`RPCTransport.requireConnection()` checks both `webSocket != nil` AND `connectionState.isConnected`; throws `WebSocketError.notConnected` when offline (no 30s wait). Every domain client routes through it.

## Rules

- Domain clients are lazy properties on RPCClient
- All RPC methods go through domain clients, not raw RPCClient calls
- EventStoreManager owns session list state

---

## Update Triggers

Update this rule when:
- Adding new RPC domain clients
- Changing service architecture
- Modifying WebSocket transport

Verification:
```bash
grep -l "Client" packages/ios-app/Sources/Services/Network/*.swift | head -5
```
