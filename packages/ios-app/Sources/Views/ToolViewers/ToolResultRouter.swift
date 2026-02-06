import SwiftUI

// MARK: - Tool Result Router
// Routes tool display through ToolRegistry — single source of truth for icon, name, summary, viewer.

struct ToolResultRouter: View {
    let tool: ToolUseData
    @State private var isExpanded = false

    private var descriptor: ToolDescriptor {
        ToolRegistry.descriptor(for: tool.toolName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolHeader

            if let result = tool.result, !result.isEmpty {
                resultViewer(for: result)
            }
        }
        .background(Color.tronSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(statusBorder, lineWidth: 0.5)
        )
    }

    private var toolHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: descriptor.icon)
                .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .medium))
                .foregroundStyle(descriptor.iconColor)
                .frame(width: 16)

            Text(descriptor.displayName)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)

            let detail = descriptor.summaryExtractor(tool.arguments)
            if !detail.isEmpty {
                Text(detail)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(1)
            }

            Spacer()

            statusBadge

            if let duration = tool.formattedDuration {
                Text(duration)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tronSurfaceElevated)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch tool.status {
        case .running:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronSuccess)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronError)
        }
    }

    @ViewBuilder
    private func resultViewer(for result: String) -> some View {
        if let factory = descriptor.viewerFactory {
            factory(tool, $isExpanded)
        } else {
            GenericResultViewer(result: result, isExpanded: $isExpanded)
        }
    }

    private var statusBorder: Color {
        switch tool.status {
        case .running: return .tronInfo.opacity(0.3)
        case .success: return .tronBorder.opacity(0.3)
        case .error: return .tronError.opacity(0.3)
        }
    }
}

// MARK: - Preview

#Preview("Core Tools") {
    ScrollView {
        VStack(spacing: 16) {
            ToolResultRouter(tool: ToolUseData(
                toolName: "Read",
                toolCallId: "read-123",
                arguments: "{\"file_path\": \"/Users/test/example.swift\"}",
                status: .success,
                result: "import Foundation\n\nstruct Example {\n    let name: String\n    var value: Int\n}\n",
                durationMs: 15
            ))

            ToolResultRouter(tool: ToolUseData(
                toolName: "Write",
                toolCallId: "write-123",
                arguments: "{\"file_path\": \"/Users/test/config.json\", \"content\": \"{\\n  \\\"name\\\": \\\"MyApp\\\",\\n  \\\"version\\\": \\\"1.0.0\\\",\\n  \\\"debug\\\": true\\n}\"}",
                status: .success,
                result: "Successfully wrote 256 bytes to config.json",
                durationMs: 8
            ))

            ToolResultRouter(tool: ToolUseData(
                toolName: "Edit",
                toolCallId: "edit-123",
                arguments: "{\"file_path\": \"/Users/test/server.py\"}",
                status: .success,
                result: "@@ -2,3 +2,6 @@\n \"\"\"\n Simple test server.\n-\"\"\"\n+\"\"\"\n+\n+Version: 1.0.0\n+Last modified by: AI\n",
                durationMs: 23
            ))

            ToolResultRouter(tool: ToolUseData(
                toolName: "Bash",
                toolCallId: "bash-123",
                arguments: "{\"command\": \"git status --short\"}",
                status: .success,
                result: "M  README.md\nA  src/new-file.ts\n?? temp/",
                durationMs: 45
            ))

            ToolResultRouter(tool: ToolUseData(
                toolName: "Grep",
                toolCallId: "grep-123",
                arguments: "{\"pattern\": \"TODO\", \"path\": \"./src\"}",
                status: .success,
                result: "src/app.ts:42:// TODO: Add error handling\nsrc/utils.ts:18:// TODO: Optimize this function\nsrc/main.ts:7:// TODO: Add logging",
                durationMs: 120
            ))

            ToolResultRouter(tool: ToolUseData(
                toolName: "Find",
                toolCallId: "find-123",
                arguments: "{\"pattern\": \"**/*.swift\"}",
                status: .success,
                result: "Sources/App/main.swift\nSources/Views/ChatView.swift\nSources/Models/Message.swift\nTests/AppTests.swift",
                durationMs: 35
            ))

            ToolResultRouter(tool: ToolUseData(
                toolName: "WebFetch",
                toolCallId: "webfetch-123",
                arguments: "{\"url\": \"https://docs.anthropic.com/overview\", \"prompt\": \"What models are available?\"}",
                status: .success,
                result: "Claude has three main model families: Claude 3.5 Sonnet, Claude 3.5 Haiku, and Claude 3 Opus.\n\nSource: https://docs.anthropic.com/overview\nTitle: Claude Models Overview",
                durationMs: 850
            ))

            ToolResultRouter(tool: ToolUseData(
                toolName: "WebSearch",
                toolCallId: "websearch-123",
                arguments: "{\"query\": \"Swift async await tutorial\"}",
                status: .success,
                result: "Found 5 results for 'Swift async await tutorial':\n\n1. **Swift Concurrency - Apple Developer**\n   https://developer.apple.com/documentation/swift/concurrency\n   Learn about Swift's modern approach to async code.",
                durationMs: 620
            ))

            ToolResultRouter(tool: ToolUseData(
                toolName: "Bash",
                toolCallId: "bash-running",
                arguments: "{\"command\": \"npm install\"}",
                status: .running,
                result: nil,
                durationMs: nil
            ))

            ToolResultRouter(tool: ToolUseData(
                toolName: "Read",
                toolCallId: "read-error",
                arguments: "{\"file_path\": \"/nonexistent/file.txt\"}",
                status: .error,
                result: "Error: File not found",
                durationMs: 5
            ))
        }
        .padding()
    }
    .background(Color.tronBackground)
    .preferredColorScheme(.dark)
}
