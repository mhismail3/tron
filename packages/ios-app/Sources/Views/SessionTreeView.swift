import SwiftUI

// MARK: - Session Tree View

/// Tree visualization for session history showing events, branch points, and fork/rewind capabilities.
struct SessionTreeView: View {
    let events: [SessionEvent]
    let headEventId: String?
    let sessionId: String
    @Binding var selectedEventId: String?
    /// Fork context for displaying parent session events differently
    var forkContext: SessionHistorySheet.ForkContext?
    let onFork: (String) -> Void
    let onRewind: (String) -> Void
    var isLoading: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Fork context header (if this is a forked session)
            if let context = forkContext {
                ForkContextHeader(context: context)
            }

            // Header with stats
            TreeStatsHeader(events: events, forkContext: forkContext)

            // Tree content
            if isLoading {
                LoadingTreeView()
            } else if events.isEmpty {
                EmptyTreeView()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sortedEvents, id: \.id) { event in
                                // Show fork divider before the fork event
                                if let context = forkContext,
                                   event.id == context.forkPointEventId {
                                    ForkDivider()
                                }

                                TreeNodeRow(
                                    event: event,
                                    isHead: event.id == headEventId,
                                    isSelected: event.id == selectedEventId,
                                    isOnPath: pathToHead.contains(event.id),
                                    isBranchPoint: branchPoints.contains(event.id),
                                    isFromParentSession: forkContext?.parentEventIds.contains(event.id) ?? false,
                                    depth: nodeDepths[event.id] ?? 0,
                                    onSelect: { selectedEventId = event.id },
                                    onFork: { onFork(event.id) },
                                    onRewind: { onRewind(event.id) }
                                )
                            }
                        }
                        .padding()
                    }
                    .onAppear {
                        // Scroll to HEAD
                        if let head = headEventId {
                            withAnimation {
                                proxy.scrollTo(head, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .background(Color.tronSurface)
    }

    // MARK: - Computed Properties

    private var sortedEvents: [SessionEvent] {
        events.sorted { $0.sequence < $1.sequence }
    }

    private var pathToHead: Set<String> {
        guard let head = headEventId else { return [] }
        var path = Set<String>()
        var current = head

        while true {
            path.insert(current)
            guard let event = events.first(where: { $0.id == current }),
                  let parentId = event.parentId else {
                break
            }
            current = parentId
        }

        return path
    }

    private var branchPoints: Set<String> {
        var childCounts: [String: Int] = [:]
        for event in events {
            if let parentId = event.parentId {
                childCounts[parentId, default: 0] += 1
            }
        }
        return Set(childCounts.filter { $0.value > 1 }.keys)
    }

    private var nodeDepths: [String: Int] {
        // Only increment depth at actual branch points, not for linear chains
        var depths: [String: Int] = [:]

        // Build parent -> children map
        var childrenOf: [String: [String]] = [:]
        for event in events {
            if let parentId = event.parentId {
                childrenOf[parentId, default: []].append(event.id)
            }
        }

        // Calculate depths - only increase depth after a branch point
        for event in sortedEvents {
            if event.parentId == nil {
                // Root event starts at depth 0
                depths[event.id] = 0
            } else if let parentId = event.parentId {
                let parentDepth = depths[parentId] ?? 0
                let siblings = childrenOf[parentId] ?? []

                if siblings.count > 1 {
                    // This is a branch point - all siblings get same depth (parent + 1)
                    // The "+siblingIndex" was causing a staircase effect - removed
                    depths[event.id] = parentDepth + 1
                } else {
                    // Linear chain - same depth as parent
                    depths[event.id] = parentDepth
                }
            }
        }

        return depths
    }

    private var maxDepth: Int {
        nodeDepths.values.max() ?? 0
    }
}

// MARK: - Fork Context Header

struct ForkContextHeader: View {
    let context: SessionHistorySheet.ForkContext

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12))
                .foregroundStyle(.tronAmber)

            VStack(alignment: .leading, spacing: 2) {
                Text("Forked Session")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tronAmber)

                HStack(spacing: 4) {
                    Text("from")
                        .font(.system(size: 10))
                        .foregroundStyle(.tronTextMuted)

                    Text(context.parentSessionTitle ?? "Unknown Session")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tronTextSecondary)
                }
            }

            Spacer()

            // Parent event count badge
            HStack(spacing: 3) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9))
                Text("\(context.parentEventIds.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.tronTextMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.tronSurfaceElevated)
            .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.tronAmber.opacity(0.1))
        .overlay(
            Rectangle()
                .fill(Color.tronAmber.opacity(0.3))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

// MARK: - Fork Divider

struct ForkDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.tronAmber.opacity(0.4))
                .frame(height: 1)

            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                Text("FORK POINT")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(.tronAmber)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.tronAmber.opacity(0.15))
            .clipShape(Capsule())

            Rectangle()
                .fill(Color.tronAmber.opacity(0.4))
                .frame(height: 1)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 28)  // Align with event rows
    }
}

// MARK: - Tree Stats Header

struct TreeStatsHeader: View {
    let events: [SessionEvent]
    var forkContext: SessionHistorySheet.ForkContext?

    private var branchCount: Int {
        var childCounts: [String: Int] = [:]
        for event in events {
            if let parentId = event.parentId {
                childCounts[parentId, default: 0] += 1
            }
        }
        return childCounts.filter { $0.value > 1 }.count
    }

    private var currentSessionEventCount: Int {
        if let context = forkContext {
            return events.count - context.parentEventIds.count
        }
        return events.count
    }

    var body: some View {
        HStack(spacing: 16) {
            if let context = forkContext {
                // Show breakdown for forked sessions
                StatBadge(value: currentSessionEventCount, label: "this session")
                StatBadge(value: context.parentEventIds.count, label: "inherited", isSecondary: true)
            } else {
                StatBadge(value: events.count, label: "events")
            }
            StatBadge(value: branchCount, label: "branches")
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
}

struct StatBadge: View {
    let value: Int
    let label: String
    var isSecondary: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(isSecondary ? .tronTextMuted : .tronEmerald)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tronTextMuted)
        }
    }
}

// MARK: - Tree Node Row

struct TreeNodeRow: View {
    let event: SessionEvent
    let isHead: Bool
    let isSelected: Bool
    let isOnPath: Bool
    let isBranchPoint: Bool
    /// Whether this event is from a parent session (for forked sessions)
    let isFromParentSession: Bool
    let depth: Int
    let hasNextSibling: Bool  // Whether there's another event at this depth after this one
    let onSelect: () -> Void
    let onFork: () -> Void
    let onRewind: () -> Void

    @State private var isExpanded = false

    /// Whether this event has expandable content to show
    private var hasExpandableContent: Bool {
        event.expandedContent != nil || !isHead
    }

    /// Background color based on selection state and parent session
    private var rowBackgroundColor: Color {
        if isSelected {
            return Color.tronEmerald.opacity(0.2)
        } else if isFromParentSession {
            // Parent session events have a subtle different tint
            return Color.tronTextMuted.opacity(0.08)
        } else if isOnPath {
            return Color.tronPhthaloGreen.opacity(0.15)
        } else {
            return Color.tronPhthaloGreen.opacity(0.08)
        }
    }

    /// Border color based on selection state
    private var rowBorderColor: Color {
        if isSelected {
            return Color.tronEmerald.opacity(0.4)
        } else if isFromParentSession {
            return Color.tronTextMuted.opacity(0.15)
        } else {
            return Color.tronBorder.opacity(0.2)
        }
    }

    /// Text color for parent session events
    private var textColor: Color {
        isFromParentSession ? .tronTextMuted : .tronTextPrimary
    }

    init(event: SessionEvent, isHead: Bool, isSelected: Bool, isOnPath: Bool, isBranchPoint: Bool, isFromParentSession: Bool = false, depth: Int, hasNextSibling: Bool = false, onSelect: @escaping () -> Void, onFork: @escaping () -> Void, onRewind: @escaping () -> Void) {
        self.event = event
        self.isHead = isHead
        self.isSelected = isSelected
        self.isOnPath = isOnPath
        self.isBranchPoint = isBranchPoint
        self.isFromParentSession = isFromParentSession
        self.depth = depth
        self.hasNextSibling = hasNextSibling
        self.onSelect = onSelect
        self.onFork = onFork
        self.onRewind = onRewind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row - number outside, content inside container
            HStack(alignment: .center, spacing: 8) {
                // Event sequence number - outside the container
                Text("\(event.sequence)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
                    .frame(width: 20, alignment: .trailing)

                // Content container
                HStack(spacing: 5) {
                    // Indentation for branched events only
                    if depth > 0 {
                        HStack(spacing: 0) {
                            ForEach(0..<depth, id: \.self) { _ in
                                Rectangle()
                                    .fill(Color.tronBorder.opacity(0.5))
                                    .frame(width: 1)
                                    .padding(.horizontal, 6)
                            }
                        }
                    }

                    // Node icon
                    eventIcon
                        .font(.system(size: 11))
                        .foregroundStyle(iconColor)
                        .frame(width: 16)

                    // Content
                    Text(event.summary)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(textColor)
                        .lineLimit(1)

                    // Parent session badge
                    if isFromParentSession {
                        Text("inherited")
                            .font(.system(size: 7, weight: .medium))
                            .foregroundStyle(.tronTextMuted)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.tronTextMuted.opacity(0.15))
                            .clipShape(Capsule())
                    }

                    if isHead {
                        Text("HEAD")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.tronEmerald)
                            .clipShape(Capsule())
                    }

                    if isBranchPoint {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                            .foregroundStyle(.tronAmber)
                    }

                    Spacer(minLength: 2)

                    // Expandable indicator
                    if hasExpandableContent {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(rowBackgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(rowBorderColor, lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            }

            // Expanded content and actions - aligned under the row container
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    // Show expanded content if available
                    if let content = event.expandedContent {
                        Text(content)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(10)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.tronSurfaceElevated.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.tronBorder.opacity(0.3), lineWidth: 0.5)
                            )
                    }

                    // Actions (only show if not HEAD)
                    if !isHead {
                        HStack(spacing: 8) {
                            Button(action: onFork) {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .font(.system(size: 10))
                                    Text("Fork")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.tronAmber)
                                .clipShape(Capsule())
                            }

                            Button(action: onRewind) {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 10))
                                    Text("Rewind")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.tronPurple)
                                .clipShape(Capsule())
                            }

                            Spacer()
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 28)  // Align under container (20px number + 8px spacing)
                .padding(.trailing, 0)
                .padding(.bottom, 2)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.25).delay(0.1)),
                    removal: .opacity.animation(.easeIn(duration: 0.15))
                ))
            }
        }
        .padding(.vertical, 1)
        .id(event.id)
    }

    // MARK: - Computed Properties

    // MARK: - Event Icon (Phase 3 enhanced)

    private var eventIcon: some View {
        Group {
            switch event.eventType {
            case .sessionStart:
                Image(systemName: "play.circle.fill")
            case .sessionEnd:
                Image(systemName: "stop.circle.fill")
            case .sessionFork:
                Image(systemName: "arrow.triangle.branch")
            case .messageUser:
                Image(systemName: "person.fill")
            case .messageAssistant:
                Image(systemName: "cpu")
            case .toolCall:
                Image(systemName: "wrench.and.screwdriver")
            case .toolResult:
                // Different icon based on success/error
                if (event.payload["isError"]?.value as? Bool) == true {
                    Image(systemName: "xmark.circle.fill")
                } else {
                    Image(systemName: "checkmark.circle.fill")
                }
            case .streamTurnStart:
                Image(systemName: "arrow.right.circle")
            case .streamTurnEnd:
                Image(systemName: "arrow.down.circle")
            case .errorAgent:
                Image(systemName: "exclamationmark.triangle.fill")
            case .errorProvider:
                Image(systemName: "arrow.clockwise.circle")
            case .errorTool:
                Image(systemName: "xmark.octagon")
            case .configModelSwitch:
                Image(systemName: "arrow.left.arrow.right")
            case .compactBoundary:
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            default:
                Image(systemName: "circle.fill")
            }
        }
    }

    // MARK: - Icon Color (Phase 3 enhanced)

    private var iconColor: Color {
        switch event.eventType {
        case .sessionStart:
            return .tronSuccess
        case .sessionEnd:
            return .tronTextMuted
        case .sessionFork:
            return .tronAmber
        case .messageUser:
            return .tronBlue
        case .messageAssistant:
            return .tronPurple
        case .toolCall:
            return .tronCyan
        case .toolResult:
            // Different color based on success/error
            if (event.payload["isError"]?.value as? Bool) == true {
                return .tronError
            }
            return .tronSuccess
        case .streamTurnStart, .streamTurnEnd:
            return .tronBlue
        case .errorAgent, .errorTool:
            return .tronError
        case .errorProvider:
            return .tronAmber
        case .configModelSwitch:
            return .tronEmerald
        case .compactBoundary:
            return .tronTextMuted
        default:
            return .tronTextMuted
        }
    }

    private var formattedTime: String {
        if let date = ISO8601DateFormatter().date(from: event.timestamp) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        return ""
    }
}

// MARK: - Loading & Empty States

struct LoadingTreeView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.tronEmerald)
            Text("Loading history...")
                .font(.subheadline)
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyTreeView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tronTextMuted)

            Text("No History")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.tronTextPrimary)

            Text("Events will appear here as you interact")
                .font(.caption)
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Compact Tree (for inline display)

struct CompactTreeView: View {
    let events: [SessionEvent]
    let headEventId: String?
    let onTap: () -> Void

    private var pathEvents: [SessionEvent] {
        guard let head = headEventId else { return [] }

        var path: [SessionEvent] = []
        var current = head

        while true {
            guard let event = events.first(where: { $0.id == current }) else { break }
            path.insert(event, at: 0)

            guard let parentId = event.parentId else { break }
            current = parentId
        }

        // Show key nodes only: start, branch points, and last 3
        let branchPoints = Set(events.compactMap { $0.parentId }.filter { parentId in
            events.filter { $0.parentId == parentId }.count > 1
        })

        return path.enumerated().filter { index, event in
            index == 0 || // First
            branchPoints.contains(event.id) || // Branch points
            index >= path.count - 3 // Last 3
        }.map { $0.element }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 2) {
                ForEach(Array(pathEvents.enumerated()), id: \.element.id) { index, event in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tronTextMuted)
                    }

                    compactIcon(for: event)
                        .font(.system(size: 10))
                        .foregroundStyle(event.id == headEventId ? .tronEmerald : .tronTextSecondary)
                }

                if pathEvents.isEmpty {
                    Text("No history")
                        .font(.caption2)
                        .foregroundStyle(.tronTextMuted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.tronSurfaceElevated)
            .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func compactIcon(for event: SessionEvent) -> some View {
        switch event.eventType {
        case .sessionStart:
            Image(systemName: "play.circle.fill")
        case .sessionFork:
            Image(systemName: "arrow.triangle.branch")
        case .messageUser:
            Image(systemName: "person.fill")
        case .messageAssistant:
            Image(systemName: "cpu")
        case .toolCall:
            Image(systemName: "wrench.fill")
        default:
            Image(systemName: "circle.fill")
        }
    }
}

// MARK: - Session History Sheet

struct SessionHistorySheet: View {
    @EnvironmentObject var eventStoreManager: EventStoreManager
    @Environment(\.dismiss) private var dismiss

    let sessionId: String
    let rpcClient: RPCClient

    @State private var events: [SessionEvent] = []
    @State private var selectedEventId: String?
    @State private var isLoading = true
    @State private var actionConfirm: ActionConfirm?
    @State private var forkContext: ForkContext?

    /// Context about the fork relationship for UI display
    struct ForkContext {
        let parentSessionId: String
        let forkEventId: String  // The event we forked from (in parent session)
        let forkPointEventId: String  // The session.fork event in this session
        let parentSessionTitle: String?
        /// IDs of events that belong to the parent session (displayed differently)
        let parentEventIds: Set<String>
    }

    enum ActionConfirm {
        case fork(String)
        case rewind(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.tronBackground
                    .ignoresSafeArea()

                if let confirm = actionConfirm {
                    confirmationView(for: confirm)
                } else {
                    SessionTreeView(
                        events: events,
                        headEventId: eventStoreManager.activeSession?.headEventId,
                        sessionId: sessionId,
                        selectedEventId: $selectedEventId,
                        forkContext: forkContext,
                        onFork: { eventId in
                            actionConfirm = .fork(eventId)
                        },
                        onRewind: { eventId in
                            actionConfirm = .rewind(eventId)
                        },
                        isLoading: isLoading
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Session History")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await loadEvents()
        }
    }

    private func loadEvents() async {
        isLoading = true

        do {
            // First sync session events from server
            try await eventStoreManager.syncSessionEvents(sessionId: sessionId)

            // Check if this is a forked session
            let session = try? eventStoreManager.eventDB.getSession(sessionId)
            let isFork = session?.isFork == true

            if isFork, let rootEventId = session?.rootEventId {
                // For forked sessions, load the full ancestor chain
                // This includes parent session events linked via parent_id
                events = try eventStoreManager.eventDB.getAncestors(rootEventId)

                // Also get any events after the root (children of root in this session)
                let sessionEvents = try eventStoreManager.getSessionEvents(sessionId)
                let rootIds = Set(events.map { $0.id })
                for event in sessionEvents where !rootIds.contains(event.id) {
                    events.append(event)
                }

                // Build fork context for UI display
                forkContext = buildForkContext(events: events, currentSessionId: sessionId)

                logger.info("Loaded forked session with \(events.count) events (including parent history)", category: .session)
            } else {
                // Regular session - just get session events
                events = try eventStoreManager.getSessionEvents(sessionId)
                forkContext = nil
            }
        } catch {
            logger.error("Failed to load events: \(error)", category: .session)
        }

        isLoading = false
    }

    /// Build fork context from events to identify parent session events
    private func buildForkContext(events: [SessionEvent], currentSessionId: String) -> ForkContext? {
        // Find the session.fork event in this session
        let forkEvents = events.filter { event in
            event.eventType == .sessionFork && event.sessionId == currentSessionId
        }
        guard let forkEvent = forkEvents.first else {
            return nil
        }

        // Parse the fork payload to get parent info
        let payload = SessionForkPayload(from: forkEvent.payload)
        guard let parentSessionId = payload?.sourceSessionId,
              let forkEventId = payload?.sourceEventId else {
            return nil
        }

        // Get parent session title
        let parentSession = try? eventStoreManager.eventDB.getSession(parentSessionId)
        let parentTitle = parentSession?.displayTitle

        // Identify which events belong to parent session(s)
        let parentEvents = events.filter { event in
            event.sessionId != currentSessionId
        }
        let parentEventIds = Set(parentEvents.map { $0.id })

        return ForkContext(
            parentSessionId: parentSessionId,
            forkEventId: forkEventId,
            forkPointEventId: forkEvent.id,
            parentSessionTitle: parentTitle,
            parentEventIds: parentEventIds
        )
    }

    @ViewBuilder
    private func confirmationView(for confirm: ActionConfirm) -> some View {
        VStack(spacing: 24) {
            switch confirm {
            case .fork(let eventId):
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.tronAmber)

                Text("Fork Session?")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tronTextPrimary)

                Text("This will create a new session branch from this point. Your current work will be preserved.")
                    .font(.subheadline)
                    .foregroundStyle(.tronTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                HStack(spacing: 16) {
                    Button("Cancel") {
                        actionConfirm = nil
                    }
                    .buttonStyle(.bordered)
                    .tint(.tronTextSecondary)

                    Button("Fork") {
                        Task {
                            await performFork(eventId)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.tronAmber)
                }

            case .rewind(let eventId):
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.tronPurple)

                Text("Rewind Session?")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tronTextPrimary)

                Text("This will move HEAD back to this event. Events after this point will remain in history but won't be active.")
                    .font(.subheadline)
                    .foregroundStyle(.tronTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                HStack(spacing: 16) {
                    Button("Cancel") {
                        actionConfirm = nil
                    }
                    .buttonStyle(.bordered)
                    .tint(.tronTextSecondary)

                    Button("Rewind") {
                        Task {
                            await performRewind(eventId)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.tronPurple)
                }
            }
        }
        .padding(32)
    }

    private func performFork(_ eventId: String) async {
        logger.debug("Fork initiated: sessionId=\(sessionId), fromEventId=\(eventId)", category: .session)
        if let event = events.first(where: { $0.id == eventId }) {
            logger.debug("Fork point: type=\(event.type), sequence=\(event.sequence)", category: .session)
        }

        do {
            let newSessionId = try await eventStoreManager.forkSession(sessionId, fromEventId: eventId)
            logger.debug("Fork succeeded: newSessionId=\(newSessionId)", category: .session)
            eventStoreManager.setActiveSession(newSessionId)
            dismiss()
        } catch {
            logger.error("Fork FAILED: \(error)", category: .session)
            actionConfirm = nil
        }
    }

    private func performRewind(_ eventId: String) async {
        logger.debug("Rewind initiated: sessionId=\(sessionId), toEventId=\(eventId)", category: .session)
        if let event = events.first(where: { $0.id == eventId }) {
            logger.debug("Rewind target: type=\(event.type), sequence=\(event.sequence)", category: .session)
        }
        let currentHeadId = eventStoreManager.activeSession?.headEventId
        if let headId = currentHeadId, let currentHead = events.first(where: { $0.id == headId }) {
            logger.debug("Current HEAD: type=\(currentHead.type), sequence=\(currentHead.sequence)", category: .session)
        } else {
            logger.debug("Current HEAD: \(currentHeadId ?? "unknown")", category: .session)
        }

        do {
            try await eventStoreManager.rewindSession(sessionId, toEventId: eventId)
            logger.debug("Rewind succeeded, dismissing sheet", category: .session)
            dismiss()
        } catch {
            logger.error("Rewind FAILED: \(error)", category: .session)
            actionConfirm = nil
        }
    }
}

