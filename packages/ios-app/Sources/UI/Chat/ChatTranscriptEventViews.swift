import SwiftUI

/// Shared compact visual treatment for transcript navigation actions.
/// The glass remains content-sized while the owning button supplies a separate
/// 44-point semantic target.
struct ChatTranscriptPillModifier: ViewModifier {
    var tone: ChatNotificationTone = .accent

    func body(content: Content) -> some View {
        ChatCompactPillSurface(tone: tone, material: .glass, interactive: true) {
            content
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(tone.primaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
}

extension View {
    func chatTranscriptPill(tone: ChatNotificationTone = .accent) -> some View {
        modifier(ChatTranscriptPillModifier(tone: tone))
    }
}

/// One visual language for transcript events that are not conversation turns.
/// Detail-bearing events are buttons with Liquid Glass; informational events
/// remain noninteractive and flat. Error notices use a rounded rectangle so
/// multiline diagnostics do not read like an oversized capsule.
struct ChatNotificationView: View {
    let presentation: ChatNotificationPresentation
    @Environment(AppModel.self) private var model
    @State private var showingDetail = false
    @State private var detailID = UUID()
    @State private var titleMeasurement: ChatCompactPillTitleMeasurement?

    private var showsDetailAction: Bool {
        presentation.hasDetailSheet
            || (presentation.expandsOnTruncation && titleMeasurement?.isTruncated == true)
    }

    private var resolvedMaterial: ChatNotificationMaterial {
        showsDetailAction ? .glass : presentation.material
    }

    var body: some View {
        Group {
            if showsDetailAction {
                pill
                    .chatCompactPillInteraction(
                        accessibilityLabel: accessibilityLabel,
                        action: {
                            detailID = UUID()
                            model.lifecycleRecordDiagnostic(event: "detail.tap", message: "detailID=\(detailID) sourceBytes=\(presentation.body?.utf8.count ?? 0)")
                            showingDetail = true
                        }
                    )
                    // Preserve the 44-point semantic row target without making
                    // its empty corners compete with the glass surface gesture.
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint(presentation.expandsOnTruncation ? "Shows the full error message" : "Shows details")
            } else {
                pill
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
        .contentTransition(.interpolate)
        .accessibilityLabel(accessibilityLabel)
        .onPreferenceChange(ChatCompactPillTitleMeasurementKey.self) { measurements in
            let rendered = measurements.first(where: { $0.renderedWidth > 0 })?.renderedWidth
            let intrinsic = measurements.first(where: { $0.intrinsicWidth > 0 })?.intrinsicWidth
            guard let rendered, let intrinsic else { return }
            let next = ChatCompactPillTitleMeasurement(renderedWidth: rendered, intrinsicWidth: intrinsic)
            guard titleMeasurement != next else { return }
            titleMeasurement = next
        }
        .tronManagedSheet(
            isPresented: $showingDetail,
            identity: "chat.transcript-event-detail"
        ) { detailSheet }
    }

    private var pill: some View {
        ChatCompactPillSurface(
            tone: presentation.tone,
            material: resolvedMaterial,
            interactive: showsDetailAction
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
                        ChatPreparedMarkdownDetail(text: body, detailID: detailID)
                            .padding(14)
                            .modifier(DetailBodySurface(
                                usesGlass: presentation.detailUsesGlassSurface,
                                accent: presentation.tone.surfaceColor
                            ))
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

struct DetailBodySurface: ViewModifier {
    let usesGlass: Bool
    let accent: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesGlass {
            content.tronGlassSurface(accent: accent, tintOpacity: 0.08)
        } else {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            content
                .background(accent.opacity(0.10), in: shape)
                .overlay(shape.stroke(accent.opacity(0.30), lineWidth: 0.5))
        }
    }
}

private struct ChatPreparedMarkdownDetail: View {
    let text: String
    let detailID: UUID
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(AppModel.self) private var model
    @State private var preparation = ChatDetailDocumentPreparation()

    var body: some View {
        Group {
            if let document = preparation.document, document.source == text {
                TronMarkdownView(document: document, streaming: false)
                    .onChange(of: preparation.revision, initial: true) { _, _ in
                        preparation.mounted(record: record)
                    }
            } else {
                Text("Preparing details…")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                    .accessibilityLabel("Preparing details")
            }
        }
        .task(id: PresentationActivityTaskID(
            source: text,
            presentationActive: presentationActivity.allowsDataPublication
        )) {
            let activity = presentationActivity
            await preparation.load(source: text, isCurrent: {
                presentationActivity == activity && activity.allowsDataPublication
            }, record: record)
        }
        .onDisappear { preparation.retire(record: record) }
    }

    private func record(_ message: String) {
        model.lifecycleRecordDiagnostic(event: "detail.preparation", message: "detailID=\(detailID) \(message)")
    }
}

struct TranscriptNotice: View {
    let title: String
    var value: String? = nil
    var detailBody: String? = nil
    let icon: String
    let tone: ChatNotificationTone
    var expandsOnTruncation = false
    var animatesEntrance = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed: Bool

    init(
        title: String,
        value: String? = nil,
        detailBody: String? = nil,
        icon: String,
        tone: ChatNotificationTone,
        expandsOnTruncation: Bool = false,
        animatesEntrance: Bool = false
    ) {
        self.title = title
        self.value = value
        self.detailBody = detailBody
        self.icon = icon
        self.tone = tone
        self.expandsOnTruncation = expandsOnTruncation
        self.animatesEntrance = animatesEntrance
        _revealed = State(initialValue: !animatesEntrance)
    }

    var body: some View {
        ChatNotificationView(presentation: .init(
            id: "embedded-notice", semanticID: nil, icon: icon, title: title,
            detail: value, body: detailBody, tone: tone,
            material: .flat, expandsOnTruncation: expandsOnTruncation
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
