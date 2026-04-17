import SwiftUI

// MARK: - Import Session Flow

@available(iOS 26.0, *)
struct ImportSessionFlow: View {
    let rpcClient: RPCClient
    let onImported: (String, String, String) -> Void  // (sessionId, workingDirectory, model)

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ImportProjectListView(
                rpcClient: rpcClient,
                onImported: { sessionId, workingDirectory, model in
                    dismiss()
                    onImported(sessionId, workingDirectory, model)
                }
            )
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
    }
}

// MARK: - Project List

@available(iOS 26.0, *)
struct ImportProjectListView: View {
    let rpcClient: RPCClient
    let onImported: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sources: [ImportSource] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .tint(.tronEmerald)
                    Text("Scanning for sessions...")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                        .padding(.top, 8)
                    Spacer()
                }
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.tronError)
                    Text(error)
                        .font(TronTypography.subheadline)
                        .foregroundStyle(.tronTextSecondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding()
            } else if sources.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.title)
                        .foregroundStyle(.tronTextMuted)
                    Text("No Claude Code sessions found")
                        .font(TronTypography.subheadline)
                        .foregroundStyle(.tronTextSecondary)
                    Text("Sessions are stored in ~/.claude/projects/")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(sources) { source in
                            NavigationLink(value: source) {
                                ImportProjectCard(source: source)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronEmerald)
                }
            }
            ToolbarItem(placement: .principal) {
                Text("Import Session")
                    .font(TronTypography.button)
                    .foregroundStyle(.tronEmerald)
            }
        }
        .navigationDestination(for: ImportSource.self) { source in
            ImportSessionListView(
                rpcClient: rpcClient,
                source: source,
                onImported: onImported
            )
        }
        .task {
            await loadSources()
        }
    }

    private func loadSources() async {
        do {
            let result = try await rpcClient.importClient.listSources()
            await MainActor.run {
                sources = result.sources
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

// MARK: - Project Card

@available(iOS 26.0, *)
private struct ImportProjectCard: View {
    let source: ImportSource

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(.tronEmerald)

            VStack(alignment: .leading, spacing: 4) {
                Text(source.projectName)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)

                Text(source.projectPath)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text("\(source.sessionCount)")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronEmerald)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.2)), in: Capsule())

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tronTextMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.1)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Session List

@available(iOS 26.0, *)
struct ImportSessionListView: View {
    let rpcClient: RPCClient
    let source: ImportSource
    let onImported: (String, String, String) -> Void

    @State private var sessions: [ImportableSession] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView().tint(.tronEmerald)
                    Spacer()
                }
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.tronCoral)
                    Text(errorMessage)
                        .font(TronTypography.subheadline)
                        .foregroundStyle(.tronTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                }
            } else if sessions.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.title)
                        .foregroundStyle(.tronTextMuted)
                    Text("No sessions found")
                        .font(TronTypography.subheadline)
                        .foregroundStyle(.tronTextSecondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(sessions) { session in
                            if session.alreadyImported {
                                ImportSessionRow(session: session, isImported: true)
                            } else {
                                NavigationLink(value: session) {
                                    ImportSessionRow(session: session, isImported: false)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(source.projectName)
                    .font(TronTypography.button)
                    .foregroundStyle(.tronEmerald)
            }
        }
        .navigationDestination(for: ImportableSession.self) { session in
            ImportSessionPreviewView(
                rpcClient: rpcClient,
                session: session,
                projectPath: source.projectPath,
                onImported: onImported
            )
        }
        .task {
            await loadSessions()
        }
    }

    private func loadSessions() async {
        do {
            let result = try await rpcClient.importClient.listSessions(
                encodedDir: source.encodedDir
            )
            await MainActor.run {
                sessions = result.sessions
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

// MARK: - Session Row

@available(iOS 26.0, *)
private struct ImportSessionRow: View {
    let session: ImportableSession
    let isImported: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.displayTitle)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(isImported ? .tronTextMuted : .tronTextPrimary)
                    .lineLimit(2)

                Spacer()

                if isImported {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                        Text("Imported")
                            .font(TronTypography.codeCaption)
                    }
                    .foregroundStyle(.tronEmerald)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tronTextMuted)
                }
            }

            HStack(spacing: 8) {
                if let model = session.model {
                    Text(model.shortModelName)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronEmerald)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.15)), in: Capsule())
                }

                Text("\(session.messageCount) msgs")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)

                if let date = session.lastActivityAt {
                    Text(formatDate(date))
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(
            .regular.tint(Color.tronEmerald.opacity(isImported ? 0.05 : 0.1)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private static let isoFormatter = ISO8601DateFormatter()
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private func formatDate(_ iso: String) -> String {
        guard let date = Self.isoFormatter.date(from: iso) else { return iso }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Session Preview

@available(iOS 26.0, *)
struct ImportSessionPreviewView: View {
    let rpcClient: RPCClient
    let session: ImportableSession
    let projectPath: String
    let onImported: (String, String, String) -> Void

    @State private var preview: ImportSessionPreview?
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                VStack { Spacer(); ProgressView().tint(.tronEmerald); Spacer() }
            } else if let preview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        statsSection(preview.stats, totalMessages: preview.totalMessages)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Preview")
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                                .foregroundStyle(.tronTextSecondary)

                            ForEach(Array(processedMessages(preview.messages).enumerated()), id: \.offset) { _, item in
                                ImportPreviewRow(item: item)
                            }

                            if preview.totalMessages > preview.messages.count {
                                Text("+ \(preview.totalMessages - preview.messages.count) more messages")
                                    .font(TronTypography.codeCaption)
                                    .foregroundStyle(.tronTextMuted)
                                    .padding(.top, 4)
                            }
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(TronTypography.codeCaption)
                                .foregroundStyle(.tronError)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(session.displayTitle)
                    .font(TronTypography.button)
                    .foregroundStyle(.tronEmerald)
                    .lineLimit(1)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isImporting {
                    ProgressView().tint(.tronEmerald)
                } else {
                    Button {
                        Task { await importSession() }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(isLoading ? .tronTextDisabled : .tronEmerald)
                    }
                    .disabled(isLoading)
                }
            }
        }
        .interactiveDismissDisabled(isImporting)
        .task {
            await loadPreview()
        }
    }

    // MARK: - Stats

    @ViewBuilder
    private func statsSection(_ stats: ImportSessionStats, totalMessages: Int) -> some View {
        HStack(spacing: 8) {
            statChip("Messages", "\(totalMessages)")
            if let model = stats.model {
                statChip("Model", model.shortModelName)
            }
            if let cost = stats.estimatedCost, cost > 0 {
                statChip("Est. Cost", String(format: "$%.2f", cost))
            }
            if let input = stats.inputTokens, input > 0 {
                statChip("Input", formatTokens(input))
            }
            if let output = stats.outputTokens, output > 0 {
                statChip("Output", formatTokens(output))
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func statChip(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronEmerald)
            Text(label)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.1)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        }
        return "\(count)"
    }

    // MARK: - Message Processing

    /// A processed display item for the preview list.
    fileprivate enum PreviewItem {
        case userMessage(text: String)
        case userCommand(name: String)
        case assistantMessage(text: String, toolCalls: [ToolCallChip])
        case aggregatedToolCalls([ToolCallChip])
    }

    fileprivate struct ToolCallChip: Hashable {
        let name: String
        let count: Int
    }

    /// Regex to detect `<command-name>...</command-name>` XML blocks.
    private static let commandNameRegex = try! NSRegularExpression(
        pattern: "<command-name>([^<]+)</command-name>",
        options: []
    )

    /// Regex to match `[tool: Name]` references.
    private static let toolRefRegex = try! NSRegularExpression(
        pattern: "\\[tool: ([^\\]]+)\\]",
        options: []
    )

    private func processedMessages(_ messages: [ImportPreviewMessage]) -> [PreviewItem] {
        var items: [PreviewItem] = []
        var i = 0
        while i < messages.count {
            let msg = messages[i]
            if msg.role == "user" {
                items.append(processUserMessage(msg))
                i += 1
            } else {
                // Collect consecutive assistant messages
                var run: [ImportPreviewMessage] = []
                while i < messages.count && messages[i].role == "assistant" {
                    run.append(messages[i])
                    i += 1
                }
                items.append(contentsOf: processAssistantRun(run))
            }
        }
        return items
    }

    private func processUserMessage(_ msg: ImportPreviewMessage) -> PreviewItem {
        let text = msg.contentPreview
        let range = NSRange(text.startIndex..., in: text)
        if let match = Self.commandNameRegex.firstMatch(in: text, range: range),
           let nameRange = Range(match.range(at: 1), in: text) {
            return .userCommand(name: String(text[nameRange]))
        }
        return .userMessage(text: text)
    }

    private func processAssistantRun(_ run: [ImportPreviewMessage]) -> [PreviewItem] {
        // Separate tool-only messages from messages with actual text
        var items: [PreviewItem] = []
        var pendingToolOnly: [String] = [] // tool names from consecutive tool-only messages

        for msg in run {
            let parsed = parseAssistantContent(msg.contentPreview)
            if parsed.text.isEmpty && !parsed.tools.isEmpty {
                // Tool-only message
                pendingToolOnly.append(contentsOf: parsed.tools)
            } else {
                // Has text content — flush any pending tool-only aggregate first
                if !pendingToolOnly.isEmpty {
                    items.append(aggregateToolCalls(pendingToolOnly))
                    pendingToolOnly = []
                }
                let chips = parsed.tools.map { ToolCallChip(name: $0, count: 1) }
                items.append(.assistantMessage(text: parsed.text, toolCalls: chips))
            }
        }

        // Flush remaining tool-only messages
        if !pendingToolOnly.isEmpty {
            items.append(aggregateToolCalls(pendingToolOnly))
        }

        return items
    }

    private func parseAssistantContent(_ content: String) -> (text: String, tools: [String]) {
        var tools: [String] = []
        let range = NSRange(content.startIndex..., in: content)
        let matches = Self.toolRefRegex.matches(in: content, range: range)

        for match in matches {
            if let nameRange = Range(match.range(at: 1), in: content) {
                tools.append(String(content[nameRange]))
            }
        }

        // Remove [tool: ...] references from text
        let cleaned = Self.toolRefRegex.stringByReplacingMatches(
            in: content, range: range, withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return (cleaned, tools)
    }

    private func aggregateToolCalls(_ toolNames: [String]) -> PreviewItem {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for name in toolNames {
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        let chips = order.map { ToolCallChip(name: $0, count: counts[$0]!) }
        return .aggregatedToolCalls(chips)
    }

    // MARK: - Network

    private func loadPreview() async {
        do {
            let result = try await rpcClient.importClient.previewSession(
                sessionPath: session.sessionPath
            )
            await MainActor.run {
                preview = result
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func importSession() async {
        isImporting = true
        errorMessage = nil

        do {
            let result = try await rpcClient.importClient.execute(
                sessionPath: session.sessionPath,
                workingDirectory: projectPath
            )

            if result.alreadyImported {
                await MainActor.run {
                    errorMessage = "This session has already been imported."
                    isImporting = false
                }
                return
            }

            guard let sessionId = result.sessionId,
                  let workingDirectory = result.workingDirectory,
                  let model = result.model else {
                await MainActor.run {
                    errorMessage = "Import completed but response was missing data."
                    isImporting = false
                }
                return
            }

            await MainActor.run {
                isImporting = false
                onImported(sessionId, workingDirectory, model)
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isImporting = false
            }
        }
    }
}

// MARK: - Preview Message Row

@available(iOS 26.0, *)
private struct ImportPreviewRow: View {
    let item: ImportSessionPreviewView.PreviewItem

    var body: some View {
        switch item {
        case .userMessage(let text):
            userRow(text: text)
        case .userCommand(let name):
            userCommandRow(name: name)
        case .assistantMessage(let text, let tools):
            assistantRow(text: text, toolCalls: tools)
        case .aggregatedToolCalls(let tools):
            aggregatedToolRow(tools: tools)
        }
    }

    @ViewBuilder
    private func userRow(text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Spacer(minLength: 40)
            Text(text)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(4)
                .multilineTextAlignment(.trailing)
            Rectangle()
                .fill(Color.tronTextMuted.opacity(0.3))
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func userCommandRow(name: String) -> some View {
        HStack {
            Spacer()
            Text("/\(name) command used")
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular.tint(Color.tronTextMuted.opacity(0.1)), in: Capsule())
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func assistantRow(text: String, toolCalls: [ImportSessionPreviewView.ToolCallChip]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Color.tronEmerald)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))

            VStack(alignment: .leading, spacing: 4) {
                if !text.isEmpty {
                    Text(text)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(4)
                }

                ForEach(toolCalls, id: \.self) { tool in
                    toolChip(name: tool.name, count: tool.count)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func aggregatedToolRow(tools: [ImportSessionPreviewView.ToolCallChip]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Color.tronEmerald)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))

            VStack(alignment: .leading, spacing: 4) {
                ForEach(tools, id: \.self) { tool in
                    toolChip(name: tool.name, count: tool.count)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func toolChip(name: String, count: Int) -> some View {
        let label = count > 1
            ? "Called \(name) tool \(count) times"
            : "Called \(name) tool"
        Text(label)
            .font(TronTypography.codeCaption)
            .foregroundStyle(.tronEmerald.opacity(0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.1)), in: Capsule())
    }
}

