import SwiftUI

enum InboundProducerPresentationPolicy {
    static func label(for origin: ChatOriginKind?) -> String {
        switch origin {
        case .subagent: return "Subagent"
        case .process: return "Process"
        case .extension: return "Extension"
        case .user: return "User"
        case .gateway: return "Tron"
        case .assistant: return "Assistant"
        case .unknown, nil: return "Context"
        }
    }

    static func title(for origin: ChatOrigin?, customType: String?) -> String {
        if let title = origin?.title, !title.isEmpty { return title }
        if let customType, !customType.isEmpty {
            return ComposerResourceNameFormatter.friendly(customType)
        }
        return "Unattributed"
    }

    static func tone(for origin: ChatOriginKind?) -> ChatNotificationTone {
        switch origin {
        case .subagent, .process: return .information
        case .user: return .accent
        case .extension: return .purple
        case .gateway, .assistant, .unknown, nil: return .neutral
        }
    }

    static func deliveryLabel(for delivery: ChatDelivery?) -> String {
        switch delivery {
        case .stored: return "Stored for model context"
        case .nextTurn: return "Delivered on the next turn"
        case .steer: return "Steered the active turn"
        case .followUp: return "Queued as a follow-up"
        case .triggeredTurn: return "Triggered an agent turn"
        case .continuedTurn: return "Continued the agent turn"
        case .beforeAgentStart: return "Delivered before agent start"
        case .toolResult: return "Delivered as a tool result"
        case .unknown, nil: return "Unknown"
        }
    }
}

struct InboundContextGoalPresentation: Equatable {
    let objective: String
    let status: String
    let tokensUsed: Int?
    let tokenBudget: Int?
    let timeUsedSeconds: Int?

    static func project(_ details: JSONValue?) -> Self? {
        guard let goal = details?.objectValue?["goal"]?.objectValue,
              let objective = goal["objective"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !objective.isEmpty else { return nil }
        return Self(
            objective: objective,
            status: ComposerResourceNameFormatter.friendly(goal["status"]?.stringValue ?? "unknown"),
            tokensUsed: goal["tokensUsed"]?.intValue,
            tokenBudget: goal["tokenBudget"]?.intValue,
            timeUsedSeconds: goal["timeUsedSeconds"]?.intValue
        )
    }

    var compactStatus: String { "\(status) · \(objective)" }

    var metadata: [TronTechnicalMetadataItem] {
        var values = [
            TronTechnicalMetadataItem(title: "Objective", value: objective, icon: "scope"),
            TronTechnicalMetadataItem(title: "Status", value: status, icon: "checkmark.circle"),
        ]
        if let tokensUsed {
            values.append(.init(title: "Tokens used", value: tokensUsed.formatted(), icon: "number"))
        }
        if let tokenBudget {
            values.append(.init(title: "Token budget", value: tokenBudget.formatted(), icon: "gauge.with.dots.needle.33percent"))
        }
        if let timeUsedSeconds {
            let boundedSeconds = max(0, min(timeUsedSeconds, Int.max / 1_000))
            values.append(.init(
                title: "Time used",
                value: ToolTiming.format(milliseconds: boundedSeconds * 1_000),
                icon: "clock"
            ))
        }
        return values
    }
}

enum InboundContextCompactPresentationPolicy {
    static func status(details: JSONValue?, message: String) -> String {
        let supplied = details?.objectValue?["status"]?.stringValue
            ?? details?.objectValue?["state"]?.stringValue
        if let supplied, !supplied.isEmpty {
            return ComposerResourceNameFormatter.friendly(supplied)
        }
        let normalized = message.lowercased()
        if normalized.contains("failed") || normalized.contains("error") { return "Failed" }
        if normalized.contains("completed") || normalized.contains("finished") { return "Completed" }
        return "Message"
    }

    static func durationMilliseconds(details: JSONValue?) -> Int? {
        let object = details?.objectValue
        let value = object?["durationMs"]?.intValue ?? object?["elapsedMs"]?.intValue
        return value.map { max(0, $0) }
    }
}

/// A producer-authored message delivered into the mounted session's agent
/// context. Inbound context is always trailing; provenance changes its tone and
/// label but never changes direction.
struct InboundProducerMessageView: View {
    let item: TranscriptItem
    @State private var showingDetails = false

    private var originTitle: String {
        InboundProducerPresentationPolicy.title(
            for: item.semantic?.origin,
            customType: item.customType
        )
    }

    private var messageText: String {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "No text content" : text
    }

    private var status: String {
        if let goal = InboundContextGoalPresentation.project(item.details) {
            return goal.compactStatus
        }
        return InboundContextCompactPresentationPolicy.status(
            details: item.details,
            message: messageText
        )
    }

    private var durationMilliseconds: Int? {
        InboundContextCompactPresentationPolicy.durationMilliseconds(details: item.details)
    }

    private var tone: ChatNotificationTone {
        InboundProducerPresentationPolicy.tone(for: item.semantic?.origin.kind)
    }

    private var originLabel: String {
        InboundProducerPresentationPolicy.label(for: item.semantic?.origin.kind)
    }

    var body: some View {
        Button { showingDetails = true } label: {
            ChatCompactPillSurface(
                tone: tone,
                material: .glass,
                interactive: true,
                cornerRadiusOverride: ChatToolChipShapePolicy.cornerRadius
            ) {
                ChatCompactPillLabel(
                    icon: "arrow.down.message.fill",
                    title: "\(originLabel) · \(originTitle)",
                    detail: status,
                    tone: tone,
                    iconSize: ChatCompactPillLayoutPolicy.toolIconSize,
                    titleWeight: .bold
                ) {
                    if let durationMilliseconds {
                        Text(ToolTiming.format(milliseconds: durationMilliseconds))
                            .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(tone.secondaryColor)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Inbound context from \(originLabel), \(originTitle), \(status). \(messageText)")
        .accessibilityHint("Shows the full message and technical details")
        .tronManagedSheet(
            isPresented: $showingDetails,
            identity: "chat.inbound-context.\(item.id)"
        ) {
            InboundContextDetailsSheet(item: item)
        }
    }
}

private struct InboundContextDetailsSheet: View {
    let item: TranscriptItem
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .medium

    private let accent = Color.tronCyan

    private var originTitle: String {
        InboundProducerPresentationPolicy.title(
            for: item.semantic?.origin,
            customType: item.customType
        )
    }

    private var messageText: String {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "No text content" : text
    }

    private var originMetadata: [TronTechnicalMetadataItem] {
        [
            .init(title: "Source", value: originTitle, icon: "doc.badge.ellipsis"),
            .init(title: "Origin", value: item.semantic?.origin.kind.rawValue ?? "unknown", icon: "externaldrive"),
            .init(title: "Confidence", value: item.semantic?.origin.confidence.rawValue ?? "unknown", icon: "checkmark.shield"),
            .init(
                title: "Delivery",
                value: InboundProducerPresentationPolicy.deliveryLabel(for: item.semantic?.delivery),
                icon: "arrow.turn.down.right"
            ),
        ]
    }

    private var goalMetadata: [TronTechnicalMetadataItem]? {
        InboundContextGoalPresentation.project(item.details)?.metadata
    }

    private var canonicalMetadata: [TronTechnicalMetadataItem] {
        [
            .init(title: "Entry", value: item.id, icon: "number"),
            .init(title: "Timestamp", value: item.timestamp, icon: "clock"),
        ]
    }

    private var contentPayload: JSONValue {
        (try? JSONValue.encode(item.content ?? [])) ?? .array([])
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TronSpacing.section) {
                    messageSection
                    if let goalMetadata {
                        TronTechnicalMetadataSection(
                            title: "Goal",
                            items: goalMetadata,
                            accent: .tronPurple
                        )
                    }
                    TronTechnicalMetadataSection(
                        title: "Origin",
                        items: originMetadata,
                        accent: accent
                    )
                    TronTechnicalMetadataSection(
                        title: "Canonical identity",
                        items: canonicalMetadata,
                        accent: .tronSlate
                    )
                    if let details = item.details {
                        payloadSection(
                            "Context details",
                            value: details,
                            sheetTitle: "Context details"
                        )
                    }
                    payloadSection(
                        "Content payload",
                        value: contentPayload,
                        sheetTitle: "Content payload"
                    )
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .tronScrollEdgeChrome()
            .tronToolDetailNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Session message", accent: accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.toolDetail)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tronPresentation()
    }

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            TronTechnicalSectionLabel("Message")
            TronMarkdownView(text: messageText, streaming: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TronSpacing.lg)
                .tronGlassSurface(accent: accent, tintOpacity: 0.08)
        }
    }

    private func payloadSection(
        _ title: String,
        value: JSONValue,
        sheetTitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            TronTechnicalSectionLabel(title)
            TronTechnicalJSONRow(
                value: value,
                title: "Inspect \(title.lowercased())",
                subtitle: ToolTechnicalPayloadSummary.summary(for: value),
                sheetTitle: sheetTitle,
                accent: accent
            )
        }
    }
}
