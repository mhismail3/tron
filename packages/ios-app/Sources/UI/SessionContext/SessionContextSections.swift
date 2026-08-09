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
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text("\(TokenFormatter.format(contextState.contextWindowTokens, style: .withSuffix)) used · \(contextWindowDescription)")
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
                Image(systemName: isCompacting ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(isCompacting ? accent : .tronEmerald)
                    .accessibilityHidden(true)
                Text("Automatic compaction")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
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

    var receivedContextSection: some View {
        VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            SettingsSectionHeader(
                title: "What the agent received",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            if latestContextSummary != nil {
                VStack(spacing: 0) {
                    contextDisclosureRow(
                        title: "Instructions",
                        detail: "\(instructionContributionCount) ordered contributions",
                        symbol: "text.alignleft",
                        accent: .tronPurple,
                        destination: .instructions
                    )
                    Divider().opacity(0.35)
                    contextDisclosureRow(
                        title: "Conversation & compaction",
                        detail: "\(providerMessageCount) provider-visible messages",
                        symbol: "bubble.left.and.bubble.right",
                        accent: .tronCyan,
                        destination: .messages
                    )
                    Divider().opacity(0.35)
                    contextDisclosureRow(
                        title: "Updates included",
                        detail: "\(includedDeliveryCount) included in this model request",
                        symbol: "bell.and.waves.left.and.right",
                        accent: .tronEmerald,
                        destination: .deliveries
                    )
                    Divider().opacity(0.35)
                    contextDisclosureRow(
                        title: "Attachments & documents",
                        detail: "\(attachmentMessageCount) projected media messages",
                        symbol: "paperclip",
                        accent: .tronBlue,
                        destination: .attachments
                    )
                    Divider().opacity(0.35)
                    contextDisclosureRow(
                        title: "Environment",
                        detail: environmentContextDescription,
                        symbol: "folder",
                        accent: .tronAmber,
                        destination: .environment
                    )
                    Divider().opacity(0.35)
                    contextDisclosureRow(
                        title: "Tool surface",
                        detail: "\(latestContextSummary?.toolCount ?? 0) exact tools",
                        symbol: "wrench.and.screwdriver",
                        accent: .tronEmerald,
                        destination: .tools
                    )
                }
                .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: false)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if let contextLoadError {
                    Label(contextLoadError, systemImage: "exclamationmark.triangle")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronAmber)
                }
            } else {
                Button {
                    if contextLoadError != nil {
                        requestProviderContextRefresh()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isLoadingInspectableContext {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: contextLoadError == nil
                                ? "text.page.badge.magnifyingglass"
                                : "exclamationmark.triangle")
                        }
                        Text(
                            contextLoadError
                                ?? (isLoadingInspectableContext
                                    ? "Loading request context…"
                                    : "No provider request has been recorded yet.")
                        )
                        Spacer(minLength: 0)
                        if contextLoadError != nil {
                            Text("Retry").font(TronTypography.pillValue)
                        }
                    }
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(contextLoadError == nil ? .tronTextMuted : .tronError)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sectionFill(
                    contextLoadError == nil ? .tronEmerald : .tronError,
                    cornerRadius: 12,
                    subtle: true,
                    interactive: contextLoadError != nil
                )
            }
        }
    }

    var agentUpdatesSection: some View {
        VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            SettingsSectionHeader(
                title: "Delivery & wait status",
                bottomPadding: 0
            )
            Text("Live session state. Available does not mean included. Only In request or Seen updates entered model context.")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(.bottom, SessionContextPresentation.headerToContentSpacing)

            if activeAgentUpdates.isEmpty,
               activeAgentWaits.isEmpty,
               historicalAgentUpdates.isEmpty,
               historicalAgentWaits.isEmpty {
                Button {
                    if agentUpdatesLoadError != nil {
                        requestAgentUpdatesRefresh()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Label(
                            SessionContextPresentation.deliveryWaitEmptyState(
                                error: agentUpdatesLoadError,
                                isLoading: isLoadingAgentUpdates,
                                hasLoadedSnapshot: hasLoadedAgentUpdatesSnapshot
                            ),
                            systemImage: agentUpdatesLoadError == nil
                                ? "bell.slash"
                                : "exclamationmark.triangle"
                        )
                        Spacer(minLength: 0)
                        if agentUpdatesLoadError != nil {
                            Text("Retry")
                                .font(TronTypography.pillValue)
                        }
                    }
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(agentUpdatesLoadError == nil ? .tronTextMuted : .tronError)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sectionFill(
                    agentUpdatesLoadError == nil ? .tronEmerald : .tronError,
                    cornerRadius: 12,
                    subtle: true,
                    interactive: agentUpdatesLoadError != nil
                )
            } else {
                VStack(spacing: 8) {
                    if let agentUpdatesLoadError {
                        Label(agentUpdatesLoadError, systemImage: "exclamationmark.triangle")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronAmber)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .sectionFill(
                                .tronAmber,
                                cornerRadius: 10,
                                subtle: true,
                                interactive: false
                            )
                    }
                    ForEach(activeAgentWaits) { wait in
                        agentWaitCard(wait)
                    }
                    ForEach(activeAgentUpdates) { update in
                        agentUpdateCard(update)
                    }
                    if deliveryHistoryCount > 0 {
                        Button {
                            showDeliveryHistorySheet = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.tronTextSecondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Recent delivery history (\(deliveryHistoryCount))")
                                        .font(TronTypography.sans(
                                            size: TronTypography.sizeBodySM,
                                            weight: .semibold
                                        ))
                                        .foregroundStyle(.tronTextPrimary)
                                    Text("View resolved deliveries and waits")
                                        .font(TronTypography.sans(
                                            size: TronTypography.sizeCaption
                                        ))
                                        .foregroundStyle(.tronTextMuted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .sectionFill(
                            .tronTextMuted,
                            cornerRadius: 12,
                            subtle: true,
                            interactive: true
                        )
                        .accessibilityHint("Opens recent delivery history")
                    }
                }
            }
        }
    }

    func agentWaitCard(_ wait: SessionAgentWaitDTO) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: wait.status == "pending" ? "hourglass" : "checkmark.circle")
                .foregroundStyle(wait.status == "pending" ? .tronAmber : .tronEmerald)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(SessionContextPresentation.agentWaitTitle(status: wait.status))
                    .font(TronTypography.sans(
                        size: TronTypography.sizeBodySM,
                        weight: .semibold
                    ))
                Text(SessionContextPresentation.agentWaitDescription(
                    status: wait.status,
                    mode: wait.mode
                ))
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(SessionContextPresentation.agentWaitStatusLabel(status: wait.status))
                .font(TronTypography.pillValue)
                .foregroundStyle(wait.status == "pending" ? .tronAmber : .tronEmerald)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(12)
        .sectionFill(
            wait.status == "pending" ? .tronAmber : .tronEmerald,
            cornerRadius: 12,
            subtle: true,
            interactive: false
        )
    }

    @ViewBuilder
    func agentUpdateCard(_ update: SessionAgentUpdateDTO) -> some View {
        if let invocationId = update.resultInvocationId {
            Button {
                selectedWorkerResult = WorkerResultSelection(invocationId: invocationId)
            } label: {
                agentUpdateCardContent(update, interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the exact durable worker result")
        } else {
            agentUpdateCardContent(update, interactive: false)
        }
    }

    func agentUpdateCardContent(
        _ update: SessionAgentUpdateDTO,
        interactive: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: agentUpdateSymbol(update.status))
                .foregroundStyle(agentUpdateColor(update.status))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(SessionContextPresentation.agentUpdateTitle(
                    sourceKind: update.sourceKind,
                    sourceWorkerId: update.sourceWorkerId,
                    sourceWorkerName: update.sourceWorkerName
                ))
                    .font(TronTypography.sans(
                        size: TronTypography.sizeBodySM,
                        weight: .semibold
                    ))
                Text(SessionContextPresentation.agentUpdateStateDescription(
                    status: update.status,
                    wakePolicy: update.wakePolicy,
                    boundary: update.boundary
                ))
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(agentUpdateColor(update.status))
                    .fixedSize(horizontal: false, vertical: true)
                Text(update.preview)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(3)
                if let error = update.lastError, !error.isEmpty {
                    Text(error)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronError)
                        .lineLimit(2)
                }
                if let timestamp = WorkerConsolePresentation.timestamp(
                    update.observedAt ?? update.cancelledAt ?? update.createdAt
                ) {
                    Text(timestamp)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(SessionContextPresentation.agentUpdateStatusLabel(
                status: update.status,
                wakePolicy: update.wakePolicy
            ))
                .font(TronTypography.pillValue)
                .foregroundStyle(agentUpdateColor(update.status))
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(12)
        .sectionFill(
            agentUpdateColor(update.status),
            cornerRadius: 12,
            subtle: true,
            interactive: interactive
        )
    }

    func agentUpdateColor(_ status: String) -> Color {
        switch status {
        case "observed": .tronEmerald
        case "prepared": .tronCyan
        case "pending": .tronAmber
        case "retry_exhausted": .tronError
        default: .tronTextMuted
        }
    }

    func agentUpdateSymbol(_ status: String) -> String {
        switch status {
        case "observed": "checkmark.circle.fill"
        case "prepared": "eye.circle"
        case "pending": "clock"
        case "retry_exhausted": "exclamationmark.triangle.fill"
        case "stale": "clock.badge.xmark"
        case "cancelled": "xmark.circle"
        default: "bell"
        }
    }

    var automaticContextSection: some View {
        VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            SettingsSectionHeader(
                title: "Legacy automatic context",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            contextDisclosureRow(
                title: "Historical contributions",
                detail: "\(automaticContextCount) recorded evaluations",
                symbol: "clock.arrow.circlepath",
                accent: .tronCyan,
                destination: .automaticContext
            )
            .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    var instructionContributionCount: Int {
        if latestContextDetail != nil {
            return allSystemContributions.count
        }
        return Int(latestContextSummary?.instructionCount ?? 0)
    }

    var attachmentMessageCount: Int {
        if let messages = manifest?.messages {
            return messages.filter {
                $0.contentKinds.contains("image") || $0.contentKinds.contains("document")
            }.count
        }
        return Int(latestContextSummary?.attachmentMessageCount ?? 0)
    }

    var providerMessageCount: Int {
        manifest?.messages.count ?? Int(latestContextSummary?.messageCount ?? 0)
    }

    var includedDeliveryCount: Int {
        if let deliveries = manifest?.agentDeliveries {
            return deliveries.count
        }
        return Int(latestContextSummary?.agentDeliveryCount ?? 0)
    }

    var automaticContextCount: Int {
        manifest?.automaticContext.count
            ?? Int(latestContextSummary?.automaticContextCount ?? 0)
    }

    var environmentContextDescription: String {
        let isAvailable = manifest?.environment.workingDirectory != nil
            || latestContextSummary?.environmentAvailable == true
        return isAvailable ? "Working directory and server route" : "No environment projection"
    }

    func contextDisclosureRow(
        title: String,
        detail: String,
        symbol: String,
        accent: Color,
        destination: SessionContextDetailDestination
    ) -> some View {
        Button {
            openContextDetail(destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TronTypography.sans(
                            size: TronTypography.sizeBodySM,
                            weight: .semibold
                        ))
                        .foregroundStyle(.tronTextPrimary)
                    Text(detail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
                Spacer()
                if contextDetailLoadingDestination == destination {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accent)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(
            latestContextSummary == nil
                || (contextDetailLoadingDestination != nil
                    && contextDetailLoadingDestination != destination)
        )
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
            metric(label: "Output", value: TokenFormatter.format(contextState.accumulatedOutputTokens))
            Divider().frame(height: 32)
            metric(label: "Cost", value: formatCost(contextState.accumulatedCost))
        }
    }

    func metric(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
    }

    var workerActivitySection: some View {
        VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            VStack(alignment: .leading, spacing: SessionContextPresentation.headerToSubheaderSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Workers in this session")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronTextSecondary)
                    Spacer()
                    if isLoadingWorkerRuns, sessionWorkerRuns.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.tronCyan)
                    } else if !workerRunGroups.isEmpty {
                        Text("\(workerRunGroups.count) roots · \(sessionWorkerRuns.count) runs")
                            .font(TronTypography.pillValue)
                            .foregroundStyle(.tronCyan)
                    }
                }

                Text("Runs started here, including nested work from the same causal trace.")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let workerLoadError, sessionWorkerRuns.isEmpty {
                Button {
                    requestWorkerRefresh()
                } label: {
                    HStack(spacing: 8) {
                        Label(workerLoadError, systemImage: "exclamationmark.triangle")
                        Spacer(minLength: 0)
                        Text("Retry")
                            .font(TronTypography.pillValue)
                    }
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronError)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sectionFill(.tronError, cornerRadius: 10, subtle: true, interactive: true)
            } else if sessionWorkerRuns.isEmpty, !isLoadingWorkerRuns {
                Label("No workers have run in this session.", systemImage: "bolt.horizontal.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sectionFill(.tronCyan, cornerRadius: 10, subtle: true, interactive: false)
            } else {
                VStack(spacing: 7) {
                    if let workerLoadError {
                        Label(workerLoadError, systemImage: "exclamationmark.triangle")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronAmber)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .sectionFill(
                                .tronAmber,
                                cornerRadius: 10,
                                subtle: true,
                                interactive: false
                            )
                    }
                    LazyVStack(spacing: 7) {
                        ForEach(workerRunGroups) { group in
                            SessionWorkerRunRow(
                                run: group.root,
                                workerName: workerNames[group.root.workerId]
                                    ?? WorkerConsolePresentation.displayLabel(group.root.workerId)
                            ) {
                                selectedWorkerRun = group.root
                            }
                            ForEach(group.descendants) { child in
                                SessionWorkerRunRow(
                                    run: child,
                                    workerName: workerNames[child.workerId]
                                        ?? WorkerConsolePresentation.displayLabel(child.workerId)
                                ) {
                                    selectedWorkerRun = child
                                }
                                .padding(.leading, 18)
                            }
                        }
                    }
                }
            }

            if workerRunsNextOffset != nil, !isLoadingWorkerRuns {
                Button {
                    loadOlderSessionWorkerRuns()
                } label: {
                    Label("Load older worker runs", systemImage: "clock.arrow.circlepath")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .sectionFill(.tronCyan, cornerRadius: 10, subtle: true, interactive: true)
            }
        }
    }

    var sessionActionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "Session",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            if dependencies.terminalRepository.isSupported {
                Button { showTerminal = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "terminal")
                            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                            .foregroundStyle(.tronCyan)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Terminal Mode")
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                                .foregroundStyle(.tronTextPrimary)
                            Text("Open a native shell in this session’s workspace")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextMuted)
                        }
                        Spacer()
                    }
                    .padding(14)
                }
                .buttonStyle(.plain)
                .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: isConnected)
                .disabled(!isConnected)
                .padding(.bottom, 8)
            }

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

    var providerAuditSection: some View {
        VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            SettingsSectionHeader(
                title: "Advanced",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            Button {
                openContextDetail(.providerAudit)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.tronTextMuted)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Redacted provider request")
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBody,
                                weight: .semibold
                            ))
                            .foregroundStyle(.tronTextPrimary)
                        Text("Exact bounded audit envelope, with media and secrets projected")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                    Spacer()
                    if contextDetailLoadingDestination == .providerAudit {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.tronTextMuted)
                    }
                }
                .padding(14)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(latestContextSummary == nil)
            .sectionFill(
                .tronTextMuted,
                cornerRadius: 12,
                subtle: true,
                interactive: latestContextSummary != nil
            )
        }
    }

}
