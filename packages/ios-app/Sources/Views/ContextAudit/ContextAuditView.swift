import SwiftUI

// MARK: - Context Audit View (Agent Control sheet)

@available(iOS 26.0, *)
struct ContextAuditView: View {
    let rpcClient: RPCClient
    let sessionId: String
    var skillStore: SkillStore?
    var readOnly: Bool = false
    /// Observable context state — drives background refresh when tokens change (e.g. after compaction)
    var contextState: ContextTrackingState?
    /// Current model info (for display name, tier, etc.)
    var currentModelInfo: ModelInfo?
    /// Current reasoning level (e.g. "low", "medium", "high")
    var reasoningLevel: String?
    /// Available models for the model picker
    var availableModels: [ModelInfo] = []
    /// Current model ID string for the model picker
    var currentModelId: String = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) var dependencies
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var detailedSnapshot: DetailedContextSnapshotResult?
    @State private var showContextDetail = false
    @State private var showModelPicker = false

    // Optimistic deletion state - skills being deleted animate out immediately
    @State private var pendingSkillDeletions: Set<String> = []

    var body: some View {
        NavigationStack {
            ZStack {
                contentView

                if isLoading && detailedSnapshot == nil {
                    Color.clear
                        .background(.ultraThinMaterial)
                        .overlay {
                            ProgressView()
                                .tint(.tronEmerald)
                        }
                        .ignoresSafeArea()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Agent Control")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
            }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(
                    models: availableModels,
                    currentModelId: currentModelId,
                    readOnly: readOnly,
                    reasoningLevel: reasoningLevel ?? "medium",
                    onSelect: { model in
                        NotificationCenter.default.post(name: .modelPickerAction, object: model)
                    }
                )
            }
            .sheet(isPresented: $showContextDetail) {
                if let snapshot = detailedSnapshot {
                    ContextDetailView(
                        rpcClient: rpcClient,
                        sessionId: sessionId,
                        snapshot: snapshot,
                        skillStore: skillStore,
                        readOnly: readOnly,
                        pendingSkillDeletions: pendingSkillDeletions,
                        onRemoveSkill: { skillName in
                            Task { await removeSkillFromContext(skillName: skillName) }
                        },
                        onFetchSkillContent: { skillName in
                            guard let store = skillStore else { return nil }
                            let metadata = await store.getSkill(name: skillName, sessionId: sessionId)
                            return metadata?.content
                        }
                    )
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
            .onChange(of: contextState?.contextWindowTokens) {
                Task { await reloadContextInBackground() }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
    }

    private var contentView: some View {
        GeometryReader { geometry in
            Group {
                if let snapshot = detailedSnapshot {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 12) {
                            ContextUsageGaugeView(
                                currentTokens: snapshot.currentTokens,
                                contextLimit: snapshot.contextLimit,
                                usagePercent: snapshot.usagePercent,
                                thresholdLevel: snapshot.thresholdLevel,
                                onTap: {
                                    showContextDetail = true
                                }
                            )
                            .padding(.horizontal)

                            ModelControlView(
                                modelInfo: currentModelInfo,
                                reasoningLevel: reasoningLevel,
                                onTap: {
                                    showModelPicker = true
                                }
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
            detailedSnapshot = try await rpcClient.context.getDetailedSnapshot(sessionId: sessionId)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func reloadContextInBackground() async {
        do {
            detailedSnapshot = try await rpcClient.context.getDetailedSnapshot(sessionId: sessionId)
            pendingSkillDeletions.removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeSkillFromContext(skillName: String) async {
        _ = withAnimation(.tronStandard) {
            pendingSkillDeletions.insert(skillName)
        }

        do {
            let result = try await rpcClient.skill.remove(sessionId: sessionId, skillName: skillName)
            if result.success {
                await reloadContextInBackground()
            } else {
                _ = withAnimation(.tronStandard) {
                    pendingSkillDeletions.remove(skillName)
                }
                errorMessage = result.error ?? "Failed to remove skill"
            }
        } catch {
            _ = withAnimation(.tronStandard) {
                pendingSkillDeletions.remove(skillName)
            }
            errorMessage = "Failed to remove skill: \(error.localizedDescription)"
        }
    }
}
