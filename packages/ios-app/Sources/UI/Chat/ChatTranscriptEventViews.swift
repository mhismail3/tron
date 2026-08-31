import SwiftUI

/// Shared compact visual treatment for transcript navigation actions.
/// The glass remains content-sized while the owning button supplies a separate
/// 44-point semantic target.
struct ChatTranscriptPillModifier: ViewModifier {
    func body(content: Content) -> some View {
        ChatCompactPillSurface(tone: .accent, material: .glass, interactive: true) {
            content
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronAccentText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
}

extension View {
    func chatTranscriptPill() -> some View {
        modifier(ChatTranscriptPillModifier())
    }
}

/// One visual language for transcript events that are not conversation turns.
/// Detail-bearing events are buttons with Liquid Glass; informational events
/// remain noninteractive and flat. Error notices use a rounded rectangle so
/// multiline diagnostics do not read like an oversized capsule.
struct ChatNotificationView: View {
    let presentation: ChatNotificationPresentation
    @State private var showingDetail = false

    var body: some View {
        Group {
            if presentation.hasDetailSheet {
                pill
                    .chatCompactPillInteraction(
                        accessibilityLabel: accessibilityLabel,
                        action: { showingDetail = true }
                    )
                    // Preserve the 44-point semantic row target without making
                    // its empty corners compete with the glass surface gesture.
                    .frame(minWidth: 44, minHeight: 44)
            } else {
                pill
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
        .contentTransition(.interpolate)
        .accessibilityLabel(accessibilityLabel)
        .tronManagedSheet(
            isPresented: $showingDetail,
            identity: "chat.transcript-event-detail"
        ) { detailSheet }
    }

    private var pill: some View {
        ChatCompactPillSurface(
            tone: presentation.tone,
            material: presentation.material,
            interactive: presentation.hasDetailSheet
        ) {
            ChatCompactPillLabel(
                icon: presentation.icon,
                title: presentation.title,
                detail: presentation.detail,
                tone: presentation.tone,
                showsProgress: presentation.showsProgress,
                titleWeight: .semibold,
                detailStyle: presentation.hasDetailSheet ? .summary : .status
            )
        }
    }

    private var accessibilityLabel: String {
        [presentation.title, presentation.detail].compactMap { $0 }.joined(separator: ", ")
    }

    private var detailSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let detail = presentation.detail {
                        Text(detail)
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextSecondary)
                    }
                    if let body = presentation.body {
                        TronMarkdownView(text: body, streaming: false)
                            .padding(14)
                            .tronGlassSurface(accent: presentation.tone.surfaceColor, tintOpacity: 0.08)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: presentation.title, accent: presentation.tone.surfaceColor)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { showingDetail = false } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}

struct TranscriptNotice: View {
    let title: String
    var value: String? = nil
    let icon: String
    let tone: ChatNotificationTone
    var animatesEntrance = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed: Bool

    init(
        title: String,
        value: String? = nil,
        icon: String,
        tone: ChatNotificationTone,
        animatesEntrance: Bool = false
    ) {
        self.title = title
        self.value = value
        self.icon = icon
        self.tone = tone
        self.animatesEntrance = animatesEntrance
        _revealed = State(initialValue: !animatesEntrance)
    }

    var body: some View {
        ChatNotificationView(presentation: .init(
            id: "embedded-notice", semanticID: nil, icon: icon, title: title,
            detail: value, body: nil, tone: tone, material: .flat
        ))
        .opacity(revealed ? 1 : 0)
        .scaleEffect(revealed || reduceMotion ? 1 : 0.98)
        .offset(y: revealed || reduceMotion ? 0 : 3)
        .onAppear {
            guard animatesEntrance, !revealed else { return }
            if reduceMotion { revealed = true }
            else {
                withAnimation(.smooth(duration: 0.24)) { revealed = true }
            }
        }
    }
}
