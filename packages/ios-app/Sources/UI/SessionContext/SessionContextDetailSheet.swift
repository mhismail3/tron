import Foundation
import SwiftUI

enum SessionContextDetailSelection: Identifiable, Equatable {
    case instructions([ContextSystemContributionDTO])
    case messages([ContextMessageManifestDTO])
    case attachments([ContextMessageManifestDTO])
    case environment(ContextEnvironmentManifestDTO?)
    case tools(
        fixed: [SessionContextFixedToolSelection],
        workers: [SessionContextWorkerSelection],
        raw: AnyCodable?
    )
    case automatic(ContextAutomaticEvaluationDTO)
    case providerAudit(
        SessionContextRequestDetailDTO,
        cacheReadTokens: Int,
        cacheWriteTokens: Int
    )

    var id: String {
        switch self {
        case .instructions: "instructions"
        case .messages: "messages"
        case .attachments: "attachments"
        case .environment: "environment"
        case .tools: "tools"
        case .automatic(let evaluation): "automatic:\(evaluation.id)"
        case .providerAudit(let detail, _, _): "provider:\(detail.eventId)"
        }
    }

    var title: String {
        switch self {
        case .instructions: "Instructions"
        case .messages: "Conversation"
        case .attachments: "Attachments"
        case .environment: "Environment"
        case .tools: "Tool Surface"
        case .automatic(let evaluation):
            evaluation.kind == "continuity" ? "Continuity" : "Worker Inbox"
        case .providerAudit: "Provider Request"
        }
    }
}

struct SessionContextDetailSheet: View {
    let selection: SessionContextDetailSelection

    @State private var rawJSONSelection: SessionContextRawJSONSelection?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    detailContent
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: selection.title, color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
        .sheet(item: $rawJSONSelection) { selection in
            SessionContextRawJSONSheet(selection: selection)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .instructions(let contributions):
            if contributions.isEmpty {
                emptyState("No instruction manifest is available for this request.")
            } else {
                ForEach(contributions) { contribution in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(contribution.label)
                                .font(TronTypography.sans(
                                    size: TronTypography.sizeBody,
                                    weight: .semibold
                                ))
                            Spacer()
                            Text(ByteCountFormatter.string(
                                fromByteCount: Int64(contribution.byteCount),
                                countStyle: .memory
                            ))
                            .font(TronTypography.pillValue)
                            .foregroundStyle(.tronEmerald)
                        }
                        Text(contribution.content)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextSecondary)
                            .textSelection(.enabled)
                        auditIdentifier("Digest", contribution.sha256)
                    }
                    .padding(14)
                    .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: false)
                }
            }

        case .messages(let messages):
            messageCards(messages, empty: "No provider-visible messages were recorded.")

        case .attachments(let messages):
            messageCards(messages, empty: "This request contained no image or document projections.")

        case .environment(let environment):
            if let environment {
                SettingsSectionHeader(title: "Provider environment", bottomPadding: 4)
                VStack(spacing: 0) {
                    metadataRow(
                        "Working directory",
                        environment.workingDirectory ?? "Not supplied"
                    )
                    Divider().opacity(0.35)
                    metadataRow("Server route", environment.serverOrigin ?? "Not supplied")
                    Divider().opacity(0.35)
                    metadataRow("Digest", environment.sha256, code: true)
                }
                .padding(.horizontal, 13)
                .sectionFill(.tronAmber, cornerRadius: 12, subtle: true, interactive: false)
            } else {
                emptyState("Environment provenance is unavailable for this request.")
            }

        case .tools(let fixed, let workers, let raw):
            let selectedFixed = fixed.filter(\.projected)
            let omittedFixed = fixed.filter { !$0.projected }
            let selected = workers.filter(\.projected)
            let omitted = workers.filter { !$0.projected }
            let summary = SessionContextPresentation.toolSummary(
                fixed: fixed,
                workers: workers
            )
            SettingsSectionHeader(title: "Tools available for this request", bottomPadding: 4)
            HStack(spacing: 0) {
                toolMetric(label: "Fixed", value: summary.fixedAvailable)
                Divider().frame(height: 32)
                toolMetric(label: "Workers", value: summary.workersAvailable)
                Divider().frame(height: 32)
                toolMetric(label: "Omitted", value: summary.omitted)
            }
            .padding(13)
            .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)

            SettingsSectionHeader(title: "Selected fixed tools", bottomPadding: 4)
            fixedToolSelectionCards(
                selectedFixed,
                empty: "No fixed tools were selected for this request."
            )
            SettingsSectionHeader(title: "Other fixed tools", bottomPadding: 4)
            fixedToolSelectionCards(
                omittedFixed,
                empty: "No fixed tools were omitted."
            )
            SettingsSectionHeader(title: "Selected direct workers", bottomPadding: 4)
            workerSelectionCards(selected, empty: "No direct workers were selected.")
            SettingsSectionHeader(title: "Omitted direct workers", bottomPadding: 4)
            workerSelectionCards(omitted, empty: "No direct workers were omitted.")
            if let raw {
                SettingsSectionHeader(title: "Exact surface evidence", bottomPadding: 4)
                rawJSONButton(
                    title: "View exact surface JSON",
                    subtitle: "Formatted only when opened",
                    destination: .toolSurface(raw)
                )
            }

        case .automatic(let evaluation):
            SettingsSectionHeader(title: "Evaluation", bottomPadding: 4)
            VStack(spacing: 0) {
                metadataRow(
                    "Outcome",
                    WorkerConsolePresentation.displayLabel(evaluation.outcome)
                )
                Divider().opacity(0.35)
                metadataRow(
                    "Selection",
                    WorkerConsolePresentation.displayLabel(evaluation.mechanism)
                )
                Divider().opacity(0.35)
                metadataRow(
                    "Delivered as",
                    SessionContextPresentation.automaticContextChannel(evaluation)
                )
                Divider().opacity(0.35)
                metadataRow("Policy worker", evaluation.workerId ?? "No worker ran")
                Divider().opacity(0.35)
                metadataRow("Version", evaluation.workerVersion ?? "Unavailable", code: true)
                Divider().opacity(0.35)
                metadataRow("Invocation", evaluation.invocationId ?? "Unavailable", code: true)
            }
            .padding(.horizontal, 13)
            .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)

            SettingsSectionHeader(
                title: evaluation.deliveryChannel == "reference"
                    ? "Reference context"
                    : "Injected narrative",
                bottomPadding: 4
            )
            auditText(
                evaluation.narrative
                    ?? evaluation.detail
                    ?? "No narrative was injected for this request."
            )

            SettingsSectionHeader(
                title: "Sources (\(evaluation.sources.count))",
                bottomPadding: 4
            )
            if evaluation.sources.isEmpty {
                emptyState(
                    evaluation.detail
                        ?? "This evaluation recorded no source-level provenance."
                )
            } else {
                auditText(
                    SessionContextAuditFormatter.projectedJSONString(
                        AnyCodable(evaluation.sources.map(\.value))
                    )
                )
            }

        case .providerAudit(let detail, let cacheReadTokens, let cacheWriteTokens):
            let auditOverview = SessionContextAuditFormatter.providerRequestOverview(
                detail.providerAudit
            )
            SettingsSectionHeader(title: "Audit identity", bottomPadding: 4)
            VStack(spacing: 0) {
                metadataRow("Format", detail.format, code: true)
                Divider().opacity(0.35)
                metadataRow("Sequence", "\(detail.sequence)")
                Divider().opacity(0.35)
                metadataRow("Timestamp", detail.timestamp)
                Divider().opacity(0.35)
                metadataRow(
                    "Provenance",
                    WorkerConsolePresentation.displayLabel(detail.provenanceAvailability)
                )
            }
            .padding(.horizontal, 13)
            .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)

            SettingsSectionHeader(title: "Session cache activity", bottomPadding: 4)
            VStack(spacing: 0) {
                metadataRow(
                    "Read",
                    "\(TokenFormatter.format(cacheReadTokens)) tokens"
                )
                Divider().opacity(0.35)
                metadataRow(
                    "Written",
                    "\(TokenFormatter.format(cacheWriteTokens)) tokens"
                )
            }
            .padding(.horizontal, 13)
            .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)

            if let cache = detail.contextManifest?.cacheLayout {
                SettingsSectionHeader(title: "Cache layout", bottomPadding: 4)
                VStack(spacing: 0) {
                    metadataRow(
                        "Stable instructions",
                        formattedBytes(cache.stableInstructionBytes)
                    )
                    Divider().opacity(0.35)
                    metadataRow("Instruction digest", cache.stableInstructionSha256, code: true)
                    Divider().opacity(0.35)
                    metadataRow(
                        "Fixed tools",
                        "\(cache.fixedToolCount) · \(formattedBytes(cache.fixedToolSchemaBytes))"
                    )
                    Divider().opacity(0.35)
                    metadataRow("Fixed prefix digest", cache.fixedToolPrefixSha256, code: true)
                    Divider().opacity(0.35)
                    metadataRow(
                        "Dynamic tools",
                        "\(cache.dynamicToolCount) · \(formattedBytes(cache.dynamicToolSchemaBytes))"
                    )
                    Divider().opacity(0.35)
                    metadataRow("Dynamic digest", cache.dynamicToolsSha256, code: true)
                    Divider().opacity(0.35)
                    metadataRow(
                        "Reference context",
                        formattedBytes(cache.requestContextBytes)
                    )
                    if let digest = cache.requestContextSha256 {
                        Divider().opacity(0.35)
                        metadataRow("Reference digest", digest, code: true)
                    }
                }
                .padding(.horizontal, 13)
                .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)
            }

            SettingsSectionHeader(title: "Redacted provider request", bottomPadding: 4)
            VStack(spacing: 0) {
                metadataRow(
                    "Envelope",
                    WorkerConsolePresentation.displayLabel(auditOverview.requestKind)
                )
                Divider().opacity(0.35)
                metadataRow(
                    "Messages",
                    auditOverview.messageCount.map(String.init) ?? "Unavailable"
                )
                Divider().opacity(0.35)
                metadataRow(
                    "Tools",
                    auditOverview.toolCount.map(String.init) ?? "Unavailable"
                )
            }
            .padding(.horizontal, 13)
            .sectionFill(.tronTextMuted, cornerRadius: 12, subtle: true, interactive: false)

            rawJSONButton(
                title: "View redacted JSON",
                subtitle: "Formatted only when opened",
                destination: .providerAudit(detail.providerAudit)
            )
        }
    }

    @ViewBuilder
    private func messageCards(
        _ messages: [ContextMessageManifestDTO],
        empty: String
    ) -> some View {
        if messages.isEmpty {
            emptyState(empty)
        } else {
            ForEach(messages) { message in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("\(message.ordinal + 1). \(WorkerConsolePresentation.displayLabel(message.role))")
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBodySM,
                                weight: .semibold
                            ))
                            .foregroundStyle(.tronTextPrimary)
                        Spacer()
                        Text(message.contentKinds.joined(separator: " · "))
                            .font(TronTypography.pillValue)
                            .foregroundStyle(.tronCyan)
                    }
                    if let preview = message.preview, !preview.isEmpty {
                        Text(preview)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextSecondary)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Text(WorkerConsolePresentation.displayLabel(
                            message.sourceKind ?? message.projection
                        ))
                        Spacer()
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(message.byteCount),
                            countStyle: .memory
                        ))
                    }
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    if !message.sourceEventIds.isEmpty {
                        auditIdentifier(
                            "Source events",
                            message.sourceEventIds.joined(separator: ", ")
                        )
                    }
                    if let invocationId = message.invocationId {
                        auditIdentifier("Invocation", invocationId)
                    }
                    auditIdentifier("Digest", message.sha256)
                }
                .padding(13)
                .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)
            }
        }
    }

    @ViewBuilder
    private func fixedToolSelectionCards(
        _ tools: [SessionContextFixedToolSelection],
        empty: String
    ) -> some View {
        if tools.isEmpty {
            emptyState(empty)
        } else {
            ForEach(tools) { tool in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(WorkerConsolePresentation.displayLabel(tool.modelName))
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBodySM,
                                weight: .semibold
                            ))
                        Spacer()
                        Text(tool.projected ? "Available" : "Not shown")
                            .font(TronTypography.pillValue)
                            .foregroundStyle(tool.projected ? .tronEmerald : .tronTextMuted)
                    }
                    Text(
                        [
                            tool.audience.map(WorkerConsolePresentation.displayLabel),
                            tool.accessPath.map(WorkerConsolePresentation.displayLabel),
                            (tool.projected ? tool.selectionReason : tool.omissionReason)
                                .map(WorkerConsolePresentation.displayLabel),
                        ]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                    )
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    auditIdentifier("Function", tool.functionId)
                }
                .padding(13)
                .sectionFill(
                    tool.projected ? .tronEmerald : .tronTextMuted,
                    cornerRadius: 12,
                    subtle: true,
                    interactive: false
                )
            }
        }
    }

    @ViewBuilder
    private func workerSelectionCards(
        _ workers: [SessionContextWorkerSelection],
        empty: String
    ) -> some View {
        if workers.isEmpty {
            emptyState(empty)
        } else {
            ForEach(workers) { worker in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(WorkerConsolePresentation.displayLabel(worker.modelName))
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBodySM,
                                weight: .semibold
                            ))
                        Spacer()
                        if worker.score > 0 {
                            Text("\(worker.score)")
                                .font(TronTypography.pillValue)
                                .foregroundStyle(worker.projected
                                    ? .tronEmerald
                                    : .tronTextMuted)
                                .accessibilityLabel("Relevance score \(worker.score)")
                        }
                        Text(worker.projected ? "Selected" : "Omitted")
                            .font(TronTypography.pillValue)
                            .foregroundStyle(worker.projected ? .tronEmerald : .tronTextMuted)
                    }
                    Text(
                        WorkerConsolePresentation.displayLabel(
                            worker.explanation
                                ?? worker.selectionReason
                                ?? worker.omissionReason
                                ?? worker.mechanism
                                ?? "Unavailable"
                        )
                    )
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    auditIdentifier("Worker", worker.workerId)
                }
                .padding(13)
                .sectionFill(
                    worker.projected ? .tronEmerald : .tronTextMuted,
                    cornerRadius: 12,
                    subtle: true,
                    interactive: false
                )
            }
        }
    }

    private func toolMetric(label: String, value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
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

    private func rawJSONButton(
        title: String,
        subtitle: String,
        destination: SessionContextRawJSONSelection
    ) -> some View {
        Button {
            rawJSONSelection = destination
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "curlybraces.square")
                    .foregroundStyle(.tronTextMuted)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(TronTypography.sans(
                            size: TronTypography.sizeBody,
                            weight: .semibold
                        ))
                        .foregroundStyle(.tronTextPrimary)
                    Text(subtitle)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
                Spacer()
            }
            .padding(13)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .sectionFill(.tronTextMuted, cornerRadius: 12, subtle: true, interactive: true)
    }

    private func emptyState(_ text: String) -> some View {
        Label(text, systemImage: "minus.circle")
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronTextMuted)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sectionFill(.tronTextMuted, cornerRadius: 12, subtle: true, interactive: false)
    }

    private func auditText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: TronTypography.sizeCaption, design: .monospaced))
            .foregroundStyle(.tronTextSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .sectionFill(.tronTextMuted, cornerRadius: 12, subtle: true, interactive: false)
    }

    private func metadataRow(_ label: String, _ value: String, code: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
            Spacer()
            Text(value)
                .font(code
                    ? .system(size: TronTypography.sizeCaption, design: .monospaced)
                    : TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 10)
    }

    private func auditIdentifier(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: TronTypography.sizeCaption, design: .monospaced))
        .foregroundStyle(.tronTextMuted)
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
