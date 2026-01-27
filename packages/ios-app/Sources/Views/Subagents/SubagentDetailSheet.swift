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
    @Environment(\.dismiss) private var dismiss

    /// Loading state for async event sync
    @State private var isLoadingEvents = false

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

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    // Header card (status, turns, duration)
                    headerCard
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

                    // Activity section - always show for subagents
                    // Events are loaded lazily in onAppear
                    activitySection
                        .padding(.horizontal)
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
            }
        }
        .presentationDragIndicator(.hidden)
        .tint(titleColor)
        .preferredColorScheme(.dark)
        .task {
            // Lazy load events for resumed sessions
            // First try local database, then sync from server if empty
            await loadSubagentEvents()
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

    // MARK: - Header Card

    private var headerCard: some View {
        HStack(spacing: 12) {
            // Status (left-aligned)
            statusIcon
            Text(statusText)
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(statusColor)

            Spacer()

            // Tags (right-aligned)
            HStack(spacing: 8) {
                SubagentStatBadge(label: "Turns", value: "\(data.currentTurn)", color: titleColor)

                if let duration = data.formattedDuration {
                    SubagentStatBadge(label: "Duration", value: duration, color: titleColor)
                }

                if let model = data.model {
                    SubagentStatBadge(label: "Model", value: formatModelName(model), color: titleColor)
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(titleColor.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

                if data.status == .running || data.status == .spawning {
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
                        } else if data.status == .running || data.status == .spawning {
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

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .spawning:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
                .tint(.tronBlue)       // Blue while spawning
        case .running:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
                .tint(.tronAmber)      // Amber while running
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }

    private var statusText: String {
        switch data.status {
        case .spawning: return "Spawning..."
        case .running: return "Running (turn \(data.currentTurn))"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    private var statusColor: Color {
        switch data.status {
        case .spawning: return .tronBlue       // Blue while spawning
        case .running: return .tronAmber       // Amber while running
        case .completed: return .tronSuccess
        case .failed: return .tronError
        }
    }

    private var titleText: String {
        switch data.status {
        case .spawning: return "Sub-Agent Spawning"
        case .running: return "Sub-Agent Running"
        case .completed: return "Sub-Agent Completed"
        case .failed: return "Sub-Agent Failed"
        }
    }

    private var titleColor: Color {
        switch data.status {
        case .spawning: return .tronBlue       // Blue while spawning
        case .running: return .tronAmber       // Amber while running
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
