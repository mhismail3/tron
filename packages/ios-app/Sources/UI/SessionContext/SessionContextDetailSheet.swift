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
    case providerAudit(SessionContextRequestDetailDTO)

    var id: String {
        switch self {
        case .instructions: "instructions"
        case .messages: "messages"
        case .attachments: "attachments"
        case .environment: "environment"
        case .tools: "tools"
        case .automatic(let evaluation): "automatic:\(evaluation.id)"
        case .providerAudit(let detail): "provider:\(detail.eventId)"
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
                auditText(SessionContextAuditFormatter.projectedJSONString(raw))
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
                metadataRow("Policy worker", evaluation.workerId ?? "No worker ran")
                Divider().opacity(0.35)
                metadataRow("Version", evaluation.workerVersion ?? "Unavailable", code: true)
                Divider().opacity(0.35)
                metadataRow("Invocation", evaluation.invocationId ?? "Unavailable", code: true)
            }
            .padding(.horizontal, 13)
            .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)

            SettingsSectionHeader(title: "Injected narrative", bottomPadding: 4)
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

        case .providerAudit(let detail):
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

            SettingsSectionHeader(title: "Redacted provider request", bottomPadding: 4)
            auditText(SessionContextAuditFormatter.projectedJSONString(detail.providerAudit))
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
}
