import SwiftUI

// MARK: - Session Fork Context

/// Context about the fork relationship for UI display
struct SessionForkContext {
    let parentSessionId: String
    let forkEventId: String  // The event we forked from (in parent session)
    let forkPointEventId: String  // The session.fork event in this session
    let parentSessionTitle: String?
    /// IDs of events that belong to the parent session (displayed differently)
    let parentEventIds: Set<String>
}

// MARK: - Sibling Branch Info

/// Information about a sibling branch (another session forked from the same event)
struct SiblingBranchInfo: Identifiable {
    let id: String  // sessionId
    let sessionTitle: String?
    let eventCount: Int
    let lastActivity: String
    var events: [SessionEvent]  // Loaded lazily on expand

    var displayTitle: String {
        sessionTitle ?? "Session \(id.prefix(8))"
    }
}

// MARK: - Session History ViewModel

/// ViewModel for managing session history tree state including sibling branches
@MainActor
class SessionHistoryViewModel: ObservableObject {
    @Published var events: [SessionEvent] = []
    @Published var siblingBranches: [String: [SiblingBranchInfo]] = [:]  // keyed by fork point event ID
    @Published var expandedBranchPoints: Set<String> = []
    @Published var isLoading = true
    @Published var forkContext: SessionForkContext?

    private let eventStoreManager: EventStoreManager
    private let rpcClient: RPCClient
    let sessionId: String

    init(sessionId: String, eventStoreManager: EventStoreManager, rpcClient: RPCClient) {
        self.sessionId = sessionId
        self.eventStoreManager = eventStoreManager
        self.rpcClient = rpcClient
    }

    var headEventId: String? {
        eventStoreManager.activeSession?.headEventId
    }

    func loadEvents() async {
        isLoading = true

        do {
            // First sync session events from server
            try await eventStoreManager.syncSessionEvents(sessionId: sessionId)

            // Check if this is a forked session
            let session = try? eventStoreManager.eventDB.getSession(sessionId)
            let isFork = session?.isFork == true

            if isFork, let rootEventId = session?.rootEventId {
                // For forked sessions, load the full ancestor chain
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

            // Find all branch points and load sibling info
            await loadSiblingBranches()
        } catch {
            logger.error("Failed to load events: \(error)", category: .session)
        }

        isLoading = false
    }

    /// Load sibling branch information for all fork points in the current tree
    private func loadSiblingBranches() async {
        // Find events that have children in other sessions (fork points)
        for event in events {
            do {
                let siblings = try eventStoreManager.eventDB.getSiblingBranches(
                    forEventId: event.id,
                    excludingSessionId: sessionId
                )

                if !siblings.isEmpty {
                    let branchInfos = siblings.map { session in
                        SiblingBranchInfo(
                            id: session.id,
                            sessionTitle: session.displayTitle,
                            eventCount: session.eventCount,
                            lastActivity: session.lastActivityAt,
                            events: []  // Load lazily
                        )
                    }
                    siblingBranches[event.id] = branchInfos
                }
            } catch {
                logger.warning("Failed to load siblings for event \(event.id): \(error)", category: .session)
            }
        }
    }

    /// Load events for a sibling branch when expanded
    func loadBranchEvents(forEventId eventId: String, branchSessionId: String) async {
        guard var branches = siblingBranches[eventId],
              let index = branches.firstIndex(where: { $0.id == branchSessionId }) else {
            return
        }

        do {
            let branchEvents = try eventStoreManager.getSessionEvents(branchSessionId)
            branches[index].events = branchEvents
            siblingBranches[eventId] = branches
        } catch {
            logger.warning("Failed to load branch events: \(error)", category: .session)
        }
    }

    func toggleBranchExpanded(eventId: String) {
        withAnimation(.tronStandard) {
            if expandedBranchPoints.contains(eventId) {
                expandedBranchPoints.remove(eventId)
            } else {
                expandedBranchPoints.insert(eventId)

                // Load events for all sibling branches at this point
                if let branches = siblingBranches[eventId] {
                    for branch in branches where branch.events.isEmpty {
                        Task {
                            await loadBranchEvents(forEventId: eventId, branchSessionId: branch.id)
                        }
                    }
                }
            }
        }
    }

    /// Build fork context from events to identify parent session events
    private func buildForkContext(events: [SessionEvent], currentSessionId: String) -> SessionForkContext? {
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

        return SessionForkContext(
            parentSessionId: parentSessionId,
            forkEventId: forkEventId,
            forkPointEventId: forkEvent.id,
            parentSessionTitle: parentTitle,
            parentEventIds: parentEventIds
        )
    }
}

// MARK: - Session History View (Redesigned)

/// Clean, mobile-first session history with clear inherited/current separation.
@available(iOS 26.0, *)
struct SessionHistoryView: View {
    let events: [SessionEvent]
    let headEventId: String?
    let sessionId: String
    var forkContext: SessionForkContext?
    let onFork: (String) -> Void
    var isLoading: Bool = false

    @State private var isInheritedExpanded = false
    @State private var selectedEventId: String?

    // MARK: - Computed Properties

    /// Events sorted chronologically (oldest first)
    private var sortedEvents: [SessionEvent] {
        events.sorted { $0.timestamp < $1.timestamp }
    }

    /// Events from parent session(s) - the inherited history
    private var inheritedEvents: [SessionEvent] {
        guard let context = forkContext else { return [] }
        return sortedEvents.filter { context.parentEventIds.contains($0.id) }
    }

    /// Events from this session only
    private var thisSessionEvents: [SessionEvent] {
        sortedEvents.filter { $0.sessionId == sessionId }
    }

    /// The event where this session forked from (in parent)
    private var forkPointEvent: SessionEvent? {
        guard let context = forkContext else { return nil }
        return events.first { $0.id == context.forkEventId }
    }

    /// Filter out noise events for cleaner display
    private func isSignificantEvent(_ event: SessionEvent) -> Bool {
        switch event.eventType {
        case .sessionStart, .sessionFork, .messageUser, .messageAssistant, .toolCall, .toolResult:
            return true
        case .streamTurnStart, .streamTurnEnd, .compactBoundary:
            return false  // Hide streaming noise
        default:
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                LoadingHistoryView()
            } else if events.isEmpty {
                EmptyHistoryView()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            // Forked session: show inherited + this session
                            if forkContext != nil {
                                ForkedSessionContent(proxy: proxy)
                            } else {
                                // Linear session: just show all events
                                LinearSessionContent(proxy: proxy)
                            }
                        }
                        .padding()
                    }
                }
            }
        }
    }

    // MARK: - Forked Session Layout

    @ViewBuilder
    private func ForkedSessionContent(proxy: ScrollViewProxy) -> some View {
        // Inherited Section (collapsible)
        InheritedSection(
            events: inheritedEvents.filter { isSignificantEvent($0) },
            forkPointEvent: forkPointEvent,
            isExpanded: $isInheritedExpanded,
            parentTitle: forkContext?.parentSessionTitle,
            onFork: onFork
        )

        // This Session Section
        ThisSessionSection(
            events: thisSessionEvents.filter { isSignificantEvent($0) },
            headEventId: headEventId,
            onFork: onFork
        )
        .onAppear {
            // Scroll to HEAD
            if let head = headEventId {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation {
                        proxy.scrollTo(head, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Linear Session Layout

    @ViewBuilder
    private func LinearSessionContent(proxy: ScrollViewProxy) -> some View {
        SectionCard(title: "Session Timeline", icon: "clock", accentColor: .tronPurple) {
            VStack(spacing: 2) {
                ForEach(sortedEvents.filter { isSignificantEvent($0) }) { event in
                    EventRow(
                        event: event,
                        isHead: event.id == headEventId,
                        showForkButton: event.id != headEventId,
                        onFork: { onFork(event.id) }
                    )
                    .id(event.id)
                }
            }
        }
        .onAppear {
            if let head = headEventId {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation {
                        proxy.scrollTo(head, anchor: .center)
                    }
                }
            }
        }
    }
}

// MARK: - Inherited Section

@available(iOS 26.0, *)
struct InheritedSection: View {
    let events: [SessionEvent]
    let forkPointEvent: SessionEvent?
    @Binding var isExpanded: Bool
    let parentTitle: String?
    let onFork: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header (always visible, tappable)
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14))
                        .foregroundStyle(.tronPurple)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Inherited from \(parentTitle ?? "parent")")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)

                        Text("\(events.count) events")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tronTextMuted)
                    }

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                        .rotationEffect(.degrees(isExpanded ? -180 : 0))
                }
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular.tint(Color.tronPurple.opacity(0.25)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(events) { event in
                        EventRow(
                            event: event,
                            isHead: false,
                            isMuted: true,
                            showForkButton: true,
                            onFork: { onFork(event.id) }
                        )
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.top, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }

            // Fork point indicator (always visible)
            if let forkPoint = forkPointEvent {
                ForkPointIndicator(event: forkPoint)
                    .padding(.top, 12)
            }
        }
    }
}

// MARK: - This Session Section

struct ThisSessionSection: View {
    let events: [SessionEvent]
    let headEventId: String?
    let onFork: (String) -> Void

    var body: some View {
        SectionCard(title: "This Session", icon: "sparkles", accentColor: .tronPurple) {
            if events.isEmpty || (events.count == 1 && events.first?.eventType == .sessionFork) {
                // Empty state - just forked, no new messages
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tronTextMuted.opacity(0.5))

                    Text("No new messages yet")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tronTextMuted)

                    Text("Start chatting to build history")
                        .font(.system(size: 11))
                        .foregroundStyle(.tronTextMuted.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 2) {
                    ForEach(events) { event in
                        // Skip the fork event itself in display
                        if event.eventType != .sessionFork {
                            EventRow(
                                event: event,
                                isHead: event.id == headEventId,
                                showForkButton: event.id != headEventId,
                                onFork: { onFork(event.id) }
                            )
                            .id(event.id)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Section Card (Legacy)

struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    let accentColor: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(accentColor.opacity(0.8))
            .padding(.leading, 4)

            // Content
            VStack(spacing: 0) {
                content()
            }
            .padding(12)
            .background(Color.tronSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(accentColor.opacity(0.15), lineWidth: 1)
            )
        }
    }
}

// MARK: - Glass Section Card (iOS 26+)

@available(iOS 26.0, *)
struct GlassSectionCard<Content: View>: View {
    let title: String
    let icon: String
    let accentColor: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(accentColor.opacity(0.8))
            .padding(.leading, 4)

            // Content with glass effect
            VStack(spacing: 0) {
                content()
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(accentColor.opacity(0.2)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

// MARK: - Fork Point Indicator

struct ForkPointIndicator: View {
    let event: SessionEvent

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.tronPurple.opacity(0.3))
                .frame(height: 1)

            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                Text("FORKED HERE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(.tronPurple)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.tronPurple.opacity(0.12))
            .clipShape(Capsule())

            Rectangle()
                .fill(Color.tronPurple.opacity(0.3))
                .frame(height: 1)
        }
    }
}

// MARK: - Event Row

struct EventRow: View {
    let event: SessionEvent
    var isHead: Bool = false
    var isMuted: Bool = false
    var showForkButton: Bool = true
    let onFork: () -> Void

    @State private var isExpanded = false

    /// Whether this event has expandable content to show
    private var hasExpandableContent: Bool {
        event.expandedContent != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row - tappable to expand
            HStack(spacing: 10) {
                // Icon
                eventIcon
                    .font(.system(size: 12))
                    .foregroundStyle(isMuted ? iconColor.opacity(0.5) : iconColor)
                    .frame(width: 20)

                // Summary
                Text(event.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isMuted ? .tronTextMuted : .tronTextPrimary)
                    .lineLimit(1)

                Spacer()

                // HEAD badge
                if isHead {
                    Text("HEAD")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tronPurple)
                        .clipShape(Capsule())
                }

                // Expand indicator (if has content)
                if hasExpandableContent {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                }

                // Fork button with circular background
                if showForkButton {
                    Button(action: onFork) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                            .foregroundStyle(.tronPurple)
                            .frame(width: 28, height: 28)
                            .background(Color.tronPurple.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(isHead ? Color.tronPurple.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                if hasExpandableContent {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            }

            // Expanded content
            if isExpanded, let content = event.expandedContent {
                Text(content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isMuted ? .tronTextMuted : .tronTextSecondary)
                    .lineLimit(12)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.tronSurfaceElevated.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 4)
                    .padding(.leading, 30) // Align under content
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }

    @ViewBuilder
    private var eventIcon: some View {
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
            Image(systemName: "wrench.and.screwdriver")
        case .toolResult:
            if (event.payload["isError"]?.value as? Bool) == true {
                Image(systemName: "xmark.circle.fill")
            } else {
                Image(systemName: "checkmark.circle.fill")
            }
        default:
            Image(systemName: "circle.fill")
        }
    }

    private var iconColor: Color {
        switch event.eventType {
        case .sessionStart: return .tronSuccess
        case .sessionFork: return .tronPurple
        case .messageUser: return .tronBlue
        case .messageAssistant: return .tronPurple
        case .toolCall: return .tronCyan
        case .toolResult:
            if (event.payload["isError"]?.value as? Bool) == true {
                return .tronError
            }
            return .tronSuccess
        default: return .tronTextMuted
        }
    }
}

// MARK: - Loading & Empty States

struct LoadingHistoryView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.tronPurple)
            Text("Loading history...")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyHistoryView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tronTextMuted.opacity(0.5))

            Text("No History")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.tronTextPrimary)

            Text("Events will appear as you chat")
                .font(.system(size: 12))
                .foregroundStyle(.tronTextMuted)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Legacy Session Tree View (kept for compatibility)

/// Tree visualization for session history showing events, branch points, and fork capabilities.
struct SessionTreeView: View {
    let events: [SessionEvent]
    let headEventId: String?
    let sessionId: String
    @Binding var selectedEventId: String?
    /// Fork context for displaying parent session events differently
    var forkContext: SessionForkContext?
    /// Sibling branches keyed by fork point event ID
    var siblingBranches: [String: [SiblingBranchInfo]] = [:]
    /// Currently expanded branch points
    var expandedBranchPoints: Set<String> = []
    let onFork: (String) -> Void
    var onToggleBranch: ((String) -> Void)?
    var onSwitchToSession: ((String, String) -> Void)?  // (sessionId, sessionTitle)
    var isLoading: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Fork context header (if this is a forked session)
            if let context = forkContext {
                ForkContextHeader(context: context)
            }

            // Header with stats
            TreeStatsHeader(
                events: events,
                forkContext: forkContext,
                totalBranchCount: totalBranchCount
            )

            // Tree content
            if isLoading {
                LoadingTreeView()
            } else if events.isEmpty {
                EmptyTreeView()
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical], showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sortedEvents, id: \.id) { event in
                                // Show fork divider before the fork event
                                if let context = forkContext,
                                   event.id == context.forkPointEventId {
                                    ForkDivider()
                                }

                                // Main track node with optional ghost tracks
                                HStack(alignment: .top, spacing: 0) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        TreeNodeRow(
                                            event: event,
                                            isHead: event.id == headEventId,
                                            isSelected: event.id == selectedEventId,
                                            isOnPath: pathToHead.contains(event.id),
                                            isBranchPoint: branchPoints.contains(event.id) || hasSiblingBranches(event.id),
                                            isFromParentSession: forkContext?.parentEventIds.contains(event.id) ?? false,
                                            depth: nodeDepths[event.id] ?? 0,
                                            onSelect: { selectedEventId = event.id },
                                            onFork: { onFork(event.id) }
                                        )

                                        // Branch indicator if this event has sibling branches
                                        if hasSiblingBranches(event.id) {
                                            BranchIndicator(
                                                branchCount: siblingBranches[event.id]?.count ?? 0,
                                                isExpanded: expandedBranchPoints.contains(event.id),
                                                onToggle: { onToggleBranch?(event.id) }
                                            )
                                            .padding(.leading, 28)
                                        }
                                    }
                                    .frame(minWidth: 300, alignment: .leading)

                                    // Ghost tracks for sibling branches (when expanded)
                                    if expandedBranchPoints.contains(event.id),
                                       let branches = siblingBranches[event.id] {
                                        GhostTrackColumn(
                                            branches: branches,
                                            forkPointEventId: event.id,
                                            onSwitchToSession: onSwitchToSession
                                        )
                                        .transition(.asymmetric(
                                            insertion: .opacity.combined(with: .move(edge: .leading)),
                                            removal: .opacity
                                        ))
                                    }
                                }
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

    private func hasSiblingBranches(_ eventId: String) -> Bool {
        guard let branches = siblingBranches[eventId] else { return false }
        return !branches.isEmpty
    }

    private var totalBranchCount: Int {
        siblingBranches.values.reduce(0) { $0 + $1.count }
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
    let context: SessionForkContext

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
    var forkContext: SessionForkContext?
    var totalBranchCount: Int = 0  // Sibling branches from other sessions

    private var localBranchCount: Int {
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

    private var combinedBranchCount: Int {
        localBranchCount + totalBranchCount
    }

    var body: some View {
        HStack(spacing: 16) {
            if let context = forkContext {
                // Show breakdown for forked sessions
                StatBadge(value: currentSessionEventCount, label: "this session", accentColor: .tronPurple)
                StatBadge(value: context.parentEventIds.count, label: "inherited", isSecondary: true, accentColor: .tronPurple)
            } else {
                StatBadge(value: events.count, label: "events", accentColor: .tronPurple)
            }
            if combinedBranchCount > 0 {
                StatBadge(value: combinedBranchCount, label: "branches", accentColor: .tronAmber)
            }
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
    var accentColor: Color = .tronPurple

    var body: some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(isSecondary ? .tronTextMuted : accentColor)
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
    var hasNextSibling: Bool = false  // Whether there's another event at this depth after this one
    let onSelect: () -> Void
    let onFork: () -> Void

    @State private var isExpanded = false

    /// Whether this event has expandable content to show
    private var hasExpandableContent: Bool {
        event.expandedContent != nil || !isHead
    }

    /// Background color based on selection state and parent session
    private var rowBackgroundColor: Color {
        if isSelected {
            return Color.tronPurple.opacity(0.2)
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

    init(event: SessionEvent, isHead: Bool, isSelected: Bool, isOnPath: Bool, isBranchPoint: Bool, isFromParentSession: Bool = false, depth: Int, hasNextSibling: Bool = false, onSelect: @escaping () -> Void, onFork: @escaping () -> Void) {
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
                            .background(Color.tronPurple)
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
                .tint(.tronPurple)
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
                        .foregroundStyle(event.id == headEventId ? .tronPurple : .tronTextSecondary)
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

// MARK: - Branch Indicator

/// Visual indicator for fork points showing branch count and expand/collapse control
struct BranchIndicator: View {
    let branchCount: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                // Branch line visual
                BranchLine()
                    .stroke(Color.tronPurple.opacity(0.6), lineWidth: 2)
                    .frame(width: 16, height: 12)

                // Branch count badge
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text("\(branchCount)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                    Text(branchCount == 1 ? "branch" : "branches")
                        .font(.system(size: 9))
                }
                .foregroundStyle(.tronPurple)

                // Expand/collapse chevron
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.tronPurple.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Shape for branch line connecting to ghost tracks
struct BranchLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Curved line from left center to right bottom
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.midY)
        )
        return path
    }
}

// MARK: - Ghost Track Column

/// Container for sibling branch events (other sessions forked from same point)
struct GhostTrackColumn: View {
    let branches: [SiblingBranchInfo]
    let forkPointEventId: String
    var onSwitchToSession: ((String, String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(branches) { branch in
                VStack(alignment: .leading, spacing: 4) {
                    // Branch header
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                            .foregroundStyle(.tronPurple.opacity(0.6))

                        Text(branch.displayTitle)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronTextMuted)

                        Text("(\(branch.eventCount) events)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tronTextMuted.opacity(0.7))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.tronPurple.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    // Branch events (ghost)
                    if !branch.events.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(branch.events.prefix(5)) { event in
                                GhostEventRow(
                                    event: event,
                                    sessionTitle: branch.displayTitle,
                                    onTap: {
                                        onSwitchToSession?(branch.id, branch.displayTitle)
                                    }
                                )
                            }

                            if branch.events.count > 5 {
                                Text("+ \(branch.events.count - 5) more...")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tronTextMuted.opacity(0.5))
                                    .padding(.leading, 20)
                            }
                        }
                    } else {
                        // Loading indicator
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Loading...")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tronTextMuted.opacity(0.5))
                        }
                        .padding(.leading, 8)
                    }
                }
                .padding(8)
                .background(Color.tronSurface.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.tronPurple.opacity(0.15), lineWidth: 1)
                )
            }
        }
        .padding(.leading, 16)
        .opacity(0.7)  // Ghost effect
    }
}

// MARK: - Ghost Event Row

/// Minimal event display for sibling branches (view-only)
struct GhostEventRow: View {
    let event: SessionEvent
    let sessionTitle: String
    let onTap: () -> Void

    @State private var showingToast = false

    var body: some View {
        Button(action: {
            showingToast = true
            // Auto-dismiss after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showingToast = false
            }
            onTap()
        }) {
            HStack(spacing: 6) {
                // Event icon
                eventIcon
                    .font(.system(size: 9))
                    .foregroundStyle(iconColor.opacity(0.6))
                    .frame(width: 12)

                // Summary (truncated)
                Text(event.summary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(1)

                Spacer()

                // Timestamp
                Text(formattedTime)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tronTextMuted.opacity(0.5))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.tronSurfaceElevated.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if showingToast {
                Text("Switch to \(sessionTitle) to interact")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.tronPurple)
                    .clipShape(Capsule())
                    .offset(y: -24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingToast)
    }

    @ViewBuilder
    private var eventIcon: some View {
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
            Image(systemName: "wrench.and.screwdriver")
        case .toolResult:
            Image(systemName: "checkmark.circle.fill")
        default:
            Image(systemName: "circle.fill")
        }
    }

    private var iconColor: Color {
        switch event.eventType {
        case .sessionStart: return .tronSuccess
        case .sessionFork: return .tronAmber
        case .messageUser: return .tronBlue
        case .messageAssistant: return .tronPurple
        case .toolCall: return .tronCyan
        case .toolResult: return .tronSuccess
        default: return .tronTextMuted
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

// MARK: - Session History Sheet

@available(iOS 26.0, *)
struct SessionHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    let sessionId: String
    let rpcClient: RPCClient
    let eventStoreManager: EventStoreManager

    @StateObject private var viewModel: SessionHistoryViewModel
    @State private var forkEventId: String?

    init(sessionId: String, rpcClient: RPCClient, eventStoreManager: EventStoreManager) {
        self.sessionId = sessionId
        self.rpcClient = rpcClient
        self.eventStoreManager = eventStoreManager
        _viewModel = StateObject(wrappedValue: SessionHistoryViewModel(
            sessionId: sessionId,
            eventStoreManager: eventStoreManager,
            rpcClient: rpcClient
        ))
    }

    var body: some View {
        NavigationStack {
            SessionHistoryView(
                events: viewModel.events,
                headEventId: viewModel.headEventId,
                sessionId: sessionId,
                forkContext: viewModel.forkContext,
                onFork: { eventId in
                    forkEventId = eventId
                },
                isLoading: viewModel.isLoading
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Session History")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tronPurple)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tronPurple)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronPurple)
        .preferredColorScheme(.dark)
        .task {
            await viewModel.loadEvents()
        }
        .sheet(item: Binding(
            get: { forkEventId.map { ForkEventWrapper(eventId: $0) } },
            set: { forkEventId = $0?.eventId }
        )) { wrapper in
            ForkConfirmationSheet(
                eventId: wrapper.eventId,
                event: viewModel.events.first(where: { $0.id == wrapper.eventId }),
                sessionId: sessionId,
                eventStoreManager: eventStoreManager,
                onDismissParent: { dismiss() }
            )
        }
    }
}

/// Wrapper to make eventId identifiable for sheet presentation
private struct ForkEventWrapper: Identifiable {
    let eventId: String
    var id: String { eventId }
}

// MARK: - Fork Confirmation Sheet

@available(iOS 26.0, *)
struct ForkConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let eventId: String
    let event: SessionEvent?
    let sessionId: String
    let eventStoreManager: EventStoreManager
    let onDismissParent: () -> Void

    @State private var isForking = false

    var body: some View {
        VStack(spacing: 24) {
            // Icon
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tronPurple)
                .frame(width: 72, height: 72)
                .background {
                    Circle()
                        .fill(.clear)
                        .glassEffect(.regular.tint(Color.tronPurple.opacity(0.25)), in: Circle())
                }
                .padding(.top, 20)

            // Title and description
            VStack(spacing: 8) {
                Text("Fork Session")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)

                Text("Create a new branch from this point")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)

                // Show the fork point summary
                if let event = event {
                    HStack(spacing: 6) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 10))
                            .foregroundStyle(.tronPurple.opacity(0.5))

                        Text(event.summary)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(2)

                        Image(systemName: "quote.closing")
                            .font(.system(size: 10))
                            .foregroundStyle(.tronPurple.opacity(0.5))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.tronPurple.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 8)
                }
            }

            Spacer()

            // Buttons
            VStack(spacing: 12) {
                Button {
                    Task {
                        await performFork()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isForking {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 12))
                        }
                        Text("Fork Session")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.clear)
                            .glassEffect(.regular.tint(Color.tronPurple.opacity(0.6)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .buttonStyle(.plain)
                .disabled(isForking)

                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.tronTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .disabled(isForking)
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .presentationDetents([.height(340)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func performFork() async {
        isForking = true
        logger.debug("Fork initiated: sessionId=\(sessionId), fromEventId=\(eventId)", category: .session)
        if let event = event {
            logger.debug("Fork point: type=\(event.type), sequence=\(event.sequence)", category: .session)
        }

        do {
            let newSessionId = try await eventStoreManager.forkSession(sessionId, fromEventId: eventId)
            logger.debug("Fork succeeded: newSessionId=\(newSessionId)", category: .session)
            eventStoreManager.setActiveSession(newSessionId)
            dismiss()
            onDismissParent()
        } catch {
            logger.error("Fork FAILED: \(error)", category: .session)
            isForking = false
        }
    }
}

