import SwiftUI

extension SessionContextSheet {
    var sessionSummary: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                contextGauge

                VStack(alignment: .leading, spacing: 4) {
                    Text(SessionContextPresentation.remainingContextText(
                        currentContextWindow: effectiveContextWindow,
                        tokensRemaining: effectiveTokensRemaining
                    ))
                        .font(TronTypography.sans(
                            size: TronTypography.sizeTitle,
                            weight: .semibold
                        ))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(
                        "\(TokenFormatter.format(contextState.contextWindowTokens, style: .withSuffix)) used"
                            + " · \(contextWindowDescription)"
                    )
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)
            }

            if SessionContextPresentation.hasSessionUsage(
                inputTokens: totalSessionInputTokens,
                outputTokens: contextState.accumulatedOutputTokens,
                cost: contextState.accumulatedCost
            ) {
                Divider().opacity(0.35)
                usageMetrics
            }

            Divider().opacity(0.35)

            HStack(spacing: 8) {
                Image(systemName: isCompacting
                    ? "arrow.triangle.2.circlepath.circle.fill"
                    : "arrow.triangle.2.circlepath")
                    .foregroundStyle(isCompacting ? accent : .tronEmerald)
                    .accessibilityHidden(true)
                Text("Automatic compaction")
                    .font(TronTypography.sans(
                        size: TronTypography.sizeCaption,
                        weight: .semibold
                    ))
                    .foregroundStyle(.tronTextSecondary)
                Spacer()
                Text(isCompacting ? "Running" : "On")
                    .font(TronTypography.pillValue)
                    .foregroundStyle(isCompacting ? accent : .tronEmerald)
            }
        }
        .padding(14)
        .sectionFill(accent, cornerRadius: 12, subtle: true, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    var managementRows: some View {
        VStack(spacing: 8) {
            agentContextSection
            backgroundActivitySection
                .onAppear { activateAgentUpdatesLane() }
            workerActivitySection
                .onAppear { activateWorkerLane() }
            terminalAction
            forkAction
            technicalDetailsSection
        }
    }

    var agentContextSection: some View {
        highLevelRow(
            title: "Agent Context",
            detail: agentContextDescription,
            symbol: "text.page.badge.magnifyingglass",
            accent: .tronPurple,
            trailingText: latestContextSummary.map { "\($0.messageCount) messages" },
            isLoading: contextDetailLoadingDestination == .agentContext
                || (isLoadingInspectableContext && latestContextSummary == nil),
            isEnabled: latestContextSummary != nil || contextLoadError != nil
        ) {
            if latestContextSummary != nil {
                openContextDetail(.agentContext)
            } else if contextLoadError != nil {
                requestProviderContextRefresh()
            }
        }
        .accessibilityHint("Opens the instructions, conversation, updates, attachments, and tools available to the agent")
    }

    var backgroundActivitySection: some View {
        let total = agentUpdates.count + agentWaits.count
        let active = activeAgentUpdates.count + activeAgentWaits.count
        return highLevelRow(
            title: "Background Activity",
            detail: backgroundActivityDescription,
            symbol: "bell.and.waves.left.and.right",
            accent: active > 0 ? .tronAmber : .tronEmerald,
            trailingText: total > 0 ? "\(total) records" : nil,
            isLoading: isLoadingAgentUpdates && !hasLoadedAgentUpdatesSnapshot,
            isEnabled: true
        ) {
            showBackgroundActivity = true
        }
        .accessibilityHint("Opens background deliveries and waits for this session")
    }

    var workerActivitySection: some View {
        highLevelRow(
            title: "Session Workers",
            detail: workerActivityDescription,
            symbol: "person.2",
            accent: .tronCyan,
            trailingText: sessionWorkerRuns.isEmpty ? nil : "\(sessionWorkerRuns.count) runs",
            isLoading: isLoadingWorkerRuns && sessionWorkerRuns.isEmpty,
            isEnabled: true
        ) {
            showSessionWorkers = true
        }
        .accessibilityHint("Opens the workers run by this session")
    }

    var terminalAction: some View {
        let availability = SessionContextPresentation.terminalAvailability(
            isConnected: isConnected,
            isSupported: dependencies.terminalRepository.isSupported
        )
        return highLevelRow(
            title: SessionContextPresentation.terminalActionTitle,
            detail: availability.detail,
            symbol: "terminal",
            accent: .tronCyan,
            trailingText: nil,
            isLoading: false,
            isEnabled: availability.isEnabled
        ) {
            showTerminal = true
        }
        .accessibilityIdentifier("session-context-terminal")
    }

    var forkAction: some View {
        highLevelRow(
            title: isFork ? "Fork again from here" : "Fork from current point",
            detail: "Create a new branch without changing this session",
            symbol: "arrow.triangle.branch",
            accent: .tronEmerald,
            trailingText: nil,
            isLoading: isForking,
            isEnabled: canMutate
        ) {
            showForkConfirmation = true
        }
        .accessibilityIdentifier("session-context-fork")
    }

    var technicalDetailsSection: some View {
        highLevelRow(
            title: "Technical Details",
            detail: "Provenance, integrity, environment, cache, and exact request evidence",
            symbol: "wrench.and.screwdriver",
            accent: .tronTextMuted,
            trailingText: nil,
            isLoading: contextDetailLoadingDestination == .technical,
            isEnabled: latestContextSummary != nil
        ) {
            openContextDetail(.technical)
        }
        .accessibilityHint("Opens technical audit evidence for the latest model request")
    }

    private var agentContextDescription: String {
        if let contextLoadError {
            return "Couldn’t refresh context. Tap to retry. \(contextLoadError)"
        }
        if latestContextSummary == nil {
            return isLoadingInspectableContext
                ? "Loading the latest model context"
                : "Available after the first model request"
        }
        return "Instructions, conversation, background updates, attachments, and available tools"
    }

    private var backgroundActivityDescription: String {
        if let agentUpdatesLoadError {
            return "Showing retained activity; refresh is currently unavailable. \(agentUpdatesLoadError)"
        }
        let active = activeAgentUpdates.count + activeAgentWaits.count
        if active > 0 {
            return "\(active) active delivery or wait \(active == 1 ? "record" : "records")"
        }
        if isLoadingAgentUpdates, !hasLoadedAgentUpdatesSnapshot {
            return "Loading delivery and wait status"
        }
        return agentUpdates.isEmpty && agentWaits.isEmpty
            ? "No background deliveries or waits"
            : "Review completed deliveries and waits"
    }

    private var workerActivityDescription: String {
        if let workerLoadError {
            return "Showing retained runs; refresh is currently unavailable. \(workerLoadError)"
        }
        if isLoadingWorkerRuns, sessionWorkerRuns.isEmpty {
            return "Loading workers run by this session"
        }
        if sessionWorkerRuns.isEmpty {
            return "No workers have run in this session"
        }
        return "View \(workerRunGroups.count) causal \(workerRunGroups.count == 1 ? "worker" : "workers") and their nested runs"
    }

    private func highLevelRow(
        title: String,
        detail: String,
        symbol: String,
        accent: Color,
        trailingText: String?,
        isLoading: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(TronTypography.sans(
                        size: TronTypography.sizeTitle,
                        weight: .medium
                    ))
                    .foregroundStyle(accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(TronTypography.sans(
                            size: TronTypography.sizeBody,
                            weight: .semibold
                        ))
                        .foregroundStyle(.tronTextPrimary)
                    Text(detail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accent)
                } else {
                    if let trailingText {
                        Text(trailingText)
                            .font(TronTypography.pillValue)
                            .foregroundStyle(accent)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Image(systemName: "chevron.right")
                        .font(TronTypography.sans(
                            size: TronTypography.sizeCaption,
                            weight: .semibold
                        ))
                        .foregroundStyle(.tronTextMuted)
                }
            }
            .padding(14)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .sectionFill(accent, cornerRadius: 12, subtle: true, interactive: isEnabled)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .disabled(!isEnabled)
    }

    var contextGauge: some View {
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
        .frame(width: 64, height: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context used")
        .accessibilityValue("\(percentage) percent")
    }

    var contextWindowDescription: String {
        guard effectiveContextWindow > 0 else {
            return "Model window unavailable"
        }
        return "\(TokenFormatter.format(effectiveContextWindow, style: .withSuffix)) window"
    }

    var usageMetrics: some View {
        let cachePercentage = SessionContextPresentation.cacheReadPercentage(
            cacheReadTokens: contextState.accumulatedCacheReadTokens,
            totalInputTokens: totalSessionInputTokens
        )
        return HStack(spacing: 0) {
            metric(label: "Input", value: TokenFormatter.format(totalSessionInputTokens))
            Divider().frame(height: 32)
            metric(label: "Cached", value: "\(cachePercentage)%")
                .accessibilityValue(
                    "\(contextState.accumulatedCacheReadTokens) cache-read tokens"
                )
            Divider().frame(height: 32)
            metric(
                label: "Output",
                value: TokenFormatter.format(contextState.accumulatedOutputTokens)
            )
            Divider().frame(height: 32)
            metric(label: "Cost", value: formatCost(contextState.accumulatedCost))
        }
    }

    func metric(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(TronTypography.sans(
                    size: TronTypography.sizeBodySM,
                    weight: .semibold
                ))
                .foregroundStyle(.tronTextPrimary)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
    }
}
