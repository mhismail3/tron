import SwiftUI
import UIKit

/// Detail sheet shown when tapping a subagent chip.
/// Displays task info, status, duration, turn count, and full output.
/// Shows real-time activity events while the subagent is running.
@available(iOS 26.0, *)
struct SubagentDetailSheet: View {
    let data: SubagentToolData
    let subagentState: SubagentState
    let eventStoreManager: EventStoreManager
    let rpcClient: RPCClient
    var onSendResults: ((SubagentToolData) -> Void)?
    @Environment(\.dismiss) private var dismiss

    /// Loading state for async event sync (running subagents)
    @State private var isLoadingEvents = false

    /// Chat history state (completed/failed subagents)
    @State private var chatEvents: [RawEvent] = []
    @State private var isLoadingChat = false
    @State private var chatLoadError: String? = nil

    /// Number of events to show per page
    private static let eventsPageSize = 15

    /// Number of visible events (pagination state)
    @State private var visibleEventCount: Int = eventsPageSize

    /// Whether summary is expanded (for long outputs)
    @State private var isSummaryExpanded: Bool = false

    /// Character limit before showing expand/collapse
    private static let summaryCharacterLimit = 500

    /// All events for this subagent (derived from state for real-time updates)
    private var allEvents: [SubagentEventItem] {
        subagentState.getEvents(for: data.subagentSessionId)
    }

    /// Visible events based on pagination
    private var visibleEvents: [SubagentEventItem] {
        Array(allEvents.prefix(visibleEventCount))
    }

    /// Whether there are more events to show
    private var hasMoreEvents: Bool {
        allEvents.count > visibleEventCount
    }

    /// Count of hidden events
    private var hiddenEventCount: Int {
        max(0, allEvents.count - visibleEventCount)
    }

    /// Chat messages derived from raw events (completed/failed subagents)
    private var chatMessages: [ChatMessage] {
        UnifiedEventTransformer.transformPersistedEvents(chatEvents)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    // Header tags (turns, duration, model) - left-aligned row
                    headerTags
                        .padding(.horizontal)

                    // Summary section (when completed - shown prominently at top)
                    if data.status == .completed, let output = data.fullOutput ?? data.resultSummary {
                        summarySection(content: output)
                            .padding(.horizontal)
                    }

                    // Error section (when failed - shown prominently)
                    if data.status == .failed, let error = data.error {
                        errorSection(error: error)
                            .padding(.horizontal)
                    }

                    // Task section
                    taskSection
                        .padding(.horizontal)

                    // Chat/Activity section
                    if data.status == .running {
                        // Running: show live activity stream
                        activitySection
                            .padding(.horizontal)
                    } else {
                        // Completed/Failed: show full chat with MessageBubble rendering
                        chatSection
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(titleText)
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(titleColor)
                }

                // Send to Agent button (top right) - when results are pending (completed or failed)
                if (data.status == .completed || data.status == .failed) && data.resultDeliveryStatus == .pending {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            onSendResults?(data)
                        } label: {
                            HStack(spacing: 6) {
                                Text("Send")
                                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(data.status == .completed ? Color.tronSuccess : Color.tronError)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .presentationDragIndicator(.hidden)
        .tint(titleColor)
        .preferredColorScheme(.dark)
        .task {
            if data.status == .running {
                // Running: load activity events for live streaming
                await loadSubagentEvents()
            } else {
                // Completed/Failed: load full chat history
                await loadChatHistory()
            }
        }
    }

    // MARK: - Event Loading

    /// Load subagent events - first from local DB, then sync from server if needed
    private func loadSubagentEvents() async {
        // Skip if already loaded with events
        if subagentState.hasLoadedEvents(for: data.subagentSessionId),
           !subagentState.getEvents(for: data.subagentSessionId).isEmpty {
            return
        }

        isLoadingEvents = true
        defer { isLoadingEvents = false }

        // First try loading from local database
        subagentState.loadEventsFromDatabase(for: data.subagentSessionId, eventDB: eventStoreManager.eventDB)

        // If still empty, sync from server then reload
        if subagentState.getEvents(for: data.subagentSessionId).isEmpty {
            // Sync subagent session events from server
            do {
                try await eventStoreManager.syncSessionEvents(sessionId: data.subagentSessionId)
                // Reload from database after sync
                subagentState.loadEventsFromDatabase(for: data.subagentSessionId, eventDB: eventStoreManager.eventDB, forceReload: true)
            } catch {
                // Sync failed - events will remain empty
            }
        }
    }

    /// Load full chat history from server for completed/failed subagents
    private func loadChatHistory() async {
        guard data.status != .running else { return }

        isLoadingChat = true
        chatLoadError = nil
        defer { isLoadingChat = false }

        do {
            let result = try await rpcClient.eventSync.getHistory(
                sessionId: data.subagentSessionId,
                types: nil,
                limit: 1000
            )
            chatEvents = result.events
        } catch {
            chatLoadError = error.localizedDescription
        }
    }

    // MARK: - Header Tags

    /// Compute effective turn count - use activity events if currentTurn is 0 for completed subagents
    private var effectiveTurnCount: Int {
        if data.currentTurn > 0 {
            return data.currentTurn
        }
        // For completed subagents with 0 turns, derive from activity events
        // Each turn typically has at least one tool call, so count unique tool events
        if data.status == .completed || data.status == .failed {
            let events = allEvents
            // Count tool events as proxy for turns (at minimum 1 if there's any activity)
            let toolCount = events.filter { $0.type == .tool }.count
            return max(1, toolCount > 0 ? (toolCount + 1) / 2 : 1) // Rough estimate: ~2 tools per turn on average, minimum 1
        }
        return data.currentTurn
    }

    private var headerTags: some View {
        HStack(spacing: 8) {
            SubagentStatBadge(label: "Turns:", value: "\(effectiveTurnCount)", color: titleColor)

            if let duration = data.formattedDuration {
                SubagentStatBadge(label: "Duration:", value: duration, color: titleColor)
            }

            if let model = data.model {
                SubagentStatBadge(label: "Model:", value: formatModelName(model), color: titleColor)
            }

            Spacer()
        }
    }

    // MARK: - Task Section

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            Text("Task")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            // Card content
            VStack(alignment: .leading, spacing: 8) {
                Text(data.task)
                    .font(TronTypography.mono(size: TronTypography.sizeBody3))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(titleColor.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Activity Section

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack {
                Text("Activity")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))

                // Event count badge
                if !allEvents.isEmpty {
                    Text("\(allEvents.count)")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(.white.opacity(0.1))
                        )
                }

                Spacer()

                if data.status == .running {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                        .tint(titleColor)
                }
            }

            // Card content
            VStack(alignment: .leading, spacing: 0) {
                if allEvents.isEmpty {
                    // Empty state - different message based on status and loading state
                    HStack(spacing: 8) {
                        if isLoadingEvents {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                                .tint(.white.opacity(0.4))
                            Text("Loading activity...")
                                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                                .foregroundStyle(.white.opacity(0.4))
                        } else if data.status == .running {
                            Image(systemName: "ellipsis")
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                                .foregroundStyle(.white.opacity(0.4))
                                .symbolEffect(.variableColor.iterative, options: .repeating)
                            Text("Waiting for activity...")
                                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                                .foregroundStyle(.white.opacity(0.4))
                        } else {
                            Image(systemName: "tray")
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                                .foregroundStyle(.white.opacity(0.4))
                            Text("No activity recorded")
                                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                } else {
                    // Event list with pagination
                    // Use LazyVStack for performance with many events
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleEvents) { event in
                            SubagentEventRow(event: event, accentColor: titleColor)
                                .id(event.id)
                        }

                        // "Show more" button when there are hidden events
                        if hasMoreEvents {
                            showMoreButton
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(titleColor.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Chat Section

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack {
                Text("Chat")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))

                if !chatMessages.isEmpty {
                    Text("\(chatMessages.count)")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.1)))
                }

                Spacer()
            }

            // Content
            if isLoadingChat {
                chatLoadingView
            } else if let error = chatLoadError {
                chatErrorView(error)
            } else if chatMessages.isEmpty {
                chatEmptyView
            } else {
                chatMessagesView
            }
        }
    }

    private var chatLoadingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.7)
                .frame(width: 14, height: 14)
                .tint(.white.opacity(0.4))
            Text("Loading chat history...")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(titleColor.opacity(0.12)),
                             in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func chatErrorView(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronError.opacity(0.8))
                Text("Failed to load chat history")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Text(error)
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.white.opacity(0.3))
            Button("Retry") {
                Task { await loadChatHistory() }
            }
            .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
            .foregroundStyle(titleColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(titleColor.opacity(0.12)),
                             in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var chatEmptyView: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.white.opacity(0.4))
            Text("No chat history")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(titleColor.opacity(0.12)),
                             in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var chatMessagesView: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(chatMessages) { message in
                MessageBubble(message: message)
            }
        }
    }

    // MARK: - Show More Button

    private var showMoreButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                visibleEventCount += Self.eventsPageSize
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                Text("Show \(min(hiddenEventCount, Self.eventsPageSize)) more")
                    .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .medium))
                Text("(\(hiddenEventCount) hidden)")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .foregroundStyle(titleColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(titleColor.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    // MARK: - Summary Section

    /// Whether content exceeds the character limit
    private func contentExceedsLimit(_ content: String) -> Bool {
        content.count > Self.summaryCharacterLimit
    }

    /// Truncated content for collapsed state
    private func truncatedContent(_ content: String) -> String {
        if content.count <= Self.summaryCharacterLimit {
            return content
        }
        // Find a good break point (newline or space) near the limit
        let searchRange = content.index(content.startIndex, offsetBy: min(Self.summaryCharacterLimit, content.count))
        if let breakIndex = content[..<searchRange].lastIndex(of: "\n") {
            return String(content[..<breakIndex])
        }
        if let breakIndex = content[..<searchRange].lastIndex(of: " ") {
            return String(content[..<breakIndex])
        }
        return String(content.prefix(Self.summaryCharacterLimit))
    }

    private func summarySection(content: String) -> some View {
        let needsExpansion = contentExceedsLimit(content)
        let displayContent = needsExpansion && !isSummaryExpanded
            ? truncatedContent(content)
            : content

        return VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack {
                Text("Summary")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                // Copy button
                Button {
                    UIPasteboard.general.string = content
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronSuccess.opacity(0.6))
                }
            }

            // Card content
            VStack(alignment: .leading, spacing: 0) {
                Text(displayContent)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)

                // Expand/collapse banner for long content
                if needsExpansion {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSummaryExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isSummaryExpanded ? "chevron.up" : "chevron.down")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                            Text(isSummaryExpanded ? "Show less" : "Show more")
                                .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .medium))
                            if !isSummaryExpanded {
                                Text("(\(content.count - Self.summaryCharacterLimit) more chars)")
                                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                        .foregroundStyle(.tronSuccess)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            Rectangle()
                                .fill(.tronSuccess.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronSuccess.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Error Section

    private func errorSection(error: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            Text("Error")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            // Card content
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronError)
                    Text("Failed")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronError)
                    Spacer()
                }

                Text(error)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronError.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Helpers

    private var titleText: String {
        switch data.status {
        case .running: return "Sub-Agent Running (Turn \(data.currentTurn))"
        case .completed: return "Sub-Agent Completed"
        case .failed: return "Sub-Agent Failed"
        }
    }

    private var titleColor: Color {
        switch data.status {
        case .running: return .tronAmber
        case .completed: return .tronSuccess
        case .failed: return .tronError
        }
    }

    private func formatModelName(_ model: String) -> String {
        // Extract the short name from full model ID
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model.count > 10 ? String(model.prefix(10)) + "..." : model
    }
}
