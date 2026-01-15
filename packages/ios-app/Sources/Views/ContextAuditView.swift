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

    // Optimistic deletion state - items being deleted animate out immediately
    @State private var pendingSkillDeletions: Set<String> = []
    @State private var pendingMessageDeletions: Set<String> = []

    // Cached token usage to avoid recomputation on every body evaluation
    @State private var cachedTokenUsage: (input: Int, output: Int, cacheRead: Int, cacheCreation: Int) = (0, 0, 0, 0)

    // Message pagination state
    @State private var messagesLoadedCount: Int = 20  // Initial batch size

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

    /// Paginated messages - only show the first N messages for performance
    private var paginatedMessages: [DetailedMessageInfo] {
        Array(displayedMessages.prefix(messagesLoadedCount))
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
                    // Clear button with confirmation menu
                    Menu {
                        Text("Remove all messages from context.\nSystem prompt and tools preserved.")
                            .font(.caption)
                        Button("Clear Context", role: .destructive) {
                            Task { await clearContext() }
                        }
                        Button("Cancel", role: .cancel) { }
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
                }
                ToolbarItem(placement: .principal) {
                    Text("Context")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Compact button with confirmation menu
                    Menu {
                        Text("Summarize older messages\nto free up context space.")
                            .font(.caption)
                        Button("Compact Context") {
                            Task { await compactContext() }
                        }
                        Button("Cancel", role: .cancel) { }
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
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
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

                        // System header (non-expandable)
                        SystemHeader()
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
                        }
                        .padding(.horizontal)

                        // Added Skills section (explicitly added via @skillname or skill sheet, deletable)
                        // These are skills the user explicitly added to the conversation context
                        // Uses displayedSkills for optimistic deletion animations
                        AddedSkillsSection(
                            skills: displayedSkills,
                            onDelete: { skillName in
                                Task { await removeSkillFromContext(skillName: skillName) }
                            },
                            onFetchContent: { skillName in
                                // Fetch full SKILL.md content from server
                                guard let store = skillStore else { return nil }
                                let metadata = await store.getSkill(name: skillName, sessionId: sessionId)
                                return metadata?.content
                            }
                        )
                        .padding(.horizontal)

                        // Messages breakdown (granular expandable) - using server data
                        // Uses paginatedMessages for optimistic deletion animations + pagination
                        DetailedMessagesSection(
                            messages: paginatedMessages,
                            totalMessages: displayedMessages.count,
                            hasMoreMessages: hasMoreMessages,
                            onLoadMore: {
                                messagesLoadedCount += 20  // Load 20 more at a time
                            },
                            onDelete: { eventId in
                                Task { await deleteMessage(eventId: eventId) }
                            }
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
            messagesLoadedCount = 20
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
        isCompacting = true

        do {
            _ = try await rpcClient.compactContext(sessionId: sessionId)
            // Reload context to show updated state
            await loadContext()
        } catch {
            errorMessage = "Failed to compact context: \(error.localizedDescription)"
        }

        isCompacting = false
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

// MARK: - System Header

@available(iOS 26.0, *)
struct SystemHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 12))
                .foregroundStyle(.tronGray)
            Text("System")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        .foregroundStyle(.red)
                }
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

// MARK: - Added Skills Section (explicitly added skills with full content, deletable)

@available(iOS 26.0, *)
struct AddedSkillsSection: View {
    let skills: [AddedSkillInfo]
    var onDelete: ((String) -> Void)?
    var onFetchContent: ((String) async -> String?)?

    var body: some View {
        // Only show if there are added skills
        if !skills.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                // Section header
                HStack {
                    Text("Added Skills (\(skills.count))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))

                    Spacer()

                    Text("tap to expand")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }

                // Skills list (lazy for performance with many skills)
                LazyVStack(spacing: 4) {
                    ForEach(skills) { skill in
                        AddedSkillRow(
                            skill: skill,
                            onDelete: { onDelete?(skill.name) },
                            onFetchContent: onFetchContent
                        )
                    }
                }
            }
        }
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

// MARK: - Detailed Messages Section (using server data)

@available(iOS 26.0, *)
struct DetailedMessagesSection: View {
    let messages: [DetailedMessageInfo]
    let totalMessages: Int
    let hasMoreMessages: Bool
    var onLoadMore: (() -> Void)?
    var onDelete: ((String) -> Void)?

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header with total count
            HStack {
                Text("Messages")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                Text("(\(messages.count)/\(totalMessages))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))

                Spacer()

                if hasMoreMessages {
                    Text("\(totalMessages - messages.count) more")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }

            if totalMessages == 0 {
                HStack {
                    Spacer()
                    Text("No messages in context")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                }
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            } else {
                // Lazy for performance with many messages
                // Uses message.id (from Identifiable) for stable identity during updates
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
                                    Text("Load \(min(20, totalMessages - messages.count)) more messages")
                                        .font(.system(size: 11, design: .monospaced))
                                }
                                .foregroundStyle(.tronCyan)
                                Spacer()
                            }
                            .padding(12)
                            .background {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.tronCyan.opacity(0.1))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
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
            }
        }
        // Removed duplicate .animation() - withAnimation in button action handles this
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
