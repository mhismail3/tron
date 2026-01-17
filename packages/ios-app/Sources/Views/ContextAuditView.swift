import SwiftUI

// MARK: - Context Audit View

@available(iOS 26.0, *)
struct ContextAuditView: View {
    let rpcClient: RPCClient
    let sessionId: String
    var skillStore: SkillStore?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var eventStoreManager: EventStoreManager
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var detailedSnapshot: DetailedContextSnapshotResult?
    @State private var sessionEvents: [SessionEvent] = []
    @State private var isClearing = false
    @State private var isCompacting = false
    @State private var showClearPopover = false
    @State private var showCompactPopover = false

    // Optimistic deletion state - items being deleted animate out immediately
    @State private var pendingSkillDeletions: Set<String> = []
    @State private var pendingMessageDeletions: Set<String> = []

    // Cached token usage to avoid recomputation on every body evaluation
    @State private var cachedTokenUsage: (input: Int, output: Int, cacheRead: Int, cacheCreation: Int) = (0, 0, 0, 0)

    // Message pagination state
    @State private var messagesLoadedCount: Int = 10  // Initial batch size

    /// Whether there are messages in context that can be cleared/compacted
    private var hasMessages: Bool {
        guard let snapshot = detailedSnapshot else { return false }
        return !snapshot.messages.isEmpty
    }

    /// Skills filtered to exclude those being deleted (for optimistic UI)
    private var displayedSkills: [AddedSkillInfo] {
        guard let snapshot = detailedSnapshot else { return [] }
        return snapshot.addedSkills.filter { !pendingSkillDeletions.contains($0.name) }
    }

    /// Messages filtered to exclude those being deleted (for optimistic UI)
    private var displayedMessages: [DetailedMessageInfo] {
        guard let snapshot = detailedSnapshot else { return [] }
        return snapshot.messages.filter { message in
            guard let eventId = message.eventId else { return true }
            return !pendingMessageDeletions.contains(eventId)
        }
    }

    /// Paginated messages - show latest messages first (reverse chronological)
    private var paginatedMessages: [DetailedMessageInfo] {
        let reversed = displayedMessages.reversed()
        return Array(reversed.prefix(messagesLoadedCount))
    }

    /// Whether there are more messages to load
    private var hasMoreMessages: Bool {
        messagesLoadedCount < displayedMessages.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if isLoading {
                    ProgressView()
                        .tint(.tronEmerald)
                } else {
                    contentView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showClearPopover = true
                    } label: {
                        HStack(spacing: 4) {
                            if isClearing {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(.tronError)
                            } else {
                                Image(systemName: "trash")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            Text("Clear")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(hasMessages ? .tronError : .tronTextMuted)
                    }
                    .disabled(isClearing || !hasMessages)
                    .popover(isPresented: $showClearPopover, arrowEdge: .top) {
                        GlassActionSheet(
                            actions: [
                                GlassAction(
                                    title: "Clear Context",
                                    icon: "trash",
                                    color: .tronError,
                                    role: .destructive
                                ) {
                                    showClearPopover = false
                                    Task { await clearContext() }
                                },
                                GlassAction(
                                    title: "Cancel",
                                    icon: nil,
                                    color: .tronTextMuted,
                                    role: .cancel
                                ) {
                                    showClearPopover = false
                                }
                            ]
                        )
                        .presentationCompactAdaptation(.popover)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Context")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCompactPopover = true
                    } label: {
                        HStack(spacing: 4) {
                            if isCompacting {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(.tronSlate)
                            } else {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            Text("Compact")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(hasMessages ? .tronSlate : .tronTextMuted)
                    }
                    .disabled(isCompacting || !hasMessages)
                    .popover(isPresented: $showCompactPopover, arrowEdge: .top) {
                        GlassActionSheet(
                            actions: [
                                GlassAction(
                                    title: "Compact Context",
                                    icon: "arrow.down.right.and.arrow.up.left",
                                    color: Color(red: 0.55, green: 0.7, blue: 0.8),
                                    role: .default
                                ) {
                                    showCompactPopover = false
                                    Task { await compactContext() }
                                },
                                GlassAction(
                                    title: "Cancel",
                                    icon: nil,
                                    color: .tronTextMuted,
                                    role: .cancel
                                ) {
                                    showCompactPopover = false
                                }
                            ]
                        )
                        .presentationCompactAdaptation(.popover)
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                await loadContext()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        .preferredColorScheme(.dark)
    }

    /// Get session token usage from cached values (populated during loadContext)
    private var sessionTokenUsage: (input: Int, output: Int, cacheRead: Int, cacheCreation: Int) {
        cachedTokenUsage
    }

    /// Calculate and cache token usage (called during data loading)
    /// Now uses session-level totals directly instead of iterating through events
    private func updateCachedTokenUsage() {
        guard let session = eventStoreManager.sessions.first(where: { $0.id == sessionId }) else {
            cachedTokenUsage = (0, 0, 0, 0)
            return
        }
        cachedTokenUsage = (session.inputTokens, session.outputTokens, session.cacheReadTokens, session.cacheCreationTokens)
    }

    private var contentView: some View {
        contextView
    }

    // MARK: - Context View

    private var contextView: some View {
        Group {
            if let snapshot = detailedSnapshot {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 16) {
                        // Usage gauge
                        ContextUsageGaugeView(
                            currentTokens: snapshot.currentTokens,
                            contextLimit: snapshot.contextLimit,
                            usagePercent: snapshot.usagePercent,
                            thresholdLevel: snapshot.thresholdLevel
                        )
                        .padding(.horizontal)

                        // Accumulated session tokens
                        TotalSessionTokensView(
                            inputTokens: sessionTokenUsage.input,
                            outputTokens: sessionTokenUsage.output,
                            cacheReadTokens: sessionTokenUsage.cacheRead,
                            cacheCreationTokens: sessionTokenUsage.cacheCreation
                        )
                        .padding(.horizontal)

                        // Token Breakdown header and expandable sections
                        TokenBreakdownHeader()
                            .padding(.horizontal)

                        // System section containers with tighter spacing
                        VStack(spacing: 10) {
                            // System Prompt (standalone container)
                            SystemPromptSection(
                                tokens: snapshot.breakdown.systemPrompt,
                                content: snapshot.systemPromptContent
                            )

                            // Tools (standalone container with badge - clay/ochre)
                            ToolsSection(
                                toolsContent: snapshot.toolsContent,
                                tokens: snapshot.breakdown.tools
                            )

                            // Rules section (immutable, terracotta - right after Tools)
                            if let rules = snapshot.rules, rules.totalFiles > 0 {
                                RulesSection(
                                    rules: rules,
                                    onFetchContent: { path in
                                        // Fetch rule content from server
                                        try await rpcClient.readFile(path: path)
                                    }
                                )
                            }

                            // Skill References (standalone container with badge and token count)
                            if let skills = skillStore?.skills, !skills.isEmpty {
                                SkillReferencesSection(skills: skills)
                            }

                            // Added Skills section (explicitly added via @skillname or skill sheet, deletable)
                            if !displayedSkills.isEmpty {
                                AddedSkillsContainer(
                                    skills: displayedSkills,
                                    onDelete: { skillName in
                                        Task { await removeSkillFromContext(skillName: skillName) }
                                    },
                                    onFetchContent: { skillName in
                                        guard let store = skillStore else { return nil }
                                        let metadata = await store.getSkill(name: skillName, sessionId: sessionId)
                                        return metadata?.content
                                    }
                                )
                            }

                            // Messages (collapsible container with count badge and token total)
                            MessagesContainer(
                                messages: paginatedMessages,
                                totalMessages: displayedMessages.count,
                                totalTokens: snapshot.breakdown.messages,
                                hasMoreMessages: hasMoreMessages,
                                onLoadMore: {
                                    messagesLoadedCount += 10  // Load 10 at a time
                                },
                                onDelete: { eventId in
                                    Task { await deleteMessage(eventId: eventId) }
                                }
                            )
                        }
                        .padding(.horizontal)

                        // Analytics Section
                        AnalyticsSection(
                            sessionId: sessionId,
                            events: sessionEvents
                        )
                        .padding(.horizontal)
                    }
                    .padding(.vertical)
                }
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.cyan)

                    Text("Loading context...")
                        .font(.caption)
                        .foregroundStyle(.tronTextMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Data Loading

    private func loadContext() async {
        isLoading = true

        do {
            // Load detailed context snapshot and events in parallel
            async let snapshotTask = rpcClient.getDetailedContextSnapshot(sessionId: sessionId)
            let events = try eventStoreManager.getSessionEvents(sessionId)

            detailedSnapshot = try await snapshotTask
            sessionEvents = events
            updateCachedTokenUsage()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Background reload that doesn't show loading state (used after optimistic updates)
    private func reloadContextInBackground() async {
        do {
            async let snapshotTask = rpcClient.getDetailedContextSnapshot(sessionId: sessionId)
            let events = try eventStoreManager.getSessionEvents(sessionId)

            detailedSnapshot = try await snapshotTask
            sessionEvents = events
            updateCachedTokenUsage()

            // Clear any pending deletions since we now have fresh data
            pendingSkillDeletions.removeAll()
            pendingMessageDeletions.removeAll()

            // Reset message pagination when reloading
            messagesLoadedCount = 10
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearContext() async {
        isClearing = true

        do {
            _ = try await rpcClient.clearContext(sessionId: sessionId)
            // Reload context to show updated state
            await loadContext()
        } catch {
            errorMessage = "Failed to clear context: \(error.localizedDescription)"
        }

        isClearing = false
    }

    private func compactContext() async {
        logger.info("🔧 compactContext() called for session: \(sessionId)", category: .general)
        isCompacting = true

        do {
            logger.info("🔧 Calling rpcClient.compactContext...", category: .general)
            let result = try await rpcClient.compactContext(sessionId: sessionId)
            logger.info("🔧 Compaction succeeded: tokensBefore=\(result.tokensBefore), tokensAfter=\(result.tokensAfter)", category: .general)
            // Dismiss the sheet - the ChatView will show the compaction notification pill
            // when it receives the agent.compaction event from the server
            dismiss()
        } catch {
            logger.error("🔧 Compaction failed: \(error)", category: .general)
            errorMessage = "Failed to compact context: \(error.localizedDescription)"
            isCompacting = false
        }
    }

    private func deleteMessage(eventId: String) async {
        // Optimistic update: immediately hide the message with animation
        _ = withAnimation(.tronStandard) {
            pendingMessageDeletions.insert(eventId)
        }

        do {
            _ = try await rpcClient.deleteMessage(sessionId, targetEventId: eventId)
            // Background reload to sync state (doesn't show loading)
            await reloadContextInBackground()
        } catch {
            // Rollback: show the message again if deletion failed
            _ = withAnimation(.tronStandard) {
                pendingMessageDeletions.remove(eventId)
            }
            errorMessage = "Failed to delete message: \(error.localizedDescription)"
        }
    }

    private func removeSkillFromContext(skillName: String) async {
        // Optimistic update: immediately hide the skill with animation
        _ = withAnimation(.tronStandard) {
            pendingSkillDeletions.insert(skillName)
        }

        do {
            let result = try await rpcClient.removeSkill(sessionId: sessionId, skillName: skillName)
            if result.success {
                // Background reload to sync state (doesn't show loading)
                await reloadContextInBackground()
            } else {
                // Rollback: show the skill again if removal failed
                _ = withAnimation(.tronStandard) {
                    pendingSkillDeletions.remove(skillName)
                }
                errorMessage = result.error ?? "Failed to remove skill"
            }
        } catch {
            // Rollback: show the skill again if removal failed
            _ = withAnimation(.tronStandard) {
                pendingSkillDeletions.remove(skillName)
            }
            errorMessage = "Failed to remove skill: \(error.localizedDescription)"
        }
    }
}

// MARK: - Total Session Tokens View

@available(iOS 26.0, *)
struct TotalSessionTokensView: View {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int

    private var totalTokens: Int {
        inputTokens + outputTokens
    }

    /// Whether any cache tokens exist (hides cache section if none)
    private var hasCacheTokens: Bool {
        cacheReadTokens > 0 || cacheCreationTokens > 0
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header with explanatory subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text("Session Totals")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Accumulated tokens across all turns (for billing)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }

            // Main content card
            VStack(spacing: 12) {
                // Header with total
                HStack {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14))
                        .foregroundStyle(.tronAmberLight)

                    Text("Accumulated")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronAmberLight)

                    Spacer()

                    Text(formatTokenCount(totalTokens))
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tronAmberLight)
                }

                // Token breakdown row
                HStack(spacing: 8) {
                    // Input tokens
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tronOrange)
                            Text("Input")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Text(formatTokenCount(inputTokens))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronOrange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.clear)
                            .glassEffect(.regular.tint(Color.tronOrange.opacity(0.3)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    // Output tokens
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tronRed)
                            Text("Output")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Text(formatTokenCount(outputTokens))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronRed)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.clear)
                            .glassEffect(.regular.tint(Color.tronRed.opacity(0.3)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                // Cache tokens row (only shown if cache tokens exist)
                if hasCacheTokens {
                    HStack(spacing: 8) {
                        // Cache read tokens
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tronAmber)
                                Text("Cache Read")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            Text(formatTokenCount(cacheReadTokens))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tronAmber)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.clear)
                                .glassEffect(.regular.tint(Color.tronAmber.opacity(0.3)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        // Cache creation tokens
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "memorychip.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tronAmberLight)
                                Text("Cache Write")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            Text(formatTokenCount(cacheCreationTokens))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tronAmberLight)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.clear)
                                .glassEffect(.regular.tint(Color.tronAmberLight.opacity(0.3)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }

                // Footer explanation
                Text("Input grows each turn • Output sums all responses")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronBronze.opacity(0.2)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

// MARK: - Context Usage Gauge View

@available(iOS 26.0, *)
struct ContextUsageGaugeView: View {
    let currentTokens: Int
    let contextLimit: Int
    let usagePercent: Double
    let thresholdLevel: String

    private var usageColor: Color {
        switch thresholdLevel {
        case "critical", "exceeded":
            return .tronError
        case "alert":
            return .tronAmber
        case "warning":
            return .tronWarning
        default:
            return .tronCyan
        }
    }

    private var formattedTokens: String {
        formatTokenCount(currentTokens)
    }

    private var formattedLimit: String {
        formatTokenCount(contextLimit)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header with explanatory subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text("Context Window")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Text("What's being sent to the model this turn")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }

            // Main content card
            VStack(spacing: 12) {
                // Header
                HStack {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 14))
                        .foregroundStyle(usageColor)

                    Text("Current Size")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronSlate)

                    Spacer()

                    Text("\(Int(usagePercent * 100))%")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(usageColor)
                }

                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.1))

                        // Fill
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(usageColor.opacity(0.8))
                            .frame(width: geometry.size.width * min(usagePercent, 1.0))
                    }
                }
                .frame(height: 10)

                // Token counts
                HStack {
                    Text("\(formattedTokens) / \(formattedLimit)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))

                    Spacer()

                    Text("\(formatTokenCount(contextLimit - currentTokens)) remaining")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronSlateDark.opacity(0.5)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

// MARK: - Token Breakdown Header

@available(iOS 26.0, *)
struct TokenBreakdownHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Window Breakdown")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
            Text("Components that make up the Context Window above")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

// MARK: - System Prompt Section (standalone container)

@available(iOS 26.0, *)
struct SystemPromptSection: View {
    let tokens: Int
    let content: String
    @State private var isExpanded = false

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tronPurple)
                Text("System Prompt")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronPurple)
                Spacer()
                Text(formatTokens(tokens))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Content
            if isExpanded {
                ScrollView {
                    Text(content)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 300)
                .background(Color.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.tronPurple.opacity(0.15))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Tools Section (standalone container with badge - clay/ochre)

@available(iOS 26.0, *)
struct ToolsSection: View {
    let toolsContent: [String]
    let tokens: Int
    @State private var isExpanded = false

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header - using onTapGesture to avoid any button highlight behavior
            HStack {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tronClay)
                Text("Tools")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronClay)

                // Count badge
                Text("\(toolsContent.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.tronClay.opacity(0.7))
                    .clipShape(Capsule())

                Spacer()
                Text(formatTokens(tokens))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Content
            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(toolsContent.enumerated()), id: \.offset) { index, tool in
                            ToolItemView(tool: tool)
                            if index < toolsContent.count - 1 {
                                Divider()
                                    .background(Color.white.opacity(0.1))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 300)
                .background(Color.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.tronClay.opacity(0.15))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Tool Item View

@available(iOS 26.0, *)
struct ToolItemView: View {
    let tool: String

    private var toolName: String {
        if let colonIndex = tool.firstIndex(of: ":") {
            return String(tool[..<colonIndex])
        }
        return tool
    }

    private var toolDescription: String {
        if let colonIndex = tool.firstIndex(of: ":") {
            let afterColon = tool.index(after: colonIndex)
            return String(tool[afterColon...]).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(toolName)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tronClay)
            if !toolDescription.isEmpty {
                Text(toolDescription)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - Expandable Content Section

@available(iOS 26.0, *)
struct ExpandableContentSection: View {
    let icon: String
    let iconColor: Color
    let title: String
    let tokens: Int
    let content: String
    @Binding var isExpanded: Bool

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(iconColor.opacity(0.8))
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(formatTokens(tokens))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Content
            if isExpanded {
                ScrollView {
                    Text(content)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 300)
                .background(Color.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(iconColor.opacity(0.15))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Skill References Section (standalone container, frontmatter only, not removable)

@available(iOS 26.0, *)
struct SkillReferencesSection: View {
    let skills: [Skill]
    @State private var isExpanded = false

    /// Estimated tokens for all skill frontmatter (description + metadata)
    /// Rough estimate: ~50 tokens per skill on average for frontmatter
    private var estimatedTokens: Int {
        skills.reduce(0) { total, skill in
            // Estimate based on description length + metadata overhead
            let descriptionTokens = skill.description.count / 4  // ~4 chars per token
            let metadataTokens = 20  // name, tags, source, etc.
            return total + descriptionTokens + metadataTokens
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(.tronCyan)
                Text("Skill References")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronCyan)

                // Count badge
                Text("\(skills.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.tronCyan.opacity(0.6))
                    .clipShape(Capsule())

                Spacer()

                // Token count
                Text(formatTokens(estimatedTokens))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Content - list of skill references (frontmatter only, lazy for performance)
            if isExpanded {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(skills) { skill in
                        SkillReferenceRow(skill: skill)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.tronCyan.opacity(0.15))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Skill Reference Row (lightweight, no delete option)

@available(iOS 26.0, *)
struct SkillReferenceRow: View {
    let skill: Skill

    @State private var isExpanded = false

    private var sourceIcon: String {
        skill.source == .project ? "folder.fill" : "globe"
    }

    private var sourceColor: Color {
        skill.source == .project ? .tronEmerald : .tronPurple
    }

    private var autoInjectBadge: String? {
        skill.autoInject ? "auto" : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 8) {
                Image(systemName: sourceIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(sourceColor)

                Text("@\(skill.name)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronCyan)

                Spacer()

                // Auto-inject badge if applicable
                if let badge = autoInjectBadge {
                    Text(badge)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronAmber)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background {
                            Capsule()
                                .fill(Color.tronAmber.opacity(0.2))
                        }
                }

                // Tags if any
                if let tags = skill.tags, !tags.isEmpty {
                    Text(tags.prefix(2).joined(separator: ", "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Expanded description (just description, not full content)
            if isExpanded {
                Text(skill.description)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                                }
        }
        .background {
            // Lightweight fill instead of glassEffect for better animation performance
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(sourceColor.opacity(0.12))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        // No context menu - skill references are not removable
    }
}

// MARK: - Added Skill Row (shows full SKILL.md content, deletable)

@available(iOS 26.0, *)
struct AddedSkillRow: View {
    let skill: AddedSkillInfo
    var onDelete: (() -> Void)?
    var onFetchContent: ((String) async -> String?)?

    @State private var isExpanded = false
    @State private var fullContent: String?
    @State private var isLoadingContent = false

    private var sourceIcon: String {
        skill.source == .project ? "folder.fill" : "globe"
    }

    private var sourceColor: Color {
        skill.source == .project ? .tronEmerald : .tronCyan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 8) {
                Image(systemName: sourceIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(.tronCyan)

                Text("@\(skill.name)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronCyan)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
                // Fetch content on first expand
                if isExpanded && fullContent == nil && !isLoadingContent {
                    Task {
                        await fetchContent()
                    }
                }
            }

            // Expanded full content (scrollable SKILL.md)
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Full SKILL.md content
                    if isLoadingContent {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(.tronCyan)
                            Text("Loading content...")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                    } else if let content = fullContent {
                        ScrollView {
                            Text(content)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 300)
                        .background(Color.black.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(.horizontal, 8)
                    } else {
                        Text("Content not available")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(8)
                    }
                }
                .padding(.bottom, 8)
                            }
        }
        .background {
            // Teal tint for added skills container (matches skill references)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.tronCyan.opacity(0.12))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contextMenu {
            if onDelete != nil {
                Button(role: .destructive) {
                    onDelete?()
                } label: {
                    Label("Remove from Context", systemImage: "trash")
                }
                .tint(.red)
            }
        }
    }

    private func fetchContent() async {
        isLoadingContent = true
        if let fetch = onFetchContent {
            fullContent = await fetch(skill.name)
        }
        isLoadingContent = false
    }
}

// MARK: - Rules Section (immutable, cannot be removed)

@available(iOS 26.0, *)
struct RulesSection: View {
    let rules: LoadedRules
    var onFetchContent: ((String) async throws -> String)?
    @State private var isExpanded = false

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row (tappable)
            HStack {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tronTerracotta)

                Text("Rules")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronTerracotta)

                // Count badge
                Text("\(rules.totalFiles)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.tronTerracotta.opacity(0.7))
                    .clipShape(Capsule())

                Spacer()

                Text(formatTokens(rules.tokens))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Expandable content
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rules.files) { file in
                        RulesFileRow(
                            file: file,
                            onFetchContent: onFetchContent
                        )
                    }
                }
                .padding(10)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.tronTerracotta.opacity(0.15))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Rules File Row (expandable to view content)

@available(iOS 26.0, *)
struct RulesFileRow: View {
    let file: RulesFile
    var content: String?
    var onFetchContent: ((String) async throws -> String)?

    @State private var isExpanded = false
    @State private var loadedContent: String?
    @State private var isLoadingContent = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row (tappable)
            HStack(spacing: 10) {
                Image(systemName: file.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.tronTerracotta.opacity(0.8))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.displayPath)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)

                    Text(file.label)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
                // Fetch content on first expand if not already loaded
                if isExpanded && loadedContent == nil && !isLoadingContent {
                    Task {
                        await fetchContent()
                    }
                }
            }

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if isLoadingContent {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(.tronTerracotta)
                            Text("Loading content...")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                    } else if let error = loadError {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tronError)
                                Text("Failed to load content")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.tronError)
                            }
                            Text(error)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                            Text("Path: \(file.path)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                                .lineLimit(2)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.tronError.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else if let displayContent = loadedContent ?? content {
                        ScrollView {
                            Text(displayContent)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 300)
                        .background(Color.black.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Text("Content not available")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(8)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.tronTerracotta.opacity(0.08))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // NO context menu - rules cannot be deleted
    }

    private func fetchContent() async {
        isLoadingContent = true
        loadError = nil
        if let fetch = onFetchContent {
            do {
                loadedContent = try await fetch(file.path)
            } catch {
                loadError = error.localizedDescription
            }
        }
        isLoadingContent = false
    }
}

// MARK: - Detailed Message Row

@available(iOS 26.0, *)
struct DetailedMessageRow: View {
    let message: DetailedMessageInfo
    let isLast: Bool
    var onDelete: (() -> Void)?

    @State private var isExpanded = false

    private var icon: String {
        switch message.role {
        case "user": return "person.fill"
        case "assistant": return "sparkles"
        case "toolResult": return message.isError == true ? "xmark.circle.fill" : "checkmark.circle.fill"
        default: return "questionmark.circle"
        }
    }

    private var iconColor: Color {
        switch message.role {
        case "user": return .tronBlue
        case "assistant": return .tronEmerald
        case "toolResult": return message.isError == true ? .tronError : .tronCyan
        default: return .gray
        }
    }

    private var title: String {
        switch message.role {
        case "user": return "User"
        case "assistant":
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                let names = toolCalls.prefix(2).map { $0.name }
                let suffix = toolCalls.count > 2 ? " +\(toolCalls.count - 2)" : ""
                return names.joined(separator: ", ") + suffix
            }
            return "Assistant"
        case "toolResult": return message.isError == true ? "Error" : "Result"
        default: return "Message"
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row (tappable)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(iconColor)
                    .frame(width: 18)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(iconColor)

                    // Summary fades out when expanded
                    Text(message.summary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .opacity(isExpanded ? 0 : 1)
                        .frame(height: isExpanded ? 0 : nil, alignment: .top)
                        .clipped()
                }

                Spacer()

                Text(formatTokens(message.tokens))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 2)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Expandable content
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Show tool calls if present
                    if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                        ForEach(toolCalls) { toolCall in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "hammer.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tronAmber)
                                    Text(toolCall.name)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.tronAmber)
                                    Spacer()
                                    Text(formatTokens(toolCall.tokens))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.4))
                                }

                                Text(toolCall.arguments)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(5)
                            }
                            .padding(8)
                            .background {
                                // Lightweight fill instead of glassEffect
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.tronAmber.opacity(0.15))
                            }
                        }
                    }

                    // Show text content if present
                    if !message.content.isEmpty {
                        ScrollView {
                            Text(message.content)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 200)
                        .background(Color.black.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                            }
        }
        .background {
            // Lightweight fill instead of glassEffect for better animation performance
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(iconColor.opacity(0.15))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            // Only show delete option if eventId is available (deletable)
            if onDelete != nil {
                Button(role: .destructive) {
                    onDelete?()
                } label: {
                    Label("Delete from Context", systemImage: "trash")
                }
                .tint(.red)
            }
        }
        // Removed duplicate .animation() - withAnimation in button action handles this
    }
}

// MARK: - Messages Container (Collapsible, matching Rules/Skills pattern)

@available(iOS 26.0, *)
struct MessagesContainer: View {
    let messages: [DetailedMessageInfo]
    let totalMessages: Int
    let totalTokens: Int
    let hasMoreMessages: Bool
    var onLoadMore: (() -> Void)?
    var onDelete: ((String) -> Void)?

    @State private var isExpanded = false

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row (tappable)
            HStack {
                Image(systemName: "message.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tronBlue)

                Text("Messages")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronBlue)

                // Count badge
                Text("\(totalMessages)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.tronBlue.opacity(0.7))
                    .clipShape(Capsule())

                Spacer()

                Text(formatTokens(totalTokens))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Expandable content
            if isExpanded {
                VStack(spacing: 4) {
                    if totalMessages == 0 {
                        Text("No messages in context")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .padding(12)
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(messages) { message in
                                DetailedMessageRow(
                                    message: message,
                                    isLast: message.index == messages.last?.index,
                                    onDelete: message.eventId != nil ? { onDelete?(message.eventId!) } : nil
                                )
                            }

                            // Load more button
                            if hasMoreMessages {
                                Button {
                                    onLoadMore?()
                                } label: {
                                    HStack {
                                        Spacer()
                                        HStack(spacing: 6) {
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 11, weight: .medium))
                                            Text("Load \(min(10, totalMessages - messages.count)) more")
                                                .font(.system(size: 11, design: .monospaced))
                                        }
                                        .foregroundStyle(.tronBlue)
                                        Spacer()
                                    }
                                    .padding(10)
                                    .background {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.tronBlue.opacity(0.1))
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.tronBlue.opacity(0.15))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Added Skills Container (Collapsible, matching Rules/Skills pattern)

@available(iOS 26.0, *)
struct AddedSkillsContainer: View {
    let skills: [AddedSkillInfo]
    var onDelete: ((String) -> Void)?
    var onFetchContent: ((String) async -> String?)?

    @State private var isExpanded = false

    /// Estimated tokens for added skills (full SKILL.md content)
    /// More substantial than skill references since full content is included
    private var estimatedTokens: Int {
        // Rough estimate: ~200 tokens per skill for full SKILL.md
        skills.count * 200
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(.tronCyan)

                Text("Added Skills")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronCyan)

                // Count badge
                Text("\(skills.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.tronCyan.opacity(0.7))
                    .clipShape(Capsule())

                Spacer()

                Text("~\(formatTokens(estimatedTokens))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Content
            if isExpanded {
                LazyVStack(spacing: 4) {
                    ForEach(skills) { skill in
                        AddedSkillRow(
                            skill: skill,
                            onDelete: { onDelete?(skill.name) },
                            onFetchContent: onFetchContent
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.tronCyan.opacity(0.15))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Analytics Section

@available(iOS 26.0, *)
struct AnalyticsSection: View {
    let sessionId: String
    let events: [SessionEvent]

    @State private var showCopied = false

    private var analytics: ConsolidatedAnalytics {
        ConsolidatedAnalytics(from: events)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            VStack(alignment: .leading, spacing: 2) {
                Text("Analytics")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Session performance and cost breakdown")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }

            // Session ID (tappable to copy)
            SessionIdRow(sessionId: sessionId)

            // Cost Summary
            CostSummaryCard(analytics: analytics)

            // Turn Breakdown
            TurnBreakdownContainer(turns: analytics.turns)
        }
        .padding(.top, 8)
    }
}

// MARK: - Session ID Row

@available(iOS 26.0, *)
struct SessionIdRow: View {
    let sessionId: String
    @State private var showCopied = false

    var body: some View {
        HStack {
            Image(systemName: "number.circle")
                .font(.system(size: 12))
                .foregroundStyle(.tronTextMuted)

            Text(showCopied ? "Copied!" : sessionId)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(showCopied ? .tronEmerald : .tronTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .animation(.easeInOut(duration: 0.15), value: showCopied)

            Spacer()

            Image(systemName: "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(.tronTextMuted)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            UIPasteboard.general.string = sessionId
            showCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                showCopied = false
            }
        }
    }
}

// MARK: - Cost Summary Card

@available(iOS 26.0, *)
struct CostSummaryCard: View {
    let analytics: ConsolidatedAnalytics

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.001 { return "$0.00" }
        if cost < 0.01 { return String(format: "$%.3f", cost) }
        return String(format: "$%.2f", cost)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tronAmber)

                Text("Session Cost")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronAmber)

                Spacer()

                Text(formatCost(analytics.totalCost))
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tronAmber)
            }

            // Stats row
            HStack(spacing: 0) {
                CostStatItem(value: "\(analytics.totalTurns)", label: "turns")
                CostStatItem(value: formatLatency(analytics.avgLatency), label: "avg latency")
                CostStatItem(value: "\(analytics.totalToolCalls)", label: "tool calls")
                CostStatItem(value: "\(analytics.totalErrors)", label: "errors", isError: analytics.totalErrors > 0)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.tronAmber.opacity(0.15))
        }
    }

    private func formatLatency(_ ms: Int) -> String {
        if ms == 0 { return "-" }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }
}

@available(iOS 26.0, *)
struct CostStatItem: View {
    let value: String
    let label: String
    var isError: Bool = false

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(isError ? .tronError : .white.opacity(0.8))
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Turn Breakdown Container

@available(iOS 26.0, *)
struct TurnBreakdownContainer: View {
    let turns: [ConsolidatedAnalytics.TurnData]
    @State private var isExpanded = false

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    private var totalTokens: Int {
        turns.reduce(0) { $0 + $1.totalTokens }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "list.number")
                    .font(.system(size: 14))
                    .foregroundStyle(.tronEmerald)

                Text("Turn Breakdown")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronEmerald)

                // Count badge
                Text("\(turns.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.tronEmerald.opacity(0.7))
                    .clipShape(Capsule())

                Spacer()

                Text(formatTokens(totalTokens))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Content
            if isExpanded {
                if turns.isEmpty {
                    Text("No turns recorded")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .padding(12)
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(turns) { turn in
                            TurnRow(turn: turn)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.tronEmerald.opacity(0.15))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Turn Row (Expandable)

@available(iOS 26.0, *)
struct TurnRow: View {
    let turn: ConsolidatedAnalytics.TurnData
    @State private var isExpanded = false

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.001 { return "$0.00" }
        if cost < 0.01 { return String(format: "$%.3f", cost) }
        return String(format: "$%.2f", cost)
    }

    private func formatLatency(_ ms: Int) -> String {
        if ms == 0 { return "-" }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 10) {
                // Turn number badge
                Text("\(turn.turn)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 24, height: 24)
                    .background(Color.tronEmerald.opacity(0.2))
                    .clipShape(Circle())

                // Summary info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        // Tokens
                        HStack(spacing: 3) {
                            Image(systemName: "number")
                                .font(.system(size: 9))
                            Text(formatTokens(turn.totalTokens))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.white.opacity(0.7))

                        // Cost
                        Text(formatCost(turn.cost))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronAmber)

                        // Latency
                        if turn.latency > 0 {
                            Text(formatLatency(turn.latency))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }

                    // Tools and errors indicators
                    HStack(spacing: 8) {
                        if turn.toolCount > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "hammer.fill")
                                    .font(.system(size: 8))
                                Text("\(turn.toolCount)")
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .foregroundStyle(.tronCyan)
                        }

                        if turn.errorCount > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 8))
                                Text("\(turn.errorCount)")
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .foregroundStyle(.tronError)
                        }

                        if let model = turn.model {
                            Text(model)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Expanded details
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Token breakdown
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Input")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                            Text(formatTokens(turn.inputTokens))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tronOrange)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Output")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                            Text(formatTokens(turn.outputTokens))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tronRed)
                        }

                        // Cache tokens (only show if present)
                        if turn.cacheReadTokens > 0 || turn.cacheCreationTokens > 0 {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cache")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.4))
                                HStack(spacing: 4) {
                                    if turn.cacheReadTokens > 0 {
                                        Text("↓\(formatTokens(turn.cacheReadTokens))")
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.tronEmerald)
                                    }
                                    if turn.cacheCreationTokens > 0 {
                                        Text("↑\(formatTokens(turn.cacheCreationTokens))")
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.tronPurple)
                                    }
                                }
                            }
                        }

                        Spacer()
                    }

                    // Tools used
                    if !turn.tools.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tools")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))

                            FlowLayout(spacing: 4) {
                                ForEach(turn.tools, id: \.self) { tool in
                                    Text(tool)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.tronCyan)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.tronCyan.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }

                    // Errors
                    if !turn.errors.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Errors")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))

                            ForEach(turn.errors, id: \.self) { error in
                                Text(error)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tronError)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.tronEmerald.opacity(0.08))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Flow Layout (for tool tags)

@available(iOS 26.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalHeight = currentY + lineHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

// MARK: - Consolidated Analytics Data Model

struct ConsolidatedAnalytics {
    struct TurnData: Identifiable {
        let id = UUID()
        let turn: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreationTokens: Int
        let cost: Double
        let latency: Int
        let toolCount: Int
        let tools: [String]
        let errorCount: Int
        let errors: [String]
        let model: String?

        var totalTokens: Int { inputTokens + outputTokens }
    }

    let turns: [TurnData]
    let totalCost: Double
    let totalTurns: Int
    let totalToolCalls: Int
    let totalErrors: Int
    let avgLatency: Int

    // MARK: - Robust Number Extraction

    /// Extract Int from Any (handles both Int and Double from JSON)
    private static func extractInt(_ value: Any?) -> Int? {
        if let intVal = value as? Int { return intVal }
        if let doubleVal = value as? Double { return Int(doubleVal) }
        if let nsNumber = value as? NSNumber { return nsNumber.intValue }
        return nil
    }

    /// Extract Double from Any (handles both Int and Double from JSON)
    private static func extractDouble(_ value: Any?) -> Double? {
        if let doubleVal = value as? Double { return doubleVal }
        if let intVal = value as? Int { return Double(intVal) }
        if let nsNumber = value as? NSNumber { return nsNumber.doubleValue }
        return nil
    }

    /// Extract token usage from event payload
    private static func extractTokenUsage(from payload: [String: AnyCodable]) -> (input: Int, output: Int, cacheRead: Int, cacheCreation: Int)? {
        guard let tokenUsage = payload["tokenUsage"]?.value as? [String: Any] else { return nil }

        let input = extractInt(tokenUsage["inputTokens"]) ?? 0
        let output = extractInt(tokenUsage["outputTokens"]) ?? 0
        let cacheRead = extractInt(tokenUsage["cacheReadTokens"]) ?? 0
        let cacheCreation = extractInt(tokenUsage["cacheCreationTokens"]) ?? 0

        return (input, output, cacheRead, cacheCreation)
    }

    // MARK: - Cost Calculation

    /// Model pricing per million tokens (USD)
    private struct ModelPricing {
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cacheWriteMultiplier: Double  // Applied to input rate for cache creation
        let cacheReadMultiplier: Double   // Applied to input rate for cache reads (discount)

        static let defaultPricing = ModelPricing(
            inputPerMillion: 3.0,
            outputPerMillion: 15.0,
            cacheWriteMultiplier: 1.25,
            cacheReadMultiplier: 0.1
        )
    }

    /// Get pricing for a model
    private static func getPricing(for model: String?) -> ModelPricing {
        guard let model = model?.lowercased() else { return .defaultPricing }

        // Claude models
        if model.contains("opus") {
            return ModelPricing(inputPerMillion: 15.0, outputPerMillion: 75.0, cacheWriteMultiplier: 1.25, cacheReadMultiplier: 0.1)
        }
        if model.contains("sonnet") {
            return ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheWriteMultiplier: 1.25, cacheReadMultiplier: 0.1)
        }
        if model.contains("haiku") {
            return ModelPricing(inputPerMillion: 0.25, outputPerMillion: 1.25, cacheWriteMultiplier: 1.25, cacheReadMultiplier: 0.1)
        }

        // OpenAI models
        if model.contains("gpt-4o-mini") {
            return ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.60, cacheWriteMultiplier: 1.0, cacheReadMultiplier: 0.5)
        }
        if model.contains("gpt-4o") || model.contains("gpt-4.1") {
            return ModelPricing(inputPerMillion: 2.50, outputPerMillion: 10.0, cacheWriteMultiplier: 1.0, cacheReadMultiplier: 0.5)
        }
        if model.contains("o3") {
            return ModelPricing(inputPerMillion: 10.0, outputPerMillion: 40.0, cacheWriteMultiplier: 1.0, cacheReadMultiplier: 0.5)
        }
        if model.contains("o4-mini") {
            return ModelPricing(inputPerMillion: 1.10, outputPerMillion: 4.40, cacheWriteMultiplier: 1.0, cacheReadMultiplier: 0.5)
        }

        // Gemini models
        if model.contains("gemini-2.5-pro") {
            return ModelPricing(inputPerMillion: 1.25, outputPerMillion: 10.0, cacheWriteMultiplier: 1.0, cacheReadMultiplier: 0.25)
        }
        if model.contains("gemini-2.5-flash") || model.contains("gemini-2.0-flash") {
            return ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.60, cacheWriteMultiplier: 1.0, cacheReadMultiplier: 0.25)
        }

        return .defaultPricing
    }

    /// Calculate cost from token usage
    private static func calculateCost(
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int
    ) -> Double {
        let pricing = getPricing(for: model)

        // Base input tokens (excluding cache tokens which are billed separately)
        let baseInputTokens = max(0, inputTokens - cacheReadTokens - cacheCreationTokens)
        let baseInputCost = (Double(baseInputTokens) / 1_000_000) * pricing.inputPerMillion

        // Cache creation cost (higher rate)
        let cacheCreationCost = (Double(cacheCreationTokens) / 1_000_000) * pricing.inputPerMillion * pricing.cacheWriteMultiplier

        // Cache read cost (discounted rate)
        let cacheReadCost = (Double(cacheReadTokens) / 1_000_000) * pricing.inputPerMillion * pricing.cacheReadMultiplier

        // Output cost
        let outputCost = (Double(outputTokens) / 1_000_000) * pricing.outputPerMillion

        return baseInputCost + cacheCreationCost + cacheReadCost + outputCost
    }

    // MARK: - Initialization

    init(from events: [SessionEvent]) {
        // Track data per turn
        struct TurnAccumulator {
            var input: Int = 0
            var output: Int = 0
            var cacheRead: Int = 0
            var cacheCreation: Int = 0
            var cost: Double? = nil  // nil means we need to calculate it
            var latency: Int = 0
            var tools: [String] = []
            var errors: [String] = []
            var model: String? = nil
        }

        var turnData: [Int: TurnAccumulator] = [:]
        var latencySum = 0
        var latencyCount = 0
        var totalTools = 0
        var totalErrs = 0

        for event in events {
            switch event.eventType {
            case .messageAssistant:
                guard let turn = Self.extractInt(event.payload["turn"]?.value) else { continue }
                var existing = turnData[turn] ?? TurnAccumulator()

                // Token usage
                if let tokens = Self.extractTokenUsage(from: event.payload) {
                    existing.input = max(existing.input, tokens.input)
                    existing.output = max(existing.output, tokens.output)
                    existing.cacheRead = max(existing.cacheRead, tokens.cacheRead)
                    existing.cacheCreation = max(existing.cacheCreation, tokens.cacheCreation)
                }

                // Latency
                if let latency = Self.extractInt(event.payload["latency"]?.value), latency > 0 {
                    existing.latency = max(existing.latency, latency)
                    latencySum += latency
                    latencyCount += 1
                }

                // Model
                if let model = event.payload["model"]?.value as? String {
                    existing.model = model
                }

                turnData[turn] = existing

            case .streamTurnEnd:
                guard let turn = Self.extractInt(event.payload["turn"]?.value) else { continue }
                var existing = turnData[turn] ?? TurnAccumulator()

                // Token usage (primary source for turn end)
                if let tokens = Self.extractTokenUsage(from: event.payload) {
                    // Use turn end tokens if we don't have them yet or if they're larger
                    if existing.input == 0 { existing.input = tokens.input }
                    if existing.output == 0 { existing.output = tokens.output }
                    existing.cacheRead = max(existing.cacheRead, tokens.cacheRead)
                    existing.cacheCreation = max(existing.cacheCreation, tokens.cacheCreation)
                }

                // Cost - this is the authoritative source from server
                if let cost = Self.extractDouble(event.payload["cost"]?.value) {
                    existing.cost = cost
                }

                // Model (if not already set from messageAssistant)
                if existing.model == nil, let model = event.payload["model"]?.value as? String {
                    existing.model = model
                }

                turnData[turn] = existing

            case .toolCall:
                guard let turn = Self.extractInt(event.payload["turn"]?.value),
                      let toolName = event.payload["name"]?.value as? String else { continue }

                var existing = turnData[turn] ?? TurnAccumulator()
                if !existing.tools.contains(toolName) {
                    existing.tools.append(toolName)
                }
                turnData[turn] = existing
                totalTools += 1

            case .errorAgent, .errorProvider, .errorTool:
                let errorMsg = (event.payload["error"]?.value as? String) ?? "Unknown error"
                if let turn = Self.extractInt(event.payload["turn"]?.value) {
                    var existing = turnData[turn] ?? TurnAccumulator()
                    existing.errors.append(errorMsg)
                    turnData[turn] = existing
                }
                totalErrs += 1

            default:
                break
            }
        }

        // Convert to array and calculate missing costs
        self.turns = turnData.sorted { $0.key < $1.key }.map { key, value in
            // Use server cost if available, otherwise calculate locally
            let finalCost = value.cost ?? Self.calculateCost(
                model: value.model,
                inputTokens: value.input,
                outputTokens: value.output,
                cacheReadTokens: value.cacheRead,
                cacheCreationTokens: value.cacheCreation
            )

            return TurnData(
                turn: key,
                inputTokens: value.input,
                outputTokens: value.output,
                cacheReadTokens: value.cacheRead,
                cacheCreationTokens: value.cacheCreation,
                cost: finalCost,
                latency: value.latency,
                toolCount: value.tools.count,
                tools: value.tools,
                errorCount: value.errors.count,
                errors: value.errors,
                model: value.model?.shortModelName
            )
        }

        self.totalCost = self.turns.reduce(0) { $0 + $1.cost }
        self.totalTurns = self.turns.count
        self.totalToolCalls = totalTools
        self.totalErrors = totalErrs
        self.avgLatency = latencyCount > 0 ? latencySum / latencyCount : 0
    }
}

// MARK: - Glass Action Sheet (Custom iOS 26 Liquid Glass Style)

/// Role for glass action buttons
enum GlassActionRole {
    case `default`
    case destructive
    case cancel
}

/// A single action in a glass action sheet
struct GlassAction {
    let title: String
    let icon: String?
    let color: Color
    let role: GlassActionRole
    let action: () -> Void
}

/// Custom action sheet with iOS 26 liquid glass styling
/// Supports custom colors and icons (unlike native confirmationDialog)
@available(iOS 26.0, *)
struct GlassActionSheet: View {
    let actions: [GlassAction]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                Button {
                    action.action()
                } label: {
                    HStack(spacing: 8) {
                        if let icon = action.icon {
                            Image(systemName: icon)
                                .font(.system(size: 14, weight: .medium))
                        }
                        Text(action.title)
                            .font(.system(size: 15, weight: action.role == .cancel ? .regular : .medium))
                    }
                    .foregroundStyle(action.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    .contentShape(Capsule())
                    .background {
                        Capsule()
                            .fill(.clear)
                            .glassEffect(
                                .regular.tint(action.color.opacity(action.role == .cancel ? 0.1 : 0.25)),
                                in: Capsule()
                            )
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(minWidth: 200)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .presentationBackground(.clear)
    }
}

// MARK: - Preview

@available(iOS 26.0, *)
#Preview {
    ContextAuditView(
        rpcClient: RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!),
        sessionId: "test"
    )
}
