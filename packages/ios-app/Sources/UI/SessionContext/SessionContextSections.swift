import SwiftUI

extension SessionContextSheet {
    var sessionSummary: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                contextGauge

                VStack(alignment: .leading, spacing: 4) {
                    Text(SessionContextPresentation.remainingContextText(
                        currentContextWindow: contextState.currentContextWindow,
                        tokensRemaining: contextState.tokensRemaining
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
        guard contextState.currentContextWindow > 0 else {
            return "Waiting for the model context-window limit"
        }
        return "\(TokenFormatter.format(contextState.currentContextWindow, style: .withSuffix)) window"
    }

    var requestSummarySection: some View {
        VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            SettingsSectionHeader(
                title: "Latest model request",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            if let summary = latestContextSummary {
                VStack(spacing: 9) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(summary.model ?? currentModelDisplayName)
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBody,
                                weight: .semibold
                            ))
                            .foregroundStyle(.tronTextPrimary)
                        Spacer()
                        Text(summary.turn.map { "Turn \($0)" } ?? "Legacy")
                            .font(TronTypography.pillValue)
                            .foregroundStyle(.tronEmerald)
                    }

                    HStack(spacing: 8) {
                        Label(
                            summary.providerName ?? summary.providerType ?? "Provider",
                            systemImage: "network"
                        )
                        Spacer()
                        Text(WorkerConsolePresentation.timestamp(summary.timestamp) ?? summary.timestamp)
                    }
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)

                    if summary.provenanceAvailability != "complete" {
                        Label(
                            "Legacy audit: exact request remains available, but source provenance was not recorded.",
                            systemImage: "clock.badge.exclamationmark"
                        )
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronAmber)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                }
                .padding(14)
                .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
            } else if isLoadingInspectableContext {
                ProgressView("Loading model context…")
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
            } else {
                Label(
                    contextLoadError ?? "No provider request has been recorded yet.",
                    systemImage: contextLoadError == nil
                        ? "text.page.badge.magnifyingglass"
                        : "exclamationmark.triangle"
                )
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(contextLoadError == nil ? .tronTextMuted : .tronError)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sectionFill(
                    contextLoadError == nil ? .tronEmerald : .tronError,
                    cornerRadius: 12,
                    subtle: true,
                    interactive: false
                )
            }
        }
    }

    var receivedContextSection: some View {
        VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            SettingsSectionHeader(
                title: "What the agent received",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            VStack(spacing: 0) {
                contextDisclosureRow(
                    title: "Instructions",
                    detail: "\(allSystemContributions.count) ordered contributions",
                    symbol: "text.alignleft",
                    accent: .tronPurple
                ) {
                    selectedContextDetail = .instructions(allSystemContributions)
                }
                Divider().opacity(0.35)
                contextDisclosureRow(
                    title: "Conversation & compaction",
                    detail: "\(providerMessageCount) provider-visible messages",
                    symbol: "bubble.left.and.bubble.right",
                    accent: .tronCyan
                ) {
                    selectedContextDetail = .messages(manifest?.messages ?? [])
                }
                Divider().opacity(0.35)
                contextDisclosureRow(
                    title: "Attachments & documents",
                    detail: "\(attachmentMessageCount) projected media messages",
                    symbol: "paperclip",
                    accent: .tronBlue
                ) {
                    selectedContextDetail = .attachments(
                        manifest?.messages.filter {
                            !$0.contentKinds.filter { $0 == "image" || $0 == "document" }.isEmpty
                        } ?? []
                    )
                }
                Divider().opacity(0.35)
                contextDisclosureRow(
                    title: "Environment",
                    detail: manifest?.environment.workingDirectory == nil
                        ? "No environment projection"
                        : "Working directory and server route",
                    symbol: "folder",
                    accent: .tronAmber
                ) {
                    selectedContextDetail = .environment(manifest?.environment)
                }
                Divider().opacity(0.35)
                contextDisclosureRow(
                    title: "Tool surface",
                    detail: "\(latestContextSummary?.toolCount ?? 0) exact tools",
                    symbol: "wrench.and.screwdriver",
                    accent: .tronEmerald
                ) {
                    selectedContextDetail = .tools(
                        fixed: requestFixedToolSelections,
                        workers: requestWorkerSelections,
                        raw: manifest?.toolSurface
                    )
                }
            }
            .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: false)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    var automaticContextSection: some View {
        VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            SettingsSectionHeader(
                title: "Automatic context",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            if let evaluations = manifest?.automaticContext, !evaluations.isEmpty {
                VStack(spacing: 8) {
                    ForEach(evaluations) { evaluation in
                        Button {
                            selectedContextDetail = .automatic(evaluation)
                        } label: {
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: evaluation.kind == "continuity"
                                    ? "brain.head.profile"
                                    : "tray.full")
                                    .foregroundStyle(evaluation.kind == "continuity"
                                        ? .tronPurple
                                        : .tronCyan)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(evaluation.kind == "continuity"
                                        ? "Continuity"
                                        : "Worker Inbox")
                                        .font(TronTypography.sans(
                                            size: TronTypography.sizeBody,
                                            weight: .semibold
                                        ))
                                        .foregroundStyle(.tronTextPrimary)
                                    Text(automaticContextSummary(evaluation))
                                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                        .foregroundStyle(.tronTextSecondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Text(WorkerConsolePresentation.displayLabel(evaluation.outcome))
                                    .font(TronTypography.pillValue)
                                    .foregroundStyle(evaluation.outcome == "failed"
                                        ? .tronError
                                        : .tronEmerald)
                            }
                            .padding(12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .sectionFill(
                            evaluation.kind == "continuity" ? .tronPurple : .tronCyan,
                            cornerRadius: 12,
                            subtle: true,
                            interactive: true
                        )
                    }
                }
            } else {
                Label(
                    latestContextSummary?.manifestAvailable == false
                        ? "Automatic contribution provenance is unavailable for this legacy request."
                        : "No automatic context evaluations were recorded.",
                    systemImage: "minus.circle"
                )
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)
            }
        }
    }

    var requestToolsSection: some View {
        let selected = requestWorkerSelections.filter(\.projected)
        let omitted = requestWorkerSelections.filter { !$0.projected }
        let omittedFixed = requestFixedToolSelections.filter { !$0.projected }
        return VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            SettingsSectionHeader(
                title: "Tools available for this request",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            VStack(spacing: 9) {
                HStack {
                    metric(label: "Fixed", value: "\(fixedToolCount)")
                    Divider().frame(height: 32)
                    metric(label: "Workers", value: "\(selected.count)")
                    Divider().frame(height: 32)
                    metric(label: "Omitted", value: "\(omitted.count + omittedFixed.count)")
                }

                if !selected.isEmpty {
                    Divider().opacity(0.35)
                    ForEach(selected.prefix(6)) { worker in
                        workerSelectionRow(worker)
                    }
                }

                if !omitted.isEmpty || !omittedFixed.isEmpty {
                    Button {
                        selectedContextDetail = .tools(
                            fixed: requestFixedToolSelections,
                            workers: requestWorkerSelections,
                            raw: manifest?.toolSurface
                        )
                    } label: {
                        HStack {
                            Label(
                                "See exact tool access and omissions",
                                systemImage: "eye.slash"
                            )
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .font(TronTypography.sans(
                            size: TronTypography.sizeCaption,
                            weight: .semibold
                        ))
                        .foregroundStyle(.tronTextSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(13)
            .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
        }
    }

    var attachmentMessageCount: Int {
        manifest?.messages.filter {
            $0.contentKinds.contains("image") || $0.contentKinds.contains("document")
        }.count ?? 0
    }

    var providerMessageCount: Int {
        manifest?.messages.count ?? Int(latestContextSummary?.messageCount ?? 0)
    }

    var fixedToolCount: UInt64 {
        guard let surface = manifest?.toolSurface.dictionaryValue else { return 0 }
        return UInt64(surface["fixedToolCount"] as? Int ?? 0)
    }

    func automaticContextSummary(_ evaluation: ContextAutomaticEvaluationDTO) -> String {
        if let narrative = evaluation.narrative, !narrative.isEmpty {
            return "\(SessionContextPresentation.automaticContextChannel(evaluation)) · \(narrative)"
        }
        return evaluation.detail.map {
            "\(SessionContextPresentation.automaticContextChannel(evaluation)) · \($0)"
        } ?? "\(SessionContextPresentation.automaticContextChannel(evaluation)) · \(WorkerConsolePresentation.displayLabel(evaluation.mechanism)) · \(evaluation.sources.count) sources"
    }

    func workerSelectionRow(_ worker: SessionContextWorkerSelection) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.horizontal.circle")
                .foregroundStyle(.tronEmerald)
            VStack(alignment: .leading, spacing: 2) {
                Text(WorkerConsolePresentation.displayLabel(worker.modelName))
                    .font(TronTypography.sans(
                        size: TronTypography.sizeCaption,
                        weight: .semibold
                    ))
                    .foregroundStyle(.tronTextPrimary)
                Text(
                    WorkerConsolePresentation.displayLabel(
                        worker.explanation
                            ?? worker.selectionReason
                            ?? worker.mechanism
                            ?? "selected"
                    )
                )
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
            }
            Spacer()
            if worker.score > 0 {
                Text("\(worker.score)")
                    .font(TronTypography.pillValue)
                    .foregroundStyle(.tronEmerald)
            }
        }
    }

    func contextDisclosureRow(
        title: String,
        detail: String,
        symbol: String,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
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
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(
                        size: TronTypography.sizeCaption,
                        weight: .semibold
                    ))
                    .foregroundStyle(.tronTextMuted)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var modelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "Model",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

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

            if let workerLoadError {
                Text(workerLoadError)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronError)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sectionFill(.tronError, cornerRadius: 10, subtle: true, interactive: false)
            } else if sessionWorkerRuns.isEmpty, !isLoadingWorkerRuns {
                Label("No workers have run in this session.", systemImage: "bolt.horizontal.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sectionFill(.tronCyan, cornerRadius: 10, subtle: true, interactive: false)
            } else {
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

            if workerRunsNextOffset != nil, !isLoadingWorkerRuns {
                Button {
                    Task { await loadSessionWorkerRuns(reset: false) }
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

    var providerAuditSection: some View {
        VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            SettingsSectionHeader(
                title: "Advanced",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            Button {
                if let latestContextDetail {
                    selectedContextDetail = .providerAudit(
                        latestContextDetail,
                        cacheReadTokens: contextState.accumulatedCacheReadTokens,
                        cacheWriteTokens: contextState.accumulatedCacheCreationTokens
                    )
                }
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
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tronTextMuted)
                }
                .padding(14)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(latestContextDetail == nil)
            .sectionFill(
                .tronTextMuted,
                cornerRadius: 12,
                subtle: true,
                interactive: latestContextDetail != nil
            )
        }
    }

}
