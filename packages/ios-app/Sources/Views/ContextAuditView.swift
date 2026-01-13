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
    @State private var cachedTokenUsage: (input: Int, output: Int, cacheRead: Int) = (0, 0, 0)

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
    private var sessionTokenUsage: (input: Int, output: Int, cacheRead: Int) {
        cachedTokenUsage
    }

    /// Calculate and cache token usage (called during data loading)
    private func updateCachedTokenUsage() {
        guard let session = eventStoreManager.sessions.first(where: { $0.id == sessionId }) else {
            cachedTokenUsage = (0, 0, 0)
            return
        }
        let cacheTokens = calculateCacheTokens()
        cachedTokenUsage = (session.inputTokens, session.outputTokens, cacheTokens)
    }

    /// Calculate cache read tokens from session events
    private func calculateCacheTokens() -> Int {
        var total = 0
        for event in sessionEvents {
            if event.eventType == .messageAssistant || event.eventType == .streamTurnEnd {
                if let tokenUsage = event.payload["tokenUsage"]?.value as? [String: Any],
                   let cacheRead = tokenUsage["cacheReadTokens"] as? Int {
                    total += cacheRead
                }
            }
        }
        return total
    }

    private var contentView: some View {
        contextView
    }

    // MARK: - Context View

    private var contextView: some View {
        Group {
            if let snapshot = detailedSnapshot {
                ScrollView {
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
                            cacheReadTokens: sessionTokenUsage.cacheRead
                        )
                        .padding(.horizontal)

                        // Token Breakdown header and expandable sections
                        TokenBreakdownHeader()
                            .padding(.horizontal)

                        // System Prompt + Tools + Skill References (combined expandable section)
                        SystemAndToolsSection(
                            systemPromptTokens: snapshot.breakdown.systemPrompt,
                            toolsTokens: snapshot.breakdown.tools,
                            systemPromptContent: snapshot.systemPromptContent,
                            toolsContent: snapshot.toolsContent,
                            allSkills: skillStore?.skills ?? []
                        )
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
                        // Uses displayedMessages for optimistic deletion animations
                        DetailedMessagesSection(
                            messages: displayedMessages,
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
        withAnimation(.tronStandard) {
            pendingMessageDeletions.insert(eventId)
        }

        do {
            _ = try await rpcClient.deleteMessage(sessionId, targetEventId: eventId)
            // Background reload to sync state (doesn't show loading)
            await reloadContextInBackground()
        } catch {
            // Rollback: show the message again if deletion failed
            withAnimation(.tronStandard) {
                pendingMessageDeletions.remove(eventId)
            }
            errorMessage = "Failed to delete message: \(error.localizedDescription)"
        }
    }

    private func removeSkillFromContext(skillName: String) async {
        // Optimistic update: immediately hide the skill with animation
        withAnimation(.tronStandard) {
            pendingSkillDeletions.insert(skillName)
        }

        do {
            let result = try await rpcClient.removeSkill(sessionId: sessionId, skillName: skillName)
            if result.success {
                // Background reload to sync state (doesn't show loading)
                await reloadContextInBackground()
            } else {
                // Rollback: show the skill again if removal failed
                withAnimation(.tronStandard) {
                    pendingSkillDeletions.remove(skillName)
                }
                errorMessage = result.error ?? "Failed to remove skill"
            }
        } catch {
            // Rollback: show the skill again if removal failed
            withAnimation(.tronStandard) {
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

    private var totalTokens: Int {
        inputTokens + outputTokens
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
            // Section header
            Text("Session Tokens")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

            // Main content card
            VStack(spacing: 12) {
                // Header with total
                HStack {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14))
                        .foregroundStyle(.tronAmberLight)

                    Text("Total")
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

                    // Cache read tokens
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "memorychip.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tronAmberLight)
                            Text("Cached")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Text(formatTokenCount(cacheReadTokens))
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

                // Footer explanation
                Text("Cumulative usage for this session")
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
            // Section header
            Text("Context Usage")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

            // Main content card
            VStack(spacing: 12) {
                // Header
                HStack {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 14))
                        .foregroundStyle(usageColor)

                    Text("Current Window")
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
        Text("Token Breakdown")
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
}

// MARK: - System and Tools Section

@available(iOS 26.0, *)
struct SystemAndToolsSection: View {
    let systemPromptTokens: Int
    let toolsTokens: Int
    let systemPromptContent: String
    let toolsContent: [String]
    /// All available skills (shown as Skill References - frontmatter only, NOT removable)
    var allSkills: [Skill] = []

    @State private var isExpanded = false
    @State private var showingSystemPrompt = false
    @State private var showingTools = false
    @State private var showingSkillRefs = false

    private var totalTokens: Int {
        systemPromptTokens + toolsTokens
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
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tronGray)

                    Text("System, Tools & Skills")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronGray)

                    Spacer()

                    Text(formatTokens(totalTokens))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? -180 : 0))
                }
                .padding(14)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .background {
                if !isExpanded {
                    // Subtle grey container (sub-containers keep their own colors)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular.tint(Color.white.opacity(0.08)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            // Expandable content
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // System Prompt - expandable
                    ExpandableContentSection(
                        icon: "doc.text.fill",
                        iconColor: .tronPurple,
                        title: "System Prompt",
                        tokens: systemPromptTokens,
                        content: systemPromptContent,
                        isExpanded: $showingSystemPrompt
                    )

                    // Tools - expandable
                    ExpandableContentSection(
                        icon: "hammer.fill",
                        iconColor: .tronAmber,
                        title: "Tools (\(toolsContent.count))",
                        tokens: toolsTokens,
                        content: toolsContent.joined(separator: "\n"),
                        isExpanded: $showingTools
                    )

                    // Skill References - frontmatter only, not removable
                    if !allSkills.isEmpty {
                        SkillReferencesSection(
                            skills: allSkills,
                            isExpanded: $showingSkillRefs
                        )
                    }
                }
                .padding(12)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
        .background {
            if isExpanded {
                // Subtle grey container (sub-containers keep their own colors)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.white.opacity(0.08)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }) {
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
                }
                .padding(10)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)

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
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(iconColor.opacity(0.25)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Skill References Section (frontmatter only, not removable)

@available(iOS 26.0, *)
struct SkillReferencesSection: View {
    let skills: [Skill]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.tronCyan.opacity(0.8))
                    Text("Skill References (\(skills.count))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? -180 : 0))
                }
                .padding(10)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)

            // Content - list of skill references (frontmatter only, lazy for performance)
            if isExpanded {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(skills) { skill in
                        SkillReferenceRow(skill: skill)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.tronCyan.opacity(0.25)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }) {
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
                }
                .padding(8)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            // Expanded description (just description, not full content)
            if isExpanded {
                Text(skill.description)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
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
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
                // Fetch content on first expand
                if isExpanded && fullContent == nil && !isLoadingContent {
                    Task {
                        await fetchContent()
                    }
                }
            }) {
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
                }
                .padding(8)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

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
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
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

// MARK: - Detailed Messages Section (using server data)

@available(iOS 26.0, *)
struct DetailedMessagesSection: View {
    let messages: [DetailedMessageInfo]
    var onDelete: ((String) -> Void)?

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            Text("Messages (\(messages.count))")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

            if messages.isEmpty {
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
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }) {
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
                        .padding(.top, 4)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

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
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
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
