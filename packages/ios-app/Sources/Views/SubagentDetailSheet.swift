import SwiftUI
import UIKit

/// Detail sheet shown when tapping a subagent chip.
/// Displays task info, status, duration, turn count, and full output.
/// Shows real-time activity events while the subagent is running.
@available(iOS 26.0, *)
struct SubagentDetailSheet: View {
    let data: SubagentToolData
    let subagentState: SubagentState
    @Environment(\.dismiss) private var dismiss

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

                    // Activity section (shows real-time events while running)
                    if !allEvents.isEmpty || data.status == .running || data.status == .spawning {
                        activitySection
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
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(titleColor)
                }
            }
        }
        .presentationDragIndicator(.hidden)
        .tint(titleColor)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header Card

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            Text("Status")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

            // Card content
            VStack(spacing: 16) {
                // Status badge
                HStack {
                    statusIcon
                    Text(statusText)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(statusColor)
                    Spacer()
                }

                // Stats row
                HStack(spacing: 12) {
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
    }

    // MARK: - Task Section

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            Text("Task")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

            // Card content
            VStack(alignment: .leading, spacing: 8) {
                Text(data.task)
                    .font(.system(size: 13, design: .monospaced))
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
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                // Event count badge
                if !allEvents.isEmpty {
                    Text("\(allEvents.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
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
                    // Waiting for events
                    HStack(spacing: 8) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                        Text("Waiting for activity...")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
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
                    .font(.system(size: 10, weight: .medium))
                Text("Show \(min(hiddenEventCount, Self.eventsPageSize)) more")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                Text("(\(hiddenEventCount) hidden)")
                    .font(.system(size: 10, design: .monospaced))
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
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                // Copy button
                Button {
                    UIPasteboard.general.string = content
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(.tronSuccess.opacity(0.6))
                }
            }

            // Card content
            VStack(alignment: .leading, spacing: 0) {
                Text(displayContent)
                    .font(.system(size: 12, design: .monospaced))
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
                                .font(.system(size: 10, weight: .medium))
                            Text(isSummaryExpanded ? "Show less" : "Show more")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                            if !isSummaryExpanded {
                                Text("(\(content.count - Self.summaryCharacterLimit) more chars)")
                                    .font(.system(size: 10, design: .monospaced))
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
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

            // Card content
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tronError)
                    Text("Failed")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronError)
                    Spacer()
                }

                Text(error)
                    .font(.system(size: 12, design: .monospaced))
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
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16, weight: .medium))
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

// MARK: - Helper Views

@available(iOS 26.0, *)
private struct SubagentStatBadge: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(color.opacity(0.2)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

// MARK: - Event Row

@available(iOS 26.0, *)
private struct SubagentEventRow: View {
    let event: SubagentEventItem
    let accentColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Event icon with optional spinner
            ZStack {
                eventIcon
                if event.isRunning {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.4)
                        .tint(iconColor)
                }
            }
            .frame(width: 16, height: 16)

            // Event content
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))

                    if event.isRunning {
                        Text("•")
                            .font(.system(size: 8))
                            .foregroundStyle(iconColor)
                    }
                }

                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(6)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)

            // Timestamp (only show for completed events)
            if !event.isRunning {
                Text(formatTime(event.timestamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background {
            if event.isRunning {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconColor.opacity(0.08))
            }
        }
    }

    private var iconColor: Color {
        switch event.type {
        case .tool:
            return event.isRunning ? .tronAmber : .tronEmerald
        case .output:
            return accentColor
        case .thinking:
            return .tronPurple
        }
    }

    @ViewBuilder
    private var eventIcon: some View {
        switch event.type {
        case .tool:
            if event.isRunning {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tronAmber)
            } else if event.title.contains("✗") {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tronError)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tronEmerald)
            }
        case .output:
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 11))
                .foregroundStyle(accentColor)
        case .thinking:
            Image(systemName: "brain")
                .font(.system(size: 11))
                .foregroundStyle(.tronPurple)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
