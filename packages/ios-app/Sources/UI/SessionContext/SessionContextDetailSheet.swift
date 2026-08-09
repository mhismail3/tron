import Foundation
import SwiftUI

enum SessionContextDetailSelection: Identifiable, Equatable {
    case agentContext(SessionContextRequestDetailDTO)
    case technical(
        SessionContextRequestDetailDTO,
        cacheReadTokens: Int,
        cacheWriteTokens: Int
    )

    var id: String {
        switch self {
        case .agentContext(let detail): "context:\(detail.eventId)"
        case .technical(let detail, _, _): "technical:\(detail.eventId)"
        }
    }

    var title: String {
        switch self {
        case .agentContext: "Agent Context"
        case .technical: "Technical Details"
        }
    }
}

/// Progressive-disclosure detail for one immutable provider request.
///
/// `Agent Context` is deliberately product-facing. Exact identifiers,
/// digests, redacted environment values, and raw envelopes are consolidated
/// under `Technical Details` instead of leaking into every content card.
struct SessionContextDetailSheet: View {
    let selection: SessionContextDetailSelection
    var models: [ModelInfo] = []

    @State private var rawJSONSelection: SessionContextRawJSONSelection?
    @State private var expandedDeliveryIds: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    detailContent
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .containerRelativeFrame(.horizontal)
                .clipped()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
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
        case .agentContext(let detail):
            agentContext(detail)
        case .technical(let detail, let cacheReadTokens, let cacheWriteTokens):
            technicalDetails(
                detail,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens
            )
        }
    }

    @ViewBuilder
    private func agentContext(_ detail: SessionContextRequestDetailDTO) -> some View {
        let manifest = detail.contextManifest
        let contributions = (manifest?.systemContributions ?? [])
            + (detail.providerAdditions ?? [])
        let messages = manifest?.messages ?? []
        let attachments = messages.filter {
            $0.contentKinds.contains("image") || $0.contentKinds.contains("document")
        }
        let fixedToolSelections = SessionContextPresentation.fixedToolSelections(
            from: manifest?.toolSurface
        )
        let workerSelections = SessionContextPresentation.workerSelections(
            from: manifest?.toolSurface
        )
        let toolSummary = SessionContextPresentation.toolSummary(
            fixed: fixedToolSelections,
            workers: workerSelections
        )
        let fixedTools = fixedToolSelections.filter(\.projected)
        let workers = workerSelections.filter(\.projected)

        contextSection(title: "Instructions") {
            if contributions.isEmpty {
                emptyState("No instructions were recorded for this request.")
            } else {
                ForEach(contributions) { contribution in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(contribution.label)
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBody,
                                weight: .semibold
                            ))
                            .foregroundStyle(.tronTextPrimary)
                        Text(contribution.content)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextSecondary)
                            .textSelection(.enabled)
                    }
                    .padding(14)
                    .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: false)
                }
            }
        }

        contextSection(title: "Conversation") {
            messageCards(messages, empty: "No provider-visible messages were recorded.")
        }

        contextSection(title: "Background updates") {
            let deliveries = manifest?.agentDeliveries ?? []
            if deliveries.isEmpty {
                emptyState(
                    "No background worker or agent updates were included in this request. "
                        + "Ordinary messages and question answers appear in Conversation."
                )
            } else {
                ForEach(deliveries) { delivery in
                    includedDeliveryCard(delivery)
                }
            }
        }

        if !attachments.isEmpty {
            contextSection(title: "Attachments & documents") {
                messageCards(attachments, empty: "No attachments were included.")
            }
        }

        contextSection(title: "Available tools") {
            if fixedTools.isEmpty, workers.isEmpty {
                emptyState("No tools were available to the agent for this request.")
            } else {
                Text(
                    "\(toolSummary.fixedAvailable) core "
                        + (toolSummary.fixedAvailable == 1 ? "tool" : "tools")
                        + " · \(toolSummary.workersAvailable) "
                        + (toolSummary.workersAvailable == 1 ? "worker" : "workers")
                )
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)

                ForEach(fixedTools) { tool in
                    capabilityCard(
                        title: WorkerConsolePresentation.displayLabel(tool.modelName),
                        detail: tool.selectionReason.map(WorkerConsolePresentation.displayLabel),
                        symbol: "wrench.and.screwdriver"
                    )
                }
                ForEach(workers) { worker in
                    capabilityCard(
                        title: WorkerConsolePresentation.displayLabel(worker.modelName),
                        detail: (worker.explanation ?? worker.selectionReason)
                            .map(WorkerConsolePresentation.displayLabel),
                        symbol: "person.2"
                    )
                }
            }
        }

        if let evaluations = manifest?.automaticContext, !evaluations.isEmpty {
            contextSection(title: "Continuity & memory") {
                ForEach(evaluations) { evaluation in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(evaluation.kind == "continuity" ? "Continuity" : "Worker results")
                                .font(TronTypography.sans(
                                    size: TronTypography.sizeBodySM,
                                    weight: .semibold
                                ))
                            Spacer()
                            Text(SessionContextPresentation.automaticContextChannel(evaluation))
                                .font(TronTypography.pillValue)
                                .foregroundStyle(.tronCyan)
                        }
                        Text(
                            evaluation.narrative
                                ?? evaluation.detail
                                ?? "No additional narrative was included."
                        )
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .textSelection(.enabled)
                    }
                    .padding(13)
                    .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)
                }
            }
        }
    }

    @ViewBuilder
    private func technicalDetails(
        _ detail: SessionContextRequestDetailDTO,
        cacheReadTokens: Int,
        cacheWriteTokens: Int
    ) -> some View {
        let manifest = detail.contextManifest
        let auditOverview = SessionContextAuditFormatter.providerRequestOverview(
            detail.providerAudit
        )

        technicalSection(title: "Audit identity") {
            metadataContainer(.tronEmerald) {
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
        }

        technicalSection(title: "Provider-visible environment") {
            Text(
                "Filesystem paths and server origins are redacted before this durable audit is "
                    + "stored, so personal paths and connection details cannot leak into logs or exports."
            )
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronTextMuted)
            .fixedSize(horizontal: false, vertical: true)

            if let environment = manifest?.environment {
                metadataContainer(.tronAmber) {
                    metadataRow("Working directory", environment.workingDirectory ?? "Not supplied")
                    Divider().opacity(0.35)
                    metadataRow("Server route", environment.serverOrigin ?? "Not supplied")
                    Divider().opacity(0.35)
                    metadataRow("Digest", environment.sha256, code: true)
                }
            } else {
                emptyState("Environment provenance is unavailable for this request.")
            }
        }

        if let manifest {
            technicalSection(title: "Integrity") {
                metadataContainer(.tronPurple) {
                    metadataRow("Instructions", manifest.systemPromptSha256, code: true)
                    Divider().opacity(0.35)
                    metadataRow("Messages", manifest.messagesSha256, code: true)
                    Divider().opacity(0.35)
                    metadataRow("Tools", manifest.toolsSha256, code: true)
                    Divider().opacity(0.35)
                    metadataRow("Complete context", manifest.contextSha256, code: true)
                }

                ForEach(manifest.systemContributions) { contribution in
                    provenanceCard(
                        title: contribution.label,
                        rows: [
                            ("Bytes", "\(contribution.byteCount)"),
                            ("Digest", contribution.sha256),
                        ]
                    )
                }
                ForEach(detail.providerAdditions ?? []) { contribution in
                    provenanceCard(
                        title: contribution.label,
                        rows: [
                            ("Bytes", "\(contribution.byteCount)"),
                            ("Digest", contribution.sha256),
                        ]
                    )
                }
            }

            technicalSection(title: "Message provenance") {
                if manifest.messages.isEmpty {
                    emptyState("No message-level provenance was recorded.")
                } else {
                    ForEach(manifest.messages) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(message.ordinal + 1). \(friendlyRole(message.role))")
                                .font(TronTypography.sans(
                                    size: TronTypography.sizeBodySM,
                                    weight: .semibold
                                ))
                            auditIdentifier("Source events", message.sourceEventIds.joined(separator: ", "))
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

            technicalSection(title: "Cache") {
                metadataContainer(.tronEmerald) {
                    metadataRow("Read", "\(TokenFormatter.format(cacheReadTokens)) tokens")
                    Divider().opacity(0.35)
                    metadataRow("Written", "\(TokenFormatter.format(cacheWriteTokens)) tokens")
                }
                if let cache = manifest.cacheLayout {
                    metadataContainer(.tronCyan) {
                        metadataRow("Stable instructions", formattedBytes(cache.stableInstructionBytes))
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
                    }
                }
            }

            technicalSection(title: "Exact tool surface") {
                rawJSONButton(
                    title: "View exact surface JSON",
                    subtitle: "Identifiers, selection evidence, and omissions",
                    destination: .toolSurface(manifest.toolSurface)
                )
            }
        }

        technicalSection(title: "Redacted provider request") {
            metadataContainer(.tronTextMuted) {
                metadataRow(
                    "Envelope",
                    WorkerConsolePresentation.displayLabel(auditOverview.requestKind)
                )
                Divider().opacity(0.35)
                metadataRow("Messages", auditOverview.messageCount.map(String.init) ?? "Unavailable")
                Divider().opacity(0.35)
                metadataRow("Tools", auditOverview.toolCount.map(String.init) ?? "Unavailable")
            }
            rawJSONButton(
                title: "View redacted JSON",
                subtitle: "The exact bounded request audit",
                destination: .providerAudit(detail.providerAudit)
            )
        }
    }

    @ViewBuilder
    private func contextSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: title, bottomPadding: 0)
            content()
        }
    }

    @ViewBuilder
    private func technicalSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: title, bottomPadding: 0)
            content()
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
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(message.ordinal + 1). \(friendlyRole(message.role))")
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBodySM,
                                weight: .semibold
                            ))
                            .foregroundStyle(.tronTextPrimary)
                        Spacer()
                        if !message.contentKinds.isEmpty {
                            Text(message.contentKinds.map(WorkerConsolePresentation.displayLabel).joined(separator: " · "))
                                .font(TronTypography.pillValue)
                                .foregroundStyle(.tronCyan)
                        }
                    }
                    if let preview = message.preview, !preview.isEmpty {
                        Text(preview)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextSecondary)
                            .textSelection(.enabled)
                    }
                    let facts = messageFacts(message)
                    if !facts.isEmpty {
                        Text(facts.joined(separator: " · "))
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                .padding(13)
                .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)
            }
        }
    }

    private func includedDeliveryCard(_ delivery: ContextAgentDeliveryDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(SessionContextPresentation.includedDeliveryTitle(
                    sourceKind: delivery.sourceKind,
                    content: delivery.content
                ))
                    .font(TronTypography.sans(
                        size: TronTypography.sizeBodySM,
                        weight: .semibold
                    ))
                Spacer()
                Text(delivery.redelivery ? "Redelivery" : "Included")
                    .font(TronTypography.pillValue)
                    .foregroundStyle(.tronEmerald)
            }
            Text(SessionContextPresentation.includedDeliverySummary(
                sourceKind: delivery.sourceKind,
                content: delivery.content
            ))
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedDeliveryIds.contains(delivery.deliveryId) },
                    set: { expanded in
                        if expanded {
                            expandedDeliveryIds.insert(delivery.deliveryId)
                        } else {
                            expandedDeliveryIds.remove(delivery.deliveryId)
                        }
                    }
                )
            ) {
                Text(delivery.content)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .textSelection(.enabled)
                    .padding(.top, 6)
            } label: {
                Text("View included content")
                    .font(TronTypography.sans(
                        size: TronTypography.sizeCaption,
                        weight: .semibold
                    ))
            }
            .tint(.tronEmerald)
        }
        .padding(13)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private func capabilityCard(title: String, detail: String?, symbol: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .foregroundStyle(.tronEmerald)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TronTypography.sans(
                        size: TronTypography.sizeBodySM,
                        weight: .semibold
                    ))
                    .foregroundStyle(.tronTextPrimary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private func messageFacts(_ message: ContextMessageManifestDTO) -> [String] {
        var facts = message.sourceModels.map {
            SessionContextPresentation.modelDisplayName(
                $0,
                models: models,
                fallback: $0.shortModelName
            )
        }
        facts.append(contentsOf: message.sourceTools.map {
            WorkerConsolePresentation.displayLabel($0)
        })
        facts.append(contentsOf: message.sourceTurns.map { "Turn \($0)" })
        if facts.isEmpty, message.projection == "compaction_summary" {
            facts.append("Compaction summary")
        }
        return facts
    }

    private func friendlyRole(_ role: String) -> String {
        switch role.lowercased() {
        case "user": "You"
        case "assistant": "Assistant"
        case "tool": "Tool result"
        case "system": "System"
        default: WorkerConsolePresentation.displayLabel(role)
        }
    }

    private func provenanceCard(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TronTypography.sans(
                    size: TronTypography.sizeBodySM,
                    weight: .semibold
                ))
            ForEach(Array(rows.enumerated()), id: \.offset) { entry in
                auditIdentifier(entry.element.0, entry.element.1)
            }
        }
        .padding(13)
        .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: false)
    }

    private func metadataContainer<Content: View>(
        _ color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 13)
            .sectionFill(color, cornerRadius: 12, subtle: true, interactive: false)
    }

    private func rawJSONButton(
        title: String,
        subtitle: String,
        destination: SessionContextRawJSONSelection
    ) -> some View {
        Button { rawJSONSelection = destination } label: {
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
            Text(value.isEmpty ? "Unavailable" : value)
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
