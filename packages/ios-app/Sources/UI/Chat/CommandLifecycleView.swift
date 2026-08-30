import SwiftUI

/// Canonical invocation receipt presentation. This is an ambient command
/// record, not a user prompt bubble; its physical identity is the receipt ID.
struct CommandLifecycleView: View {
    let item: TranscriptItem
    @State private var showingDetails = false

    private var resource: ComposerResourceInvocation? { item.semantic?.resourceInvocation }
    private var name: String { resource?.name ?? "Extension command" }
    private var commandLabel: String {
        let arguments = resource?.arguments ?? ""
        guard !arguments.isEmpty else { return "/\(name)" }
        let bounded = String(arguments.prefix(72))
        return "/\(name) \(bounded)\(arguments.count > bounded.count ? "…" : "")"
    }
    private var state: String { item.semantic?.lifecycle?.rawValue ?? "accepted" }
    private var origin: String {
        item.semantic?.origin.title
            ?? item.semantic?.origin.kind.rawValue.capitalized
            ?? "Extension"
    }
    private var tone: ChatNotificationTone {
        switch state {
        case "failed", "interrupted": return .error
        case "completed": return .accent
        case "outcomeUnknown": return .warning
        default: return .neutral
        }
    }

    var body: some View {
        Button { showingDetails = true } label: {
            ChatCompactPillSurface(tone: tone, material: .glass, interactive: true) {
                ChatCompactPillLabel(
                    icon: "command",
                    title: "\(origin) · \(commandLabel)",
                    detail: ComposerResourceNameFormatter.friendly(state),
                    tone: tone,
                    iconSize: ChatCompactPillLayoutPolicy.toolIconSize,
                    titleWeight: .bold
                )
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityLabel("\(origin) command \(commandLabel), \(state)")
        .accessibilityHint("Shows command details")
        .sheet(isPresented: $showingDetails) {
            CommandLifecycleDetailsSheet(item: item)
        }
    }
}

private struct CommandLifecycleDetailsSheet: View {
    let item: TranscriptItem
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .medium

    private var resource: ComposerResourceInvocation? { item.semantic?.resourceInvocation }
    private var name: String { resource?.name ?? "Extension command" }
    private var origin: String {
        item.semantic?.origin.title
            ?? item.semantic?.origin.kind.rawValue.capitalized
            ?? "Extension"
    }
    private var arguments: String {
        let value = resource?.arguments ?? ""
        return value.isEmpty ? "No arguments" : value
    }
    private var metadata: [TronTechnicalMetadataItem] {
        [
            .init(title: "Command", value: "/\(name)", icon: "command"),
            .init(
                title: "Lifecycle",
                value: ComposerResourceNameFormatter.friendly(item.semantic?.lifecycle?.rawValue ?? "accepted"),
                icon: "clock.arrow.circlepath"
            ),
            .init(title: "Source", value: origin, icon: "shippingbox"),
            .init(title: "Origin", value: item.semantic?.origin.kind.rawValue ?? "unknown", icon: "externaldrive"),
        ]
    }
    private var identity: [TronTechnicalMetadataItem] {
        [
            .init(title: "Invocation", value: item.semantic?.invocationId ?? "Unavailable", icon: "point.3.connected.trianglepath.dotted"),
            .init(title: "Operation", value: item.semantic?.operationId ?? "Unavailable", icon: "number"),
            .init(title: "Entry", value: item.id, icon: "doc.text"),
            .init(title: "Timestamp", value: item.timestamp, icon: "clock"),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TronSpacing.section) {
                    VStack(alignment: .leading, spacing: TronSpacing.sm) {
                        TronTechnicalSectionLabel("Arguments")
                        TronMarkdownView(text: arguments, streaming: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(TronSpacing.lg)
                            .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.08)
                        Text("Arguments are passed exactly to the extension and may be case-sensitive.")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                            .foregroundStyle(Color.tronTextSecondary)
                    }
                    TronTechnicalMetadataSection(title: "Command", items: metadata, accent: .tronEmerald)
                    TronTechnicalMetadataSection(title: "Canonical identity", items: identity, accent: .tronSlate)
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
                    TronSheetTitle(title: "Command details", accent: .tronEmerald)
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
}
