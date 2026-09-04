import SwiftUI

enum InboundProducerPresentationPolicy {
    static func title(for origin: ChatOrigin?) -> String {
        if let title = origin?.title, !title.isEmpty { return title }
        switch origin?.kind {
        case .user: return "User"
        case .subagent: return "Subagent"
        case .process: return "Process"
        case .extension: return "Extension"
        case .gateway: return "Tron"
        case .assistant: return "Assistant"
        case .unknown, nil: return "Unknown source"
        }
    }

    static func messageType(_ customType: String?) -> String {
        guard let customType, !customType.isEmpty else { return "Custom message" }
        return ComposerResourceNameFormatter.friendly(customType)
    }

    static func compactTitle(for origin: ChatOrigin?) -> String {
        guard let origin, origin.kind != .unknown else {
            return ChatSemanticPillRole.context.label
        }
        return "\(title(for: origin)) · \(ChatSemanticPillRole.context.label)"
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

/// A canonical model prompt admitted by a Gateway-owned Automation. It remains
/// a visible chat turn, but its receipt-backed producer is distinct from the
/// person using the session.
struct AutomationPromptMessageView: View {
    let item: TranscriptItem

    private var promptText: String? {
        AutomationPromptPresentationPolicy.visibleText(item)
    }

    private var accessibilitySummary: String {
        promptText.map { "Automation prompt: \($0)" } ?? "Automation prompt"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .bold))
                    .accessibilityHidden(true)
                Text(AutomationPromptPresentationPolicy.originTitle.uppercased())
                    .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .bold))
            }
            .foregroundStyle(Color.tronAutomation)

            if let resource = item.semantic?.resourceInvocation {
                CanonicalResourceChip(resource: resource)
            }
            if let promptText {
                UserPromptText(text: promptText)
            }
        }
        .padding(.horizontal, ChatPromptContainerStyle.horizontalPadding)
        .padding(.top, ChatPromptContainerStyle.topPadding)
        .padding(.bottom, ChatPromptContainerStyle.userPromptBottomPadding)
        .modifier(UserPromptGlassModifier(accent: .tronAutomation))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
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
    static func status(details: JSONValue?) -> String {
        guard let object = details?.objectValue else { return "Received" }
        var values: [String] = []
        for candidate in [object["status"]?.stringValue, object["state"]?.stringValue] {
            if let candidate, !candidate.isEmpty { values.append(candidate) }
        }
        for key in object.keys.sorted() {
            guard let nested = object[key]?.objectValue else { continue }
            for candidate in [nested["status"]?.stringValue, nested["state"]?.stringValue] {
                if let candidate, !candidate.isEmpty { values.append(candidate) }
            }
        }
        let admitted = Set(values.compactMap(standardStatus))
        guard admitted.count == 1, let status = admitted.first else { return "Received" }
        return status
    }

    private static func standardStatus(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "active": return "Active"
        case "running", "in_progress", "working": return "In Progress"
        case "pending": return "Pending"
        case "queued": return "Queued"
        case "complete", "completed", "finished", "success", "succeeded": return "Completed"
        case "failed", "error": return "Failed"
        case "blocked": return "Blocked"
        case "paused": return "Paused"
        case "cancelled", "canceled", "interrupted": return "Cancelled"
        case "warning": return "Warning"
        case "received": return "Received"
        default: return nil
        }
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
        InboundProducerPresentationPolicy.title(for: item.semantic?.origin)
    }

    private var status: String {
        InboundContextCompactPresentationPolicy.status(details: item.details)
    }

    private var durationMilliseconds: Int? {
        InboundContextCompactPresentationPolicy.durationMilliseconds(details: item.details)
    }

    private var tone: ChatNotificationTone {
        InboundProducerPresentationPolicy.tone(for: item.semantic?.origin.kind)
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
                    title: InboundProducerPresentationPolicy.compactTitle(for: item.semantic?.origin),
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
        .accessibilityLabel("\(originTitle) context, \(status)")
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

    private var accent: Color {
        InboundProducerPresentationPolicy.tone(for: item.semantic?.origin.kind).surfaceColor
    }

    private var originTitle: String {
        InboundProducerPresentationPolicy.title(for: item.semantic?.origin)
    }

    private var messageText: String {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "No text content" : text
    }

    private var originMetadata: [TronTechnicalMetadataItem] {
        [
            .init(title: "Producer", value: originTitle, icon: "puzzlepiece.extension"),
            .init(title: "Message type", value: InboundProducerPresentationPolicy.messageType(item.customType), icon: "doc.badge.ellipsis"),
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
                            accent: accent
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
                    TronSheetTitle(title: "Context details", accent: accent)
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
