import SwiftUI

enum SessionInputCompactPresentationPolicy {
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

/// A producer-authored message delivered into the mounted session's agent turn.
/// This is conversation input, not a tool invocation, so it shares the trailing
/// edge with user and steering messages while retaining distinct provenance.
struct SessionInputMessageView: View {
    let item: TranscriptItem
    @State private var showingDetails = false

    private var originTitle: String {
        item.sessionInput?.origin?.owner?.title ?? "Extension message"
    }

    private var messageText: String {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "No text content" : text
    }

    private var status: String {
        SessionInputCompactPresentationPolicy.status(
            details: item.details,
            message: messageText
        )
    }

    private var durationMilliseconds: Int? {
        SessionInputCompactPresentationPolicy.durationMilliseconds(details: item.details)
    }

    private var tone: ChatNotificationTone {
        status == "Failed" ? .error : status == "Completed" ? .accent : .information
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
                    title: originTitle,
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
        .accessibilityLabel("Message from \(originTitle), \(status). \(messageText)")
        .accessibilityHint("Shows the full message and technical details")
        .sheet(isPresented: $showingDetails) {
            SessionInputDetailsSheet(item: item)
        }
    }
}

private struct SessionInputDetailsSheet: View {
    let item: TranscriptItem
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .medium

    private let accent = Color.tronCyan

    private var origin: ExtensionToolOrigin? { item.sessionInput?.origin }

    private var messageText: String {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "No text content" : text
    }

    private var originMetadata: [TronTechnicalMetadataItem] {
        [
            .init(title: "Extension", value: origin?.owner?.title ?? "Unknown extension", icon: "puzzlepiece.extension"),
            .init(title: "Source", value: origin?.source ?? "Not attributed", icon: "externaldrive"),
            .init(title: "Custom type", value: item.customType ?? "Unknown", icon: "tag"),
            .init(title: "Delivery", value: "Triggered an agent turn", icon: "arrow.turn.down.right"),
        ]
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
                            "Producer details",
                            value: details,
                            sheetTitle: "Producer details"
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
