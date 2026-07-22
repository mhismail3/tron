import SwiftUI

enum SessionContextPressure: Equatable {
    case normal
    case elevated
    case critical

    var color: Color {
        switch self {
        case .normal: .tronEmerald
        case .elevated: .tronAmber
        case .critical: .tronError
        }
    }
}

/// Pure presentation and action policy for the Session Context surface.
enum SessionContextPresentation {
    static func boundedPercentage(_ percentage: Int) -> Int {
        min(max(percentage, 0), 100)
    }

    static func progressFraction(_ percentage: Int) -> Double {
        Double(boundedPercentage(percentage)) / 100
    }

    static func pressure(for percentage: Int) -> SessionContextPressure {
        switch boundedPercentage(percentage) {
        case 95...: .critical
        case 80...: .elevated
        default: .normal
        }
    }

    static func canMutate(
        isConnected: Bool,
        isAgentActive: Bool,
        isCompacting: Bool,
        isBusy: Bool
    ) -> Bool {
        isConnected && !isAgentActive && !isCompacting && !isBusy
    }

    static func mutationUnavailableReason(
        isConnected: Bool,
        isAgentActive: Bool,
        isCompacting: Bool
    ) -> String? {
        if !isConnected { return "Reconnect to change the model or fork this session." }
        if isCompacting { return "Wait for context compaction to finish." }
        if isAgentActive { return "Wait for the current response to finish." }
        return nil
    }

    static func hasSessionUsage(inputTokens: Int, outputTokens: Int, cost: Double) -> Bool {
        inputTokens > 0 || outputTokens > 0 || cost > 0
    }

    static func remainingContextText(currentContextWindow: Int, tokensRemaining: Int) -> String {
        guard currentContextWindow > 0 else { return "Window loading" }
        return "\(TokenFormatter.format(tokensRemaining, style: .withSuffix)) left"
    }
}

/// Minimal session-scoped context telemetry and controls backed only by current
/// engine behavior: server token records, the model catalog/switch operation,
/// automatic compaction state, and session forking.
struct SessionContextSheet: View {
    let contextState: ContextTrackingState
    let currentModelId: String
    let currentModelInfo: ModelInfo?
    let reasoningLevel: String?
    let isConnected: Bool
    let isAgentActive: Bool
    let isCompacting: Bool
    let isFork: Bool
    let modelRepository: any ModelRepository
    let onSelectModel: (ModelInfo) -> Void
    let onFork: () async throws -> String

    @Environment(\.dismiss) private var dismiss
    @State private var availableModels: [ModelInfo] = []
    @State private var isLoadingModels = false
    @State private var isForking = false
    @State private var showModelPicker = false
    @State private var showForkConfirmation = false
    @State private var errorMessage: String?

    private var percentage: Int { contextState.contextPercentage }
    private var accent: Color { SessionContextPresentation.pressure(for: percentage).color }
    private var totalSessionInputTokens: Int {
        contextState.accumulatedInputTokens + contextState.accumulatedCacheReadTokens
    }
    private var canMutate: Bool {
        SessionContextPresentation.canMutate(
            isConnected: isConnected,
            isAgentActive: isAgentActive,
            isCompacting: isCompacting,
            isBusy: isForking
        )
    }
    private var currentModelDisplayName: String {
        currentModelInfo?.formattedModelName ?? currentModelId.shortModelName
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 18) {
                    contextSection
                    modelSection

                    if SessionContextPresentation.hasSessionUsage(
                        inputTokens: totalSessionInputTokens,
                        outputTokens: contextState.accumulatedOutputTokens,
                        cost: contextState.accumulatedCost
                    ) {
                        usageSection
                    }

                    sessionActionsSection

                    if let reason = SessionContextPresentation.mutationUnavailableReason(
                        isConnected: isConnected,
                        isAgentActive: isAgentActive,
                        isCompacting: isCompacting
                    ) {
                        Text(reason)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Session Context", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
        .task { await loadModels() }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(
                models: availableModels,
                currentModelId: currentModelId,
                readOnly: !canMutate,
                reasoningLevel: currentModelInfo?.supportsReasoning == true ? reasoningLevel : nil,
                onSelect: onSelectModel
            )
        }
        .confirmationDialog(
            "Fork this session?",
            isPresented: $showForkConfirmation,
            titleVisibility: .visible
        ) {
            Button("Fork from current point") {
                Task { await forkSession() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a new session branch while preserving this session unchanged.")
        }
        .tronErrorAlert(message: $errorMessage)
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Context")

            VStack(spacing: 16) {
                HStack(spacing: 18) {
                    contextGauge

                    VStack(alignment: .leading, spacing: 7) {
                        Text(SessionContextPresentation.remainingContextText(
                            currentContextWindow: contextState.currentContextWindow,
                            tokensRemaining: contextState.tokensRemaining
                        ))
                            .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                            .foregroundStyle(accent)

                        Text("\(TokenFormatter.format(contextState.contextWindowTokens, style: .withSuffix)) currently used")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextSecondary)

                        Text(contextWindowDescription)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }

                    Spacer(minLength: 0)
                }

                Divider().opacity(0.35)

                HStack(spacing: 10) {
                    Image(systemName: isCompacting ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(isCompacting ? accent : .tronEmerald)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic compaction")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronTextPrimary)
                        Text(isCompacting ? "Compacting this session now" : "Managed by the Engine context settings")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }

                    Spacer()

                    Text(isCompacting ? "Running" : "On")
                        .font(TronTypography.pillValue)
                        .foregroundStyle(isCompacting ? accent : .tronEmerald)
                }
            }
            .padding(16)
            .sectionFill(accent, cornerRadius: 12, subtle: true, interactive: false)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var contextGauge: some View {
        ZStack {
            Circle()
                .stroke(Color.tronTextMuted.opacity(0.2), lineWidth: 7)
            Circle()
                .trim(from: 0, to: SessionContextPresentation.progressFraction(percentage))
                .stroke(accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(percentage)%")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                .foregroundStyle(accent)
        }
        .frame(width: 76, height: 76)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context used")
        .accessibilityValue("\(percentage) percent")
    }

    private var contextWindowDescription: String {
        guard contextState.currentContextWindow > 0 else {
            return "Waiting for the model context-window limit"
        }
        return "\(TokenFormatter.format(contextState.currentContextWindow, style: .withSuffix)) total window"
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Model")

            Button {
                showModelPicker = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "cpu")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(.tronPurple)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(currentModelDisplayName)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(.tronTextPrimary)
                            .lineLimit(1)

                        Text(currentModelInfo?.formattedContextWindow ?? "Current session model")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }

                    Spacer()

                    if isLoadingModels {
                        ProgressView().controlSize(.small).tint(.tronPurple)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                .padding(14)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: canMutate)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(!canMutate || availableModels.isEmpty)
            .accessibilityIdentifier("session-context-model-picker")
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Session Usage")

            HStack(spacing: 0) {
                metric(label: "Input", value: TokenFormatter.format(totalSessionInputTokens))
                Divider().frame(height: 42)
                metric(label: "Output", value: TokenFormatter.format(contextState.accumulatedOutputTokens))
                Divider().frame(height: 42)
                metric(label: "Cost", value: formatCost(contextState.accumulatedCost))
            }
            .padding(.vertical, 14)
            .sectionFill(.tronInfo, cornerRadius: 12, subtle: true, interactive: false)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func metric(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private var sessionActionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Session")

            Button {
                showForkConfirmation = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(isFork ? "Fork again from here" : "Fork from current point")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(.tronTextPrimary)
                        Text("Create a new branch without changing this session")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }

                    Spacer()

                    if isForking {
                        ProgressView().controlSize(.small).tint(.tronEmerald)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                .padding(14)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: canMutate)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(!canMutate)
            .accessibilityIdentifier("session-context-fork")
        }
    }

    private func loadModels() async {
        availableModels = modelRepository.cachedModels
        guard availableModels.isEmpty, isConnected else { return }

        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            availableModels = try await modelRepository.list(forceRefresh: false)
        } catch {
            errorMessage = "Could not load models: \(error.localizedDescription)"
        }
    }

    private func forkSession() async {
        guard canMutate else { return }
        isForking = true
        defer { isForking = false }
        do {
            let newSessionId = try await onFork()
            dismiss()
            await Task.yield()
            NotificationCenter.default.post(name: .switchToSession, object: newSessionId)
        } catch {
            errorMessage = "Could not fork session: \(error.localizedDescription)"
        }
    }
}
