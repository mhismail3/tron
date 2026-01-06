# iOS App Event Store Enhancements

## Overview

This document outlines the iOS app enhancements to leverage the new event store data from the server-side improvements (Phases 1-4). The goal is to surface rich metadata, provide accurate event visualization, and enable powerful session analytics.

---

## New Data Available from Server

### Phase 1: Enriched `message.assistant` Payload

| Field | Type | Description |
|-------|------|-------------|
| `turn` | `Int` | Turn number in the agent loop |
| `model` | `String` | Model that generated this response |
| `stopReason` | `String` | Why the turn ended (`end_turn`, `tool_use`, `max_tokens`) |
| `latency` | `Int` | Response time in milliseconds |
| `hasThinking` | `Bool` | Whether extended thinking was used |

### Phase 2: Discrete Tool Events

**`tool.call`**
```json
{
  "toolCallId": "tc_abc123",
  "name": "read",
  "arguments": { "path": "/file.ts" },
  "turn": 1
}
```

**`tool.result`**
```json
{
  "toolCallId": "tc_abc123",
  "content": "file contents...",
  "isError": false,
  "duration": 45,
  "truncated": false
}
```

### Phase 3: Error Events

**`error.agent`**
```json
{
  "error": "Maximum turns exceeded",
  "code": "MAX_TURNS_EXCEEDED",
  "recoverable": false
}
```

**`error.provider`**
```json
{
  "provider": "anthropic",
  "error": "Rate limit exceeded",
  "code": "rate_limit_error",
  "retryable": true,
  "retryAfter": 5000
}
```

**`error.tool`**
```json
{
  "toolName": "bash",
  "toolCallId": "tc_failed",
  "error": "Command not found",
  "code": "COMMAND_NOT_FOUND"
}
```

### Phase 4: Turn Boundary Events

**`stream.turn_start`**
```json
{ "turn": 1 }
```

**`stream.turn_end`**
```json
{
  "turn": 1,
  "tokenUsage": { "inputTokens": 500, "outputTokens": 200 }
}
```

---

## Enhancement 1: Per-Message Metadata Display

### Goal
Show rich metadata beneath each assistant message to provide context about how the response was generated.

### Design

```
┌─────────────────────────────────────────────────────────────┐
│ Here's the file contents you requested...                   │
│                                                             │
│ ↓1.2K  ↑456  •  claude-sonnet-4  •  2.3s  •  Thinking      │
└─────────────────────────────────────────────────────────────┘
```

### Components

**`MessageMetadataBadge`** - Displays beneath assistant messages:
- Token usage (existing `TokenBadge`)
- Model name pill (monospaced, muted color)
- Latency pill (e.g., "2.3s")
- "Thinking" label when extended thinking was used (no emoji)

### Data Model Changes

**`Sources/Models/Message.swift`**

Add to `ChatMessage`:
```swift
struct ChatMessage: Identifiable, Equatable {
    // Existing fields...

    // NEW: Enriched metadata from Phase 1
    var model: String?
    var latency: Int?
    var turnNumber: Int?
    var hasThinking: Bool?
    var stopReason: String?
}
```

### View Changes

**`Sources/Views/MessageBubble.swift`**

Replace simple `TokenBadge` with comprehensive `MessageMetadataBadge`:

```swift
struct MessageMetadataBadge: View {
    let usage: TokenUsage?
    let model: String?
    let latency: Int?
    let hasThinking: Bool?

    var body: some View {
        HStack(spacing: 8) {
            // Token usage
            if let usage = usage {
                TokenBadge(usage: usage)
            }

            // Separator
            if usage != nil && (model != nil || latency != nil) {
                Text("•")
                    .foregroundStyle(.tronTextMuted)
            }

            // Model name
            if let model = model {
                Text(formatModelName(model))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
            }

            // Latency
            if let latency = latency {
                Text(formatLatency(latency))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
            }

            // Thinking indicator (text, not emoji)
            if hasThinking == true {
                Text("Thinking")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronAmber)
            }
        }
    }

    private func formatModelName(_ model: String) -> String {
        // Extract short name: "claude-sonnet-4-20250514" -> "sonnet-4"
        if model.contains("opus") { return "opus" }
        if model.contains("sonnet") { return "sonnet" }
        if model.contains("haiku") { return "haiku" }
        return model.components(separatedBy: "-").prefix(2).joined(separator: "-")
    }

    private func formatLatency(_ ms: Int) -> String {
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }
}
```

### ViewModel Changes

**`Sources/ViewModels/ChatViewModel.swift`**

When reconstructing messages from events, extract enriched fields:

```swift
private func reconstructMessage(from event: SessionEvent) -> ChatMessage? {
    guard event.eventType == .messageAssistant else { return nil }

    let payload = event.payload

    return ChatMessage(
        role: .assistant,
        content: extractContent(from: payload),
        tokenUsage: extractTokenUsage(from: payload),
        // NEW: Extract enriched fields
        model: payload["model"]?.value as? String,
        latency: payload["latency"]?.value as? Int,
        turnNumber: payload["turn"]?.value as? Int,
        hasThinking: payload["hasThinking"]?.value as? Bool,
        stopReason: payload["stopReason"]?.value as? String
    )
}
```

---

## Enhancement 2: Enhanced Event Tree View

### Goal
Create an elegant, accurate, and robust visualization of all event types in the session history tree.

### Design Principles

1. **Consistency** - Each event type has a distinct, recognizable visual identity
2. **Information density** - Show key data without clutter
3. **Elegance** - Clean typography, proper spacing, subtle colors
4. **Accuracy** - Display actual data from event payloads

### Event Type Visual Design

| Event Type | Icon | Color | Summary Format |
|------------|------|-------|----------------|
| `session.start` | `play.circle.fill` | `.tronSuccess` | "Session started" |
| `session.end` | `stop.circle.fill` | `.tronTextMuted` | "Session ended ({reason})" |
| `session.fork` | `arrow.triangle.branch` | `.tronAmber` | "Forked from {source}" |
| `message.user` | `person.fill` | `.tronBlue` | First 50 chars of content |
| `message.assistant` | `cpu` | `.tronPurple` | First 50 chars + metadata |
| `tool.call` | `wrench.and.screwdriver` | `.tronCyan` | "{toolName}: {key_arg}" |
| `tool.result` | `checkmark.circle` / `xmark.circle` | `.tronSuccess` / `.tronError` | "{duration}ms • {status}" |
| `stream.turn_start` | `arrow.right.circle` | `.tronBlue` | "Turn {n} started" |
| `stream.turn_end` | `arrow.down.circle` | `.tronBlue` | "Turn {n} • {tokens} tokens" |
| `error.agent` | `exclamationmark.triangle.fill` | `.tronError` | "{code}: {message}" |
| `error.provider` | `arrow.clockwise.circle` | `.tronAmber` | "Retry in {delay}ms" |
| `error.tool` | `xmark.octagon` | `.tronError` | "{toolName} failed" |
| `config.model_switch` | `arrow.left.arrow.right` | `.tronEmerald` | "{from} → {to}" |
| `compact.boundary` | `arrow.down.right.and.arrow.up.left` | `.tronTextMuted` | "Context compacted" |

### Implementation

**`Sources/Database/EventTypes.swift`**

Update the `summary` computed property:

```swift
extension SessionEventType {
    func summary(from payload: [String: AnyCodable]) -> String {
        switch self {
        case .sessionStart:
            let model = (payload["model"]?.value as? String) ?? "unknown"
            return "Session started • \(formatModelName(model))"

        case .sessionEnd:
            let reason = (payload["reason"]?.value as? String) ?? "completed"
            return "Session ended (\(reason))"

        case .sessionFork:
            return "Forked session"

        case .messageUser:
            let content = extractTextContent(from: payload)
            return truncate(content, to: 50)

        case .messageAssistant:
            let content = extractTextContent(from: payload)
            var summary = truncate(content, to: 40)

            // Add metadata indicators
            var indicators: [String] = []
            if let latency = payload["latency"]?.value as? Int {
                indicators.append(formatLatency(latency))
            }
            if payload["hasThinking"]?.value as? Bool == true {
                indicators.append("Thinking")
            }
            if !indicators.isEmpty {
                summary += " • " + indicators.joined(separator: " • ")
            }
            return summary

        case .toolCall:
            let name = (payload["name"]?.value as? String) ?? "unknown"
            let args = payload["arguments"]?.value as? [String: Any] ?? [:]
            let keyArg = extractKeyArgument(toolName: name, from: args)
            return "\(name): \(keyArg)"

        case .toolResult:
            let isError = (payload["isError"]?.value as? Bool) ?? false
            let duration = payload["duration"]?.value as? Int
            let status = isError ? "error" : "success"

            if let duration = duration {
                return "\(duration)ms • \(status)"
            }
            return status

        case .streamTurnStart:
            let turn = (payload["turn"]?.value as? Int) ?? 0
            return "Turn \(turn) started"

        case .streamTurnEnd:
            let turn = (payload["turn"]?.value as? Int) ?? 0
            if let tokenUsage = payload["tokenUsage"]?.value as? [String: Any],
               let input = tokenUsage["inputTokens"] as? Int,
               let output = tokenUsage["outputTokens"] as? Int {
                return "Turn \(turn) • \(formatTokens(input + output)) tokens"
            }
            return "Turn \(turn) ended"

        case .errorAgent:
            let code = (payload["code"]?.value as? String) ?? "ERROR"
            let error = (payload["error"]?.value as? String) ?? "Unknown error"
            return "\(code): \(truncate(error, to: 30))"

        case .errorProvider:
            let provider = (payload["provider"]?.value as? String) ?? "provider"
            let retryable = (payload["retryable"]?.value as? Bool) ?? false
            if retryable, let delay = payload["retryAfter"]?.value as? Int {
                return "\(provider) • retry in \(delay)ms"
            }
            return "\(provider) error"

        case .errorTool:
            let toolName = (payload["toolName"]?.value as? String) ?? "tool"
            return "\(toolName) failed"

        case .configModelSwitch:
            let from = formatModelName((payload["previousModel"]?.value as? String) ?? "?")
            let to = formatModelName((payload["newModel"]?.value as? String) ?? "?")
            return "\(from) → \(to)"

        case .compactBoundary:
            return "Context compacted"

        default:
            return self.rawValue
        }
    }

    // Helper to extract key argument for tool display
    private func extractKeyArgument(toolName: String, from args: [String: Any]) -> String {
        switch toolName.lowercased() {
        case "read", "write", "edit":
            if let path = args["file_path"] as? String ?? args["path"] as? String {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        case "bash":
            if let cmd = args["command"] as? String {
                return truncate(cmd, to: 25)
            }
        case "grep":
            if let pattern = args["pattern"] as? String {
                return "\"\(truncate(pattern, to: 20))\""
            }
        case "glob", "find":
            if let pattern = args["pattern"] as? String {
                return pattern
            }
        default:
            break
        }
        return ""
    }
}
```

**`Sources/Views/SessionTreeView.swift`**

Update `TreeNodeRow` for elegant display:

```swift
struct TreeNodeRow: View {
    // ... existing properties ...

    private var eventIcon: some View {
        Image(systemName: iconName)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(iconColor)
            .frame(width: 20, height: 20)
            .background(
                Circle()
                    .fill(iconColor.opacity(0.15))
            )
    }

    private var iconName: String {
        switch event.eventType {
        case .sessionStart: return "play.circle.fill"
        case .sessionEnd: return "stop.circle.fill"
        case .sessionFork: return "arrow.triangle.branch"
        case .messageUser: return "person.fill"
        case .messageAssistant: return "cpu"
        case .toolCall: return "wrench.and.screwdriver"
        case .toolResult:
            let isError = (event.payload["isError"]?.value as? Bool) ?? false
            return isError ? "xmark.circle.fill" : "checkmark.circle.fill"
        case .streamTurnStart: return "arrow.right.circle"
        case .streamTurnEnd: return "arrow.down.circle"
        case .errorAgent: return "exclamationmark.triangle.fill"
        case .errorProvider: return "arrow.clockwise.circle"
        case .errorTool: return "xmark.octagon"
        case .configModelSwitch: return "arrow.left.arrow.right"
        case .compactBoundary: return "arrow.down.right.and.arrow.up.left"
        default: return "circle.fill"
        }
    }

    private var iconColor: Color {
        switch event.eventType {
        case .sessionStart: return .tronSuccess
        case .sessionEnd: return .tronTextMuted
        case .sessionFork: return .tronAmber
        case .messageUser: return .tronBlue
        case .messageAssistant: return .tronPurple
        case .toolCall: return .tronCyan
        case .toolResult:
            let isError = (event.payload["isError"]?.value as? Bool) ?? false
            return isError ? .tronError : .tronSuccess
        case .streamTurnStart, .streamTurnEnd: return .tronBlue
        case .errorAgent, .errorTool: return .tronError
        case .errorProvider: return .tronAmber
        case .configModelSwitch: return .tronEmerald
        default: return .tronTextMuted
        }
    }
}
```

### Expanded Content View

For detailed event inspection, show formatted payload:

```swift
private var expandedContent: String? {
    switch event.eventType {
    case .messageAssistant:
        var lines: [String] = []
        if let model = event.payload["model"]?.value as? String {
            lines.append("Model: \(model)")
        }
        if let turn = event.payload["turn"]?.value as? Int {
            lines.append("Turn: \(turn)")
        }
        if let latency = event.payload["latency"]?.value as? Int {
            lines.append("Latency: \(formatLatency(latency))")
        }
        if let stopReason = event.payload["stopReason"]?.value as? String {
            lines.append("Stop reason: \(stopReason)")
        }
        if event.payload["hasThinking"]?.value as? Bool == true {
            lines.append("Extended thinking: Yes")
        }
        if let tokenUsage = event.payload["tokenUsage"]?.value as? [String: Any] {
            if let input = tokenUsage["inputTokens"] as? Int,
               let output = tokenUsage["outputTokens"] as? Int {
                lines.append("Tokens: ↓\(formatTokens(input)) ↑\(formatTokens(output))")
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")

    case .toolCall:
        let name = (event.payload["name"]?.value as? String) ?? "unknown"
        let turn = (event.payload["turn"]?.value as? Int) ?? 0
        var lines = ["Tool: \(name)", "Turn: \(turn)"]
        if let args = event.payload["arguments"]?.value {
            let argsStr = formatJSON(args)
            if argsStr.count < 200 {
                lines.append("Arguments:\n\(argsStr)")
            }
        }
        return lines.joined(separator: "\n")

    case .toolResult:
        var lines: [String] = []
        if let duration = event.payload["duration"]?.value as? Int {
            lines.append("Duration: \(duration)ms")
        }
        let isError = (event.payload["isError"]?.value as? Bool) ?? false
        lines.append("Status: \(isError ? "Error" : "Success")")
        if event.payload["truncated"]?.value as? Bool == true {
            lines.append("Content: Truncated")
        }
        if let content = event.payload["content"]?.value as? String {
            let preview = truncate(content, to: 200)
            lines.append("\n\(preview)")
        }
        return lines.joined(separator: "\n")

    case .errorAgent, .errorProvider, .errorTool:
        var lines: [String] = []
        if let error = event.payload["error"]?.value as? String {
            lines.append("Error: \(error)")
        }
        if let code = event.payload["code"]?.value as? String {
            lines.append("Code: \(code)")
        }
        if let recoverable = event.payload["recoverable"]?.value as? Bool {
            lines.append("Recoverable: \(recoverable ? "Yes" : "No")")
        }
        if let retryable = event.payload["retryable"]?.value as? Bool {
            lines.append("Retryable: \(retryable ? "Yes" : "No")")
        }
        if let retryAfter = event.payload["retryAfter"]?.value as? Int {
            lines.append("Retry after: \(retryAfter)ms")
        }
        return lines.joined(separator: "\n")

    case .streamTurnEnd:
        var lines: [String] = []
        if let turn = event.payload["turn"]?.value as? Int {
            lines.append("Turn: \(turn)")
        }
        if let tokenUsage = event.payload["tokenUsage"]?.value as? [String: Any] {
            if let input = tokenUsage["inputTokens"] as? Int {
                lines.append("Input tokens: \(formatTokens(input))")
            }
            if let output = tokenUsage["outputTokens"] as? Int {
                lines.append("Output tokens: \(formatTokens(output))")
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")

    default:
        return nil
    }
}
```

---

## Enhancement 3: Session Analytics Sheet

### Goal
Provide comprehensive session analytics in a modal sheet, following [Apple's Human Interface Guidelines for Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets).

### Access Point

Add a chart button to the left of the settings button in `ChatView`:

```
┌─────────────────────────────────────────┐
│  ← Back    Session Title    📊  ⚙️      │
└─────────────────────────────────────────┘
                               ↑
                         Analytics button
```

### Sheet Design

Following Apple's sheet guidelines:
- Modal presentation with drag-to-dismiss
- Clear title and close button
- Scrollable content
- Respects safe areas

### Analytics Content

#### 1. Summary Stats Row
```
┌─────────────────────────────────────────┐
│   12        3.2s        2        1.5K   │
│  turns    avg lat    errors    tokens   │
└─────────────────────────────────────────┘
```

#### 2. Turn-by-Turn Breakdown
```
┌─────────────────────────────────────────┐
│ Turn Breakdown                          │
├─────────────────────────────────────────┤
│ Turn 1   ████████████░░░  892 tokens    │
│ Turn 2   █████░░░░░░░░░░  356 tokens    │
│ Turn 3   ██████████░░░░░  723 tokens    │
└─────────────────────────────────────────┘
```

#### 3. Tool Execution Summary
```
┌─────────────────────────────────────────┐
│ Tool Usage                              │
├─────────────────────────────────────────┤
│ 🔧 read     ×8    avg 23ms   total 184ms│
│ 🔧 edit     ×3    avg 45ms   total 135ms│
│ 🔧 bash     ×2    avg 120ms  total 240ms│
└─────────────────────────────────────────┘
```

#### 4. Model Usage
```
┌─────────────────────────────────────────┐
│ Model Usage                             │
├─────────────────────────────────────────┤
│ sonnet-4     ████████████████░  85%     │
│ opus-4       ████░░░░░░░░░░░░░  15%     │
└─────────────────────────────────────────┘
```

#### 5. Error Log (if any)
```
┌─────────────────────────────────────────┐
│ Errors                                  │
├─────────────────────────────────────────┤
│ ⚠️ 10:32  Provider: Rate limit (retried)│
│ ❌ 10:35  Tool: bash command failed     │
└─────────────────────────────────────────┘
```

### Implementation

**`Sources/Views/SessionAnalyticsSheet.swift`**

```swift
import SwiftUI
import Charts

struct SessionAnalyticsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let sessionId: String
    let events: [SessionEvent]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Summary stats
                    SummaryStatsRow(analytics: analytics)

                    // Turn breakdown
                    TurnBreakdownSection(turns: analytics.turns)

                    // Tool usage
                    if !analytics.toolUsage.isEmpty {
                        ToolUsageSection(tools: analytics.toolUsage)
                    }

                    // Model usage
                    if analytics.modelUsage.count > 1 {
                        ModelUsageSection(models: analytics.modelUsage)
                    }

                    // Errors
                    if !analytics.errors.isEmpty {
                        ErrorLogSection(errors: analytics.errors)
                    }
                }
                .padding()
            }
            .background(Color.tronBackground)
            .navigationTitle("Session Analytics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var analytics: SessionAnalytics {
        SessionAnalytics(from: events)
    }
}

// MARK: - Analytics Data Model

struct SessionAnalytics {
    struct TurnData: Identifiable {
        let id = UUID()
        let turn: Int
        let inputTokens: Int
        let outputTokens: Int
        var totalTokens: Int { inputTokens + outputTokens }
    }

    struct ToolData: Identifiable {
        let id = UUID()
        let name: String
        var count: Int
        var totalDuration: Int
        var avgDuration: Int { count > 0 ? totalDuration / count : 0 }
        var errorCount: Int
    }

    struct ModelData: Identifiable {
        let id = UUID()
        let model: String
        var tokenCount: Int
    }

    struct ErrorData: Identifiable {
        let id = UUID()
        let timestamp: Date
        let type: String // "agent", "provider", "tool"
        let message: String
        let isRecoverable: Bool
    }

    let turns: [TurnData]
    let toolUsage: [ToolData]
    let modelUsage: [ModelData]
    let errors: [ErrorData]

    var totalTurns: Int { turns.count }
    var totalTokens: Int { turns.reduce(0) { $0 + $1.totalTokens } }
    var totalErrors: Int { errors.count }
    var avgLatency: Int // Calculated from message.assistant events

    init(from events: [SessionEvent]) {
        // Parse events and compute analytics
        // ... implementation details ...
    }
}

// MARK: - Summary Stats Row

struct SummaryStatsRow: View {
    let analytics: SessionAnalytics

    var body: some View {
        HStack(spacing: 0) {
            StatCard(value: "\(analytics.totalTurns)", label: "turns")
            StatCard(value: formatLatency(analytics.avgLatency), label: "avg latency")
            StatCard(value: "\(analytics.totalErrors)", label: "errors")
            StatCard(value: formatTokens(analytics.totalTokens), label: "tokens")
        }
        .padding(.vertical, 16)
        .background(Color.tronSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct StatCard: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(.tronEmerald)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Turn Breakdown Section

struct TurnBreakdownSection: View {
    let turns: [SessionAnalytics.TurnData]

    private var maxTokens: Int {
        turns.map(\.totalTokens).max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Turn Breakdown")
                .font(.headline)
                .foregroundStyle(.tronTextPrimary)

            VStack(spacing: 8) {
                ForEach(turns) { turn in
                    HStack(spacing: 12) {
                        Text("Turn \(turn.turn)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tronTextSecondary)
                            .frame(width: 50, alignment: .leading)

                        GeometryReader { geo in
                            HStack(spacing: 0) {
                                // Input tokens (darker)
                                Rectangle()
                                    .fill(Color.tronEmerald.opacity(0.6))
                                    .frame(width: geo.size.width * ratio(turn.inputTokens))

                                // Output tokens (lighter)
                                Rectangle()
                                    .fill(Color.tronEmerald)
                                    .frame(width: geo.size.width * ratio(turn.outputTokens))
                            }
                        }
                        .frame(height: 16)
                        .background(Color.tronSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                        Text(formatTokens(turn.totalTokens))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tronTextMuted)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.tronSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func ratio(_ tokens: Int) -> CGFloat {
        CGFloat(tokens) / CGFloat(maxTokens)
    }
}

// MARK: - Tool Usage Section

struct ToolUsageSection: View {
    let tools: [SessionAnalytics.ToolData]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tool Usage")
                .font(.headline)
                .foregroundStyle(.tronTextPrimary)

            VStack(spacing: 8) {
                ForEach(tools) { tool in
                    HStack(spacing: 12) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 12))
                            .foregroundStyle(.tronCyan)

                        Text(tool.name)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronTextPrimary)

                        Spacer()

                        Text("×\(tool.count)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tronTextSecondary)

                        Text("avg \(tool.avgDuration)ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tronTextMuted)

                        if tool.errorCount > 0 {
                            Text("\(tool.errorCount) err")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tronError)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(16)
        .background(Color.tronSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Error Log Section

struct ErrorLogSection: View {
    let errors: [SessionAnalytics.ErrorData]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Errors")
                .font(.headline)
                .foregroundStyle(.tronTextPrimary)

            VStack(spacing: 8) {
                ForEach(errors) { error in
                    HStack(spacing: 12) {
                        Image(systemName: error.isRecoverable
                            ? "exclamationmark.triangle.fill"
                            : "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(error.isRecoverable ? .tronAmber : .tronError)

                        Text(formatTime(error.timestamp))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tronTextMuted)

                        Text(error.type.capitalized)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tronTextSecondary)

                        Text(error.message)
                            .font(.system(size: 12))
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .background(Color.tronSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
```

### ChatView Integration

**`Sources/Views/ChatView.swift`**

Add analytics button and sheet state:

```swift
struct ChatView: View {
    // ... existing properties ...

    @State private var showingAnalytics = false

    var body: some View {
        // ... existing content ...
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    // NEW: Analytics button
                    Button {
                        showingAnalytics = true
                    } label: {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }

                    // Existing: Settings button
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
        }
        .sheet(isPresented: $showingAnalytics) {
            SessionAnalyticsSheet(
                sessionId: sessionId,
                events: sessionEvents
            )
        }
    }
}
```

---

## Implementation Checklist

### Phase 1: Data Model Updates
- [ ] Add enriched fields to `ChatMessage` struct
- [ ] Update `ChatViewModel` to extract new fields during reconstruction
- [ ] Add helper functions for formatting (latency, tokens, model names)

### Phase 2: Per-Message Metadata
- [ ] Create `MessageMetadataBadge` component
- [ ] Update `MessageBubble` to use new badge
- [ ] Add "Thinking" label (not emoji) when applicable

### Phase 3: Enhanced Event Tree
- [ ] Update `SessionEventType.summary()` for all event types
- [ ] Update `TreeNodeRow` icons and colors
- [ ] Implement rich expanded content view
- [ ] Test with real session data for accuracy

### Phase 4: Session Analytics Sheet
- [ ] Create `SessionAnalytics` data model
- [ ] Create `SessionAnalyticsSheet` view
- [ ] Implement summary stats row
- [ ] Implement turn breakdown chart
- [ ] Implement tool usage table
- [ ] Implement error log
- [ ] Add analytics button to ChatView toolbar
- [ ] Connect sheet presentation

### Phase 5: Testing
- [ ] Test with sessions containing all event types
- [ ] Test with error scenarios (rate limits, tool failures)
- [ ] Test with model switching mid-session
- [ ] Test with extended thinking enabled
- [ ] Verify analytics calculations are accurate

---

## File Changes Summary

| File | Changes |
|------|---------|
| `Sources/Models/Message.swift` | Add enriched fields to `ChatMessage` |
| `Sources/Views/MessageBubble.swift` | Add `MessageMetadataBadge` component |
| `Sources/ViewModels/ChatViewModel.swift` | Extract enriched fields during reconstruction |
| `Sources/Database/EventTypes.swift` | Enhanced summaries for all event types |
| `Sources/Views/SessionTreeView.swift` | Updated icons, colors, expanded content |
| `Sources/Views/SessionAnalyticsSheet.swift` | **NEW** - Analytics sheet view |
| `Sources/Views/ChatView.swift` | Add analytics button and sheet |

---

## Design Notes

### Typography
- Monospaced fonts for technical data (tokens, latency, turn numbers)
- System fonts for labels and descriptions
- Consistent sizing: 10-11pt for metadata, 12-13pt for content

### Colors
- `.tronEmerald` - Primary accent, success states
- `.tronBlue` - User content, turn events
- `.tronPurple` - Assistant content
- `.tronCyan` - Tool operations
- `.tronAmber` - Warnings, retries, thinking
- `.tronError` - Errors, failures
- `.tronTextMuted` - Secondary information

### Spacing
- 8pt between related elements
- 16pt between sections
- 24pt between major content blocks

### Interaction
- Tap to expand event details in tree view
- Sheet with medium/large detents for analytics
- Drag indicator visible on sheets
