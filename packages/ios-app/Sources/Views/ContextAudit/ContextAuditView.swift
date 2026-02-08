import SwiftUI

// MARK: - Context Audit View

@available(iOS 26.0, *)
struct ContextAuditView: View {
    let rpcClient: RPCClient
    let sessionId: String
    var skillStore: SkillStore?
    var readOnly: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) var dependencies
    @State private var isLoading = true

    // Convenience accessor
    private var eventStoreManager: EventStoreManager { dependencies!.eventStoreManager }
    @State private var errorMessage: String?
    @State private var detailedSnapshot: DetailedContextSnapshotResult?
    @State private var sessionEvents: [SessionEvent] = []
    @State private var isClearing = false
    @State private var isCompacting = false
    @State private var showClearPopover = false
    @State private var showCompactPopover = false

    // Optimistic deletion state - skills being deleted animate out immediately
    @State private var pendingSkillDeletions: Set<String> = []

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

    /// All messages from snapshot
    private var allMessages: [DetailedMessageInfo] {
        detailedSnapshot?.messages ?? []
    }

    /// Paginated messages - show latest messages first (reverse chronological)
    private var paginatedMessages: [DetailedMessageInfo] {
        let reversed = allMessages.reversed()
        return Array(reversed.prefix(messagesLoadedCount))
    }

    /// Whether there are more messages to load
    private var hasMoreMessages: Bool {
        messagesLoadedCount < allMessages.count
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
                                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                            }
                            Text("Clear")
                                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                        }
                        .foregroundStyle(hasMessages && !readOnly ? .tronError : .tronTextMuted)
                    }
                    .disabled(isClearing || !hasMessages || readOnly)
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
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
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
                                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                            }
                            Text("Compact")
                                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                        }
                        .foregroundStyle(hasMessages && !readOnly ? .tronSlate : .tronTextMuted)
                    }
                    .disabled(isCompacting || !hasMessages || readOnly)
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
        .adaptivePresentationDetents([.medium, .large])
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
        GeometryReader { geometry in
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
                                            try await rpcClient.filesystem.readFile(path: path)
                                        }
                                    )
                                }

                                // Memory section (auto-injected memories, purple)
                                if let memory = snapshot.memory, memory.count > 0 {
                                    MemorySection(memory: memory)
                                }

                                // Skill References (standalone container with badge and token count)
                                if let skills = skillStore?.skills, !skills.isEmpty {
                                    SkillReferencesSection(skills: skills)
                                }

                                // Added Skills section (explicitly added via @skillname or skill sheet, deletable)
                                if !displayedSkills.isEmpty {
                                    AddedSkillsContainer(
                                        skills: displayedSkills,
                                        onDelete: readOnly ? nil : { skillName in
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
                                    totalMessages: allMessages.count,
                                    totalTokens: snapshot.breakdown.messages,
                                    hasMoreMessages: hasMoreMessages,
                                    onLoadMore: {
                                        messagesLoadedCount += 10
                                    }
                                )
                            }
                            .padding(.horizontal)

                            // Analytics Section
                            AnalyticsSection(
                                sessionId: sessionId,
                                events: sessionEvents,
                                inputTokens: sessionTokenUsage.input,
                                outputTokens: sessionTokenUsage.output,
                                cacheReadTokens: sessionTokenUsage.cacheRead,
                                cacheCreationTokens: sessionTokenUsage.cacheCreation
                            )
                            .padding(.horizontal)
                        }
                        .padding(.vertical)
                        .frame(width: geometry.size.width)
                    }
                    .frame(width: geometry.size.width)
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(.cyan)

                        Text("Loading context...")
                            .font(TronTypography.caption)
                            .foregroundStyle(.tronTextMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadContext() async {
        isLoading = true

        do {
            // Load detailed context snapshot and events in parallel
            async let snapshotTask = rpcClient.context.getDetailedSnapshot(sessionId: sessionId)
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
            async let snapshotTask = rpcClient.context.getDetailedSnapshot(sessionId: sessionId)
            let events = try eventStoreManager.getSessionEvents(sessionId)

            detailedSnapshot = try await snapshotTask
            sessionEvents = events
            updateCachedTokenUsage()

            // Clear any pending deletions since we now have fresh data
            pendingSkillDeletions.removeAll()

            // Reset message pagination when reloading
            messagesLoadedCount = 10
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearContext() async {
        isClearing = true

        do {
            _ = try await rpcClient.context.clear(sessionId: sessionId)
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
            let result = try await rpcClient.context.compact(sessionId: sessionId)
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

    private func removeSkillFromContext(skillName: String) async {
        // Optimistic update: immediately hide the skill with animation
        _ = withAnimation(.tronStandard) {
            pendingSkillDeletions.insert(skillName)
        }

        do {
            let result = try await rpcClient.misc.removeSkill(sessionId: sessionId, skillName: skillName)
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

